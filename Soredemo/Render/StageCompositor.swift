import AVFoundation
import CoreVideo
import Foundation
// `PointerSample`, `ObservationLog`, `JSONLReader`, `SecureInputInterval`, `TapDisabledInterval`
// for `buildPointerTrack(from:)` — reading the segment's observation log to build the
// `PointerTrack` `startRequest` reads from. Not previously imported here: nothing in this file
// touched `Project` before the drawn pointer (Phase 2B Task 5).
import Project
import Render
// `Nanoseconds` for the composition-time → host-clock conversion below. Reached until now only
// transitively through `Render` → `Project`/`Timeline`; `-enable-upcoming-feature
// MemberImportVisibility` (this app target's own flag, matched in
// `scripts/run-cross-boundary-probe.sh`) requires the direct import once this file names the type
// and reads `HostRange.start`/`.duration` off records it decodes.
import Timeline

/// The `AVVideoCompositing` conformance. **Owns no policy**: it asks the planner for a plan and
/// hands it to a renderer. Everything it decides is which frame is being drawn and when.
///
/// **`newPixelBuffer()`, not `newReadOnlyPixelBuffer()`.** The brief that specified this file
/// hedged on which name to call. Checked directly against the macOS 27.0 SDK header
/// (`AVVideoCompositing.h`): `newPixelBuffer` is declared on `AVVideoCompositionRenderContext` and
/// is `API_DEPRECATED("Use newReadOnlyPixelBuffer() instead", macos(10.9, 27.0), ...)` — the
/// successor name occurs exactly once in the entire SDK, inside that deprecation message, and is
/// declared on no type anywhere. `newReadOnlyPixelBuffer()` does not exist to call. Because the
/// deprecation floor (27.0) is above this project's deployment target (26.0, `ARCHITECTURE.md`
/// D2), `newPixelBuffer()` produces no deprecation warning here — this is not a D6b-27 row, it is
/// simply the only name that exists.
///
/// **`CVReadOnlyPixelBuffer`, found by the compiler rather than by any header or interface file —
/// not anticipated by the brief at all.** This SDK's `AVAsynchronousVideoCompositionRequest
/// .sourceReadOnlyPixelBuffer(byTrackID:)` (the successor the header names for the now-deprecated
/// `sourceFrameByTrackID:`) returns `CVReadOnlyPixelBuffer`, a type declared in no C header and no
/// `.swiftinterface` findable on this machine — its shape was established by `-typecheck`ing
/// single-member probes and reading the compiler's own type-mismatch diagnostics, not by reading
/// documentation. `.size: CVImageSize` (`.width`/`.height: Int`) supplies `sourceWidth`/
/// `sourceHeight` below. `withUnsafeBuffer<R>(_:)` hands a plain `CVPixelBuffer` into a closure for
/// its duration — the one public route back to the type `FrameRendering` (Task 3's seam) actually
/// speaks; the underlying buffer's own `unsafeBuffer` accessor is `internal` on
/// `CVBufferRepresentable` and unreachable from here. `request.finish(withComposedPixelBuffer:)` —
/// the same Swift name the brief used — turns out to want a `CVReadOnlyPixelBuffer` too, so the
/// freshly rendered `destination` (still a plain `CVPixelBuffer` from `newPixelBuffer()`) is
/// wrapped with `CVReadOnlyPixelBuffer(unsafeBuffer:)` before being handed back.
nonisolated final class StageCompositor: NSObject, AVVideoCompositing {
    /// Set once before the composition is handed to AVFoundation. `nonisolated(unsafe)` for the
    /// same reason `CaptureSession`'s writer references are: AVFoundation calls back on its own
    /// queue and the value is published before any callback can see it.
    nonisolated(unsafe) static var renderer: (any FrameRendering)?
    nonisolated(unsafe) static var style: StageStyle = .default
    /// The observation log this segment's pointer track is read from. `nil` — the default — means
    /// no pointer is ever drawn, which is not a fifth `PointerReading` case smuggled in through a
    /// side door: it is simply nothing having been configured to read from yet, the same state a
    /// caller that never sets `renderer` leaves this compositor in for the whole render.
    nonisolated(unsafe) static var observationLogURL: URL?
    /// A reviewer's permanent decisions to suppress the pointer — `CursorOverride`'s own header —
    /// set the same way `renderer`/`style`/`observationLogURL` are: by whoever owns this
    /// composition, before playback starts. Not read from the observation log; see
    /// `buildPointerTrack(from:)`'s own header for why. Empty by default, which is not a fifth
    /// `PointerReading` case either — it means nobody has overridden anything yet, the same
    /// "nothing configured" state `observationLogURL == nil` is for the log.
    nonisolated(unsafe) static var overrides: [CursorOverride] = []

    let sourcePixelBufferAttributes: [String: any Sendable]? =
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] =
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]

    private nonisolated(unsafe) var renderContext: AVVideoCompositionRenderContext?

    /// Built lazily on the first `startRequest` and cached for the rest of this instance's life —
    /// "read once", per the brief. AVFoundation instantiates one `StageCompositor` per composition
    /// session (`CompositionBuilder` sets this type as `customVideoCompositorClass`, which
    /// AVFoundation itself instantiates — nothing in this app ever calls `StageCompositor()`), and
    /// `startRequest` is the earliest point any instance method runs, so there is no earlier hook
    /// to read the log from. `pointerTrackLoaded` is separate from `pointerTrack` being non-`nil`
    /// because a log that fails to read (missing file, corrupt header) must still be "loaded" —
    /// tried once and given up on — rather than retried on every single frame of the render.
    private nonisolated(unsafe) var pointerTrack: PointerTrack?
    private nonisolated(unsafe) var pointerTrackLoaded = false

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderContext = newRenderContext
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let trackID = request.sourceTrackIDs.first?.int32Value,
              let source = request.sourceReadOnlyPixelBuffer(byTrackID: trackID),
              let context = renderContext,
              let destination = context.newPixelBuffer(),
              let renderer = Self.renderer else {
            request.finish(with: CompositorError.notConfigured)
            return
        }
        let basePlan = StagePlanner.plan(
            outputWidth: Int(context.size.width), outputHeight: Int(context.size.height),
            sourceWidth: source.size.width, sourceHeight: source.size.height,
            style: Self.style)
        let plan = RenderPlan(outputWidth: basePlan.outputWidth, outputHeight: basePlan.outputHeight,
                              card: basePlan.card, cornerRadius: basePlan.cornerRadius,
                              style: basePlan.style,
                              pointer: pointerPlacement(at: request.compositionTime, in: basePlan))
        do {
            // `source` is read-only, and `FrameRendering.render(_:source:into:)` — Task 3's seam —
            // asks for a plain `CVPixelBuffer`. `withUnsafeBuffer` is the one public bridge between
            // the two, scoped to this closure so nothing holds the unwrapped buffer past the call
            // that actually reads it.
            try source.withUnsafeBuffer { sourceBuffer in
                try renderer.render(plan, source: sourceBuffer, into: destination)
            }
            request.finish(withComposedPixelBuffer: CVReadOnlyPixelBuffer(unsafeBuffer: destination))
        } catch {
            request.finish(with: error)
        }
    }

    enum CompositorError: Error { case notConfigured }

    // MARK: - the pointer track

    /// `.drawn(p)` becomes a placement in `plan`'s own output-pixel space; every other reading —
    /// `.blind`, `.suppressedByReviewer`, `.noObservationYet` — draws no pointer at all.
    ///
    /// **This is a four-case `switch`, not an `if let` over two.** `PointerTrack.position(at:)`
    /// returns a four-case `PointerReading` precisely so a caller cannot collapse "a gap that was
    /// measured", "a reviewer's decision" and "before the first sample" into one absence — see
    /// that type's own header. Naming all four cases here (rather than `default: return nil`) is
    /// what makes a FIFTH case added later a compile error at this call site instead of a silent
    /// fall-through.
    private func pointerPlacement(at compositionTime: CMTime,
                                  in plan: RenderPlan) -> NormalizedPointerPlacement? {
        guard compositionTime.isValid,
              let track = loadedPointerTrack(),
              let time = Nanoseconds(rationalSeconds: compositionTime.value,
                                     timescale: compositionTime.timescale) else { return nil }
        switch track.position(at: time) {
        case .drawn(let point):
            return StagePlanner.placement(for: point, in: plan)
        case .blind, .suppressedByReviewer, .noObservationYet:
            return nil
        }
    }

    /// Reads `Self.observationLogURL` at most once per instance and caches the result — success
    /// or failure alike, so a log this instance could not read is not retried on every frame.
    /// `Self.overrides` is read here too, at the same "once" moment, for the same reason
    /// `observationLogURL` is: both are configuration a caller sets before playback starts, not
    /// values that change frame to frame.
    private func loadedPointerTrack() -> PointerTrack? {
        if pointerTrackLoaded { return pointerTrack }
        pointerTrackLoaded = true
        guard let url = Self.observationLogURL else { return nil }
        pointerTrack = try? Self.buildPointerTrack(from: url, overrides: Self.overrides)
        return pointerTrack
    }

    /// Turns one observation log into a `PointerTrack`: `"pointer"` records become its samples;
    /// `"secureInput"` and `"tapDisabled"` records — the two kinds this log carries for
    /// `GapSite.secureInput`/`.tapDisabled` (`ObservationLog`'s own "what a record may contain")
    /// — become its `BlindInterval`s, each from that record's own `HostRange`, untouched.
    ///
    /// **`overrides` is taken as a parameter, not read from the log.** `CursorOverride` is, by its
    /// own header, "a reviewer's permanent decision" — a project-level judgement call, not a fact
    /// the observation log records. This app has no reviewer UI or persisted-override storage yet,
    /// so `Self.overrides` (above) is the only source for now and defaults to `[]`; when a
    /// reviewer UI exists, it sets that static the same way `StageWindow.load()` already sets
    /// `renderer` and `style`, and nothing about this function's own shape needs to change.
    private static func buildPointerTrack(from url: URL,
                                          overrides: [CursorOverride]) throws -> PointerTrack {
        let lines = try JSONLReader.linesOfFile(at: url).lines
        var samples: [PointerSample] = []
        var blindIntervals: [BlindInterval] = []
        for line in lines {
            switch try ObservationLog.kind(of: line) {
            case "pointer":
                samples.append(try ObservationLog.decode(line) as PointerSample)
            case "secureInput":
                let interval = (try ObservationLog.decode(line) as SecureInputInterval).interval
                blindIntervals.append(BlindInterval(start: interval.start, duration: interval.duration,
                                                    cause: .secureInput))
            case "tapDisabled":
                let interval = (try ObservationLog.decode(line) as TapDisabledInterval).interval
                blindIntervals.append(BlindInterval(start: interval.start, duration: interval.duration,
                                                    cause: .tapDisabled))
            default:
                break
            }
        }
        return PointerTrack(samples: samples, blindIntervals: blindIntervals, overrides: overrides)
    }
}
