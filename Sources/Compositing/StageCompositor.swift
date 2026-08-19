import AVFoundation
import CoreVideo
import Foundation
// `Project` for `buildTracks(from:)`, which reads the segment's observation log.
import Project
import Render
// `Nanoseconds`, named below, so `MemberImportVisibility` requires the direct import.
import Timeline

/// The `AVVideoCompositing` conformance. Owns no policy: it asks the planner for a plan and hands
/// it to a renderer.
///
/// `newPixelBuffer()` is used because the successor named in its deprecation message is declared on
/// no type in this SDK. `withUnsafeBuffer` is the only public route from the source's read-only
/// buffer to the plain `CVPixelBuffer` `FrameRendering` takes.
public nonisolated final class StageCompositor: NSObject, AVVideoCompositing {
    /// Set once before the composition reaches AVFoundation, so it is published before any callback.
    public nonisolated(unsafe) static var renderer: (any FrameRendering)?
    // Not `public`: no caller outside this file sets `style`.
    nonisolated(unsafe) static var style: StageStyle = .default
    /// The observation log the pointer track is read from; `nil` draws no pointer.
    public nonisolated(unsafe) static var observationLogURL: URL?
    /// A reviewer's decisions to suppress the pointer, set before playback starts and never read
    /// from the observation log.
    public nonisolated(unsafe) static var overrides: [CursorOverride] = []

    /// Counters read after playback or export. `static` because AVFoundation owns every instance.
    /// Reset per opened recording, so not a lifetime total.
    nonisolated(unsafe) private static var _diagnostics = Diagnostics()
    /// Guards `_diagnostics` only; the instance-level `lock` below guards cached tracks.
    private static let diagnosticsLock = NSLock()
    // Every `_diagnostics` access runs inside `diagnosticsLock.withLock`.
    public static var diagnostics: Diagnostics { diagnosticsLock.withLock { unsafe _diagnostics } }
    /// Zeroes the counters, so a stale count cannot be read as belonging to a new recording.
    public static func resetDiagnostics() { diagnosticsLock.withLock { unsafe _diagnostics = Diagnostics() } }
    private static func recordDroppedFrame() { diagnosticsLock.withLock { unsafe _diagnostics.framesDropped += 1 } }

    /// `framesDropped` counts `startRequest`'s two failure paths, its leading `guard` and the
    /// `catch` around `render`. Compositor failures only: `AVPlayer` display-time drops and
    /// seek-cancelled requests never reach this file.
    public struct Diagnostics: Sendable {
        public internal(set) var framesDropped = 0
    }

    public let sourcePixelBufferAttributes: [String: any Sendable]? =
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    public let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] =
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]

    private nonisolated(unsafe) var renderContext: AVVideoCompositionRenderContext?

    /// Guards `pointerTrack`/`clickTrack`/`tracksLoaded`/`logAnchor`, which `loadedTracks()`
    /// read-modify-writes per frame. Not `renderContext`, which is write-once-then-read and
    /// published before any `startRequest` can see it.
    private nonisolated let lock = NSLock()

    /// Built lazily on the first `startRequest` and cached under `lock`. `tracksLoaded` is separate
    /// from the tracks being non-`nil` so a log that fails to read is not retried every frame.
    private nonisolated(unsafe) var pointerTrack: PointerTrack?
    private nonisolated(unsafe) var clickTrack: ClickTrack?
    /// The log header's origin for turning a composition time into the host clock the samples are
    /// stamped in. `nil` when the log had no header, which draws nothing.
    private nonisolated(unsafe) var logAnchor: EpochAnchor?
    private nonisolated(unsafe) var tracksLoaded = false

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        // Write-once-then-read, published before any `startRequest` callback can see it.
        unsafe renderContext = newRenderContext
    }

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        // Read under the "published before any callback" guarantee, not under `lock`.
        guard let trackID = request.sourceTrackIDs.first?.int32Value,
              let source = request.sourceReadOnlyPixelBuffer(byTrackID: trackID),
              let context = unsafe renderContext,
              let destination = context.newPixelBuffer(),
              let renderer = unsafe Self.renderer else {
            Self.recordDroppedFrame()
            request.finish(with: CompositorError.notConfigured)
            return
        }
        let basePlan = StagePlanner.plan(
            outputWidth: Int(context.size.width), outputHeight: Int(context.size.height),
            sourceWidth: source.size.width, sourceHeight: source.size.height,
            style: unsafe Self.style)
        let plan = RenderPlan(outputWidth: basePlan.outputWidth, outputHeight: basePlan.outputHeight,
                              card: basePlan.card, cornerRadius: basePlan.cornerRadius,
                              style: basePlan.style,
                              pointer: pointerPlacement(at: request.compositionTime, in: basePlan))
        do {
            // Scoped so the plain `CVPixelBuffer` never outlives the call.
            try source.withUnsafeBuffer { sourceBuffer in
                try renderer.render(plan, source: sourceBuffer, into: destination)
            }
            request.finish(withComposedPixelBuffer: CVReadOnlyPixelBuffer(unsafeBuffer: destination))
        } catch {
            Self.recordDroppedFrame()
            request.finish(with: error)
        }
    }

    /// `Equatable` so callers can compare against `.notConfigured` rather than pattern-matching.
    public enum CompositorError: Error, Equatable { case notConfigured }

    // MARK: - the pointer track

    /// `.drawn(p)` becomes a placement in `plan`'s output-pixel space with `ClickTrack`'s ripple
    /// phase at that instant; every other `PointerReading` draws nothing. Cases are named, not
    /// defaulted, so a new one is a compile error. `public` as the test seam, since
    /// `startRequest(_:)` takes a type only AVFoundation can construct.
    public func pointerPlacement(at compositionTime: CMTime,
                                 in plan: RenderPlan) -> NormalizedPointerPlacement? {
        guard compositionTime.isValid,
              let offset = Nanoseconds(rationalSeconds: compositionTime.value,
                                       timescale: compositionTime.timescale) else { return nil }
        let (pointer, click, anchor) = loadedTracks()
        guard let pointer, let anchor else { return nil }
        // `compositionTime` is relative to the composition start, log records absolute. The anchor
        // owns the conversion (`EpochAnchor.instant(atOffset:)`), and the tracks take a
        // `HostInstant`, so holding a bare `Nanoseconds` here — `1a98402`'s shape — no longer
        // typechecks. Rough placement, not a frame-accurate media origin.
        let instant = anchor.instant(atOffset: offset)
        switch pointer.position(at: instant) {
        case .drawn(let point, let shape):
            return StagePlanner.placement(for: point, in: plan,
                                          ripplePhase: click?.ripplePhase(at: instant),
                                          shape: shape)
        case .blind, .suppressedByReviewer, .noObservationYet:
            return nil
        }
    }

    /// Reads `Self.observationLogURL` at most once per instance, caching success or failure alike.
    /// Check and set are one critical section; the lock is never held across `render`.
    private func loadedTracks() -> (pointer: PointerTrack?, click: ClickTrack?, anchor: EpochAnchor?) {
        // The shared statics are read under the "published before playback starts" guarantee.
        lock.withLock {
            if !(unsafe tracksLoaded) {
                unsafe tracksLoaded = true
                if let url = unsafe Self.observationLogURL,
                   let built = try? Self.buildTracks(from: url, overrides: unsafe Self.overrides) {
                    unsafe pointerTrack = built.pointer
                    unsafe clickTrack = built.click
                    unsafe logAnchor = built.anchor
                }
            }
            return unsafe (pointerTrack, clickTrack, logAnchor)
        }
    }

    /// Turns one observation log into a `PointerTrack` and a `ClickTrack` in one pass.
    /// `overrides` is a parameter, not read from the log: a reviewer's decision is a
    /// project-level judgement, not an observed fact.
    private static func buildTracks(from url: URL, overrides: [CursorOverride]) throws
        -> (pointer: PointerTrack, click: ClickTrack, anchor: EpochAnchor?) {
        let lines = try JSONLReader.linesOfFile(at: url).lines
        var samples: [PointerSample] = []
        var blindIntervals: [BlindInterval] = []
        var buttonEvents: [ButtonEvent] = []
        var anchor: EpochAnchor?
        for line in lines {
            switch try ObservationLog.kind(of: line) {
            case "logHeader":
                anchor = (try ObservationLog.decode(line) as ObservationLogHeader).anchor
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
        return (pointer: pointer, click: click, anchor: anchor)
    }
}
