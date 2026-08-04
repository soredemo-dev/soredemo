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

    /// Counters a caller can read after playback or export has run — never only a console line,
    /// the same "a dropped record with nothing counting it is indistinguishable from a record that
    /// was never produced" rule `CaptureSession.Diagnostics`/`AXObserver.Diagnostics` already
    /// apply to capture. `static`, like `renderer`/`style`/`observationLogURL`/`overrides` above,
    /// for the identical reason: AVFoundation owns every `StageCompositor` instance and this app
    /// never gets a handle to one, so a per-instance counter would be unreadable by anything
    /// outside AVFoundation itself. `StageWindow.load()` resets this to a fresh `Diagnostics()` at
    /// the same point it (re)sets `renderer`/`style`/`observationLogURL` — one recording opened,
    /// one counter's worth of drops for it — so this answers "how many frames has the CURRENTLY
    /// open recording's preview session dropped", not a lifetime total across every file the app
    /// has ever opened.
    nonisolated(unsafe) private static var _diagnostics = Diagnostics()
    /// Guards `_diagnostics` only — a separate lock from the instance-level `lock` below, because
    /// `_diagnostics` is `static` (shared across every `StageCompositor` instance, exactly like
    /// `renderer`/`style`/`observationLogURL`/`overrides`) while `lock` guards one instance's own
    /// `pointerTrack`/`clickTrack`/`tracksLoaded`. Two locks, two different things each protects.
    private static let diagnosticsLock = NSLock()
    static var diagnostics: Diagnostics { diagnosticsLock.withLock { _diagnostics } }
    /// Resets the counters below to zero — called by `StageWindow.load()` when a (possibly new)
    /// recording is opened, so a stale count from a previously opened file cannot be read as
    /// belonging to this one.
    static func resetDiagnostics() { diagnosticsLock.withLock { _diagnostics = Diagnostics() } }
    private static func recordDroppedFrame() { diagnosticsLock.withLock { _diagnostics.framesDropped += 1 } }

    /// **A complete account, not a partial one — Task 5.5's own counters needed three fix rounds
    /// to reach this bar and this one is written against that standard from the start.**
    /// `framesDropped` increments at exactly the two places `startRequest` below can fail to
    /// produce a composed frame for a composition time AVFoundation asked for — there is no third:
    ///
    ///   1. **The leading `guard` in `startRequest`.** Any of `request.sourceTrackIDs.first`,
    ///      `request.sourceReadOnlyPixelBuffer(byTrackID:)`, `renderContext`,
    ///      `context.newPixelBuffer()`, or `Self.renderer` being absent takes this branch. In
    ///      correctly wired playback the first two are supplied by AVFoundation and the third and
    ///      fifth are configured before playback ever starts (`StageWindow.load()`), so the
    ///      realistic way this fires during a REAL run is `context.newPixelBuffer()` returning
    ///      `nil` — `AVVideoCompositionRenderContext`'s own pixel-buffer pool can be exhausted
    ///      under real memory/GPU pressure during live, real-time playback. This is the shape "the
    ///      preview path may drop" names: a busy system genuinely failing to hand back a
    ///      destination buffer for one composition time, with no error of this app's own making.
    ///   2. **The `catch` around `renderer.render(_:source:into:)`.** A thrown render error —
    ///      `CoreImageFrameRenderer.render` does not throw today (structurally required by the
    ///      `FrameRendering` protocol's `throws`, the same "compiles-required, not yet exercised"
    ///      shape `MasterWriter.swift`'s own `do`/`catch` documents), but a future renderer
    ///      (Task 3's open Metal seam) legitimately could.
    ///
    /// Both branches call `request.finish(with:)` with an error instead of
    /// `request.finish(withComposedPixelBuffer:)` — AVFoundation receives no frame for that
    /// composition time either way, and these are the ONLY two `finish` calls in this file that do
    /// not carry a composed buffer. **Shared by preview and export alike**, because both consumers
    /// drive the same `StageCompositor` (`ARCHITECTURE.md` D8) — the export path additionally
    /// throws on its own `framesRead == framesWritten` mismatch (`MP4Exporter.swift`), so a drop
    /// there is never silent even without this counter; the preview path has no such check, which
    /// is the entire reason this counter exists.
    struct Diagnostics: Sendable {
        public internal(set) var framesDropped = 0
    }

    let sourcePixelBufferAttributes: [String: any Sendable]? =
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] =
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]

    private nonisolated(unsafe) var renderContext: AVVideoCompositionRenderContext?

    /// Guards `pointerTrack`/`clickTrack`/`tracksLoaded` below — **not** `renderContext`, which
    /// stays the pre-existing unguarded `nonisolated(unsafe)` this file already had. That
    /// asymmetry is deliberate, not an inconsistency left behind: `renderContext` is
    /// write-once-then-read (`renderContextChanged` sets it before any `startRequest` can see it,
    /// and it is never mutated again), the same "published before any callback can see it" shape
    /// `Self.renderer`'s own comment already claims for the statics above. `pointerTrack`/
    /// `clickTrack`/`tracksLoaded` are different: `loadedTracks()` below is a check-then-set INSIDE
    /// the call `startRequest` makes on every frame — a read-modify-write on the hot path, not a
    /// one-time publish — and an unguarded read-modify-write racing another thread's write is a
    /// data race in the language sense, not merely a stale-value risk. Review round 2 of this task
    /// found this resting on "AVFoundation serialises `startRequest` per instance", a framework
    /// runtime guarantee no test, header or scan states — and asked for the assumption removed
    /// rather than documented, which is what this lock does.
    private nonisolated let lock = NSLock()

    /// Built lazily on the first `startRequest` and cached for the rest of this instance's life —
    /// "read once", per the brief. AVFoundation instantiates one `StageCompositor` per composition
    /// session (`CompositionBuilder` sets this type as `customVideoCompositorClass`, which
    /// AVFoundation itself instantiates — nothing in this app ever calls `StageCompositor()`), and
    /// `startRequest` is the earliest point any instance method runs, so there is no earlier hook
    /// to read the log from. `tracksLoaded` is separate from `pointerTrack`/`clickTrack` being
    /// non-`nil` because a log that fails to read (missing file, corrupt header) must still be
    /// "loaded" — tried once and given up on — rather than retried on every single frame of the
    /// render. One flag for both tracks because they come from the SAME read of the SAME file
    /// (`loadedTracks()` below) — two flags could disagree about whether the log had been tried.
    ///
    /// All three are `nonisolated(unsafe)`, like every mutable property `CaptureSession` and
    /// `InputObserver` hold behind their own `lock` — `unsafe` is honest, not a suppression:
    /// nothing here is protected by actor isolation, everything is protected by `lock`, and
    /// `withLock`'s closure is what actually keeps concurrent access safe.
    private nonisolated(unsafe) var pointerTrack: PointerTrack?
    private nonisolated(unsafe) var clickTrack: ClickTrack?
    private nonisolated(unsafe) var tracksLoaded = false

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderContext = newRenderContext
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let trackID = request.sourceTrackIDs.first?.int32Value,
              let source = request.sourceReadOnlyPixelBuffer(byTrackID: trackID),
              let context = renderContext,
              let destination = context.newPixelBuffer(),
              let renderer = Self.renderer else {
            Self.recordDroppedFrame()
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
            Self.recordDroppedFrame()
            request.finish(with: error)
        }
    }

    enum CompositorError: Error { case notConfigured }

    // MARK: - the pointer track

    /// `.drawn(p)` becomes a placement in `plan`'s own output-pixel space, carrying whatever ripple
    /// phase `ClickTrack` reports at the same instant; every other reading — `.blind`,
    /// `.suppressedByReviewer`, `.noObservationYet` — draws no pointer AND no ripple: there is no
    /// cursor location to radiate one from, so the ripple question does not arise independently of
    /// the pointer one.
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
              let time = Nanoseconds(rationalSeconds: compositionTime.value,
                                     timescale: compositionTime.timescale) else { return nil }
        let (pointer, click) = loadedTracks()
        guard let pointer else { return nil }
        switch pointer.position(at: time) {
        case .drawn(let point):
            return StagePlanner.placement(for: point, in: plan, ripplePhase: click?.ripplePhase(at: time))
        case .blind, .suppressedByReviewer, .noObservationYet:
            return nil
        }
    }

    /// Reads `Self.observationLogURL` at most once per instance and caches both tracks it builds
    /// from that one read — success or failure alike, so a log this instance could not read is not
    /// retried on every frame. `Self.overrides` is read here too, at the same "once" moment, for
    /// the same reason `observationLogURL` is: both are configuration a caller sets before playback
    /// starts, not values that change frame to frame.
    ///
    /// **The check and the set are ONE critical section, not two.** `if tracksLoaded { … };
    /// tracksLoaded = true; …` — the shape this had before this lock existed — lets two threads
    /// both observe `tracksLoaded == false` and both perform the load: each would decode the log
    /// independently and each would write its own `pointerTrack`/`clickTrack`, the last writer
    /// winning. That duplicate work is idempotent here (`buildTracks` is a pure function of the
    /// file's bytes, so either result is correct), which is WHY a coarser lock — covering the
    /// check, the read, the decode and the write together — is the right trade rather than a
    /// narrower one that only protects the flag: idempotent redundancy is an acceptable cost, a
    /// half-written cache is not, and the simplest way to guarantee the latter never happens is to
    /// make the whole sequence one section. The file read itself is bounded, one-time, per-instance
    /// I/O — not a per-frame cost — so serialising concurrent callers through it while it happens
    /// is a one-time price, not a standing tax on every frame; every frame AFTER the first returns
    /// from the cache in O(1) under the same lock.
    ///
    /// **This lock is never held across `renderer.render(_:source:into:)`.** That call — which
    /// `CoreImageFrameRenderer`'s own header notes can cost milliseconds — happens in `startRequest`
    /// AFTER this function has already returned and released `lock`; nothing here reaches into it.
    private func loadedTracks() -> (pointer: PointerTrack?, click: ClickTrack?) {
        lock.withLock {
            if !tracksLoaded {
                tracksLoaded = true
                if let url = Self.observationLogURL,
                   let built = try? Self.buildTracks(from: url, overrides: Self.overrides) {
                    pointerTrack = built.pointer
                    clickTrack = built.click
                }
            }
            return (pointerTrack, clickTrack)
        }
    }

    /// Turns one observation log into a `PointerTrack` and a `ClickTrack`, in one pass over the
    /// file: `"pointer"` records become the `PointerTrack`'s samples; `"secureInput"` and
    /// `"tapDisabled"` records — the two kinds this log carries for `GapSite.secureInput`/
    /// `.tapDisabled` (`ObservationLog`'s own "what a record may contain") — become its
    /// `BlindInterval`s, each from that record's own `HostRange`, untouched; `"button"` records
    /// become the `ClickTrack`'s events (`ClickTrack.init` itself keeps only the `.down` ones).
    ///
    /// **`overrides` is taken as a parameter, not read from the log.** `CursorOverride` is, by its
    /// own header, "a reviewer's permanent decision" — a project-level judgement call, not a fact
    /// the observation log records. This app has no reviewer UI or persisted-override storage yet,
    /// so `Self.overrides` (above) is the only source for now and defaults to `[]`; when a
    /// reviewer UI exists, it sets that static the same way `StageWindow.load()` already sets
    /// `renderer` and `style`, and nothing about this function's own shape needs to change.
    private static func buildTracks(from url: URL, overrides: [CursorOverride]) throws
        -> (pointer: PointerTrack, click: ClickTrack) {
        let lines = try JSONLReader.linesOfFile(at: url).lines
        var samples: [PointerSample] = []
        var blindIntervals: [BlindInterval] = []
        var buttonEvents: [ButtonEvent] = []
        for line in lines {
            switch try ObservationLog.kind(of: line) {
            case "pointer":
                samples.append(try ObservationLog.decode(line) as PointerSample)
            case "button":
                buttonEvents.append(try ObservationLog.decode(line) as ButtonEvent)
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
        let pointer = PointerTrack(samples: samples, blindIntervals: blindIntervals, overrides: overrides)
        let click = ClickTrack(events: buttonEvents)
        return (pointer: pointer, click: click)
    }
}
