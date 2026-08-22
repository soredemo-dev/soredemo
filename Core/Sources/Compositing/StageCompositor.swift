import AVFoundation
import Overlays
import CoreVideo
import Foundation
// `Project` for `buildTracks(from:)`, which reads the segment's observation log.
// `FramingGate`/`ZoomBlock`/`CameraMotion` — the zoom pipeline this file drives.
import Framing
import Geometry
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
    /// The stage's look — background, padding, corner radius, shadow.
    ///
    /// **`public` since the style picker.** It was internal on the stated grounds that "no
    /// caller outside this file sets `style`", which was true and was the problem: the app
    /// shipped one hard-coded look, and every comparable recorder lets a person choose one.
    /// Set on the same terms as the other seams here — before the composition is built,
    /// because AVFoundation owns every compositor instance.
    public nonisolated(unsafe) static var style: StageStyle = .default
    /// The observation log the pointer track is read from; `nil` draws no pointer.
    public nonisolated(unsafe) static var observationLogURL: URL?
    /// A reviewer's decisions to suppress the pointer, set before playback starts and never read
    /// from the observation log.
    public nonisolated(unsafe) static var overrides: [CursorOverride] = []
    /// **What survived editing, and where each surviving nanosecond came from.**
    ///
    /// `nil` means no edits — output time IS source time, which is the case every recording
    /// starts in and the reason a bug here hides until the first cut. Once a cut exists,
    /// `startRequest` is handed OUTPUT times while every observation record is stamped in
    /// SOURCE time, so the pointer and the camera must be looked up through this or they land
    /// by however much was removed before them. Set on the same terms as the seams below.
    public nonisolated(unsafe) static var editTimeline: EditTimeline?

    /// A reviewer's decisions about where the camera frames — set on the same terms and for
    /// the same reason as `overrides`. Applied by `FramingPlan.framedClicks(with:)`, which
    /// consults them BEFORE the gate, so a re-derivation cannot replace an authored value.
    public nonisolated(unsafe) static var framingOverrides: [FramingOverride] = []
    /// A person's changes to the derived zooms — where each starts, how long it lasts, whether
    /// it happens. Set on the same terms as the seams above. See `ZoomAdjustment` for why they
    /// are keyed on the click rather than on the block.
    public nonisolated(unsafe) static var zoomAdjustments: [ZoomAdjustment] = []

    /// The captions to burn in, in the recording's SOURCE time, or empty for none. Set on the
    /// same terms as the seams above.
    ///
    /// **Source time, and looked up through `sourceOffset(forOutput:)` like everything else
    /// here.** A track already retimed through the edit would be right until the next cut and
    /// wrong afterwards, in exactly the way `editTimeline`'s own comment describes. Retiming for
    /// a SIDECAR file is a different job with a different answer — see
    /// `CaptionTrack.retimed(through:)`, which the export uses and this does not.
    public nonisolated(unsafe) static var captions = CaptionTrack()
    /// How a burnt-in caption looks. Separate from `style`, which is the card's look: a person
    /// turning captions off should not have to give up their background.
    public nonisolated(unsafe) static var captionStyle: CaptionStyle = .default
    /// Whether to draw them at all. False leaves `captions` in place, so turning burn-in off and
    /// on again does not discard a transcript that took a minute to produce.
    public nonisolated(unsafe) static var burnsInCaptions = false

    /// Text overlays, in the recording's SOURCE time. Set on the same terms as the seams above,
    /// and looked up the same way — see `captionOverlay(at:)`.
    ///
    /// No `burnsIn` twin: a person who put a word on the screen put it there on purpose, and a
    /// title that could be silently switched off would be a title nobody trusts is in the export.
    public nonisolated(unsafe) static var texts = TextTrack()

    /// Parts of the recording to hide. Set on the same terms as the seams above.
    public nonisolated(unsafe) static var redactions = RedactionTrack()

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
    /// The camera, built with the tracks from the same log and queried per frame.
    private nonisolated(unsafe) var camera: CameraMotion?
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
        // The camera first: the pointer's placement is computed THROUGH the resulting plan
        // (`StagePlanner.placement` maps by `RenderPlan.contentX/Y`), so a pointer drawn
        // against the un-zoomed plan would sit where the user never pointed.
        let aimed = cameraPlan(basePlan, at: request.compositionTime)
        let plan = RenderPlan(outputWidth: aimed.outputWidth, outputHeight: aimed.outputHeight,
                              card: aimed.card, cornerRadius: aimed.cornerRadius,
                              style: aimed.style,
                              pointer: pointerPlacement(at: request.compositionTime, in: aimed),
                              contentZoom: aimed.contentZoom,
                              contentCentre: aimed.contentCentre,
                              caption: captionOverlay(at: request.compositionTime),
                              texts: textOverlays(at: request.compositionTime),
                              redactions: redactedRegions(at: request.compositionTime))
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
    /// **Output time → source time, through the edit.** The one conversion that stands between
    /// a composition frame and the recording it was made from.
    ///
    /// `nil` when the requested output time is past the end of the edited video — a frame that
    /// does not exist. Not clamped: the caller draws no pointer and applies no camera rather
    /// than reusing the last frame's answer for every frame past the end.
    ///
    /// With no edit this is the identity, which is exactly why it is written once here and
    /// called from both time-reading sites rather than inlined at each.
    nonisolated static func sourceOffset(forOutput offset: Nanoseconds) -> Nanoseconds? {
        guard let timeline = unsafe editTimeline else { return offset }
        return timeline.sourceTime(atOutput: offset)
    }

    public func pointerPlacement(at compositionTime: CMTime,
                                 in plan: RenderPlan) -> NormalizedPointerPlacement? {
        guard compositionTime.isValid,
              let outputOffset = Nanoseconds(rationalSeconds: compositionTime.value,
                                             timescale: compositionTime.timescale),
              let offset = Self.sourceOffset(forOutput: outputOffset) else { return nil }
        let (pointer, click, anchor, _) = loadedTracks()
        guard let pointer, let anchor else { return nil }
        // `compositionTime` is relative to the composition start, log records absolute. The anchor
        // owns the conversion (`EpochAnchor.instant(atOffset:)`), and the tracks take a
        // `HostInstant`, so holding a bare `Nanoseconds` here — `1a98402`'s shape — no longer
        // typechecks. Rough placement, not a frame-accurate media origin.
        let instant = anchor.instant(atOffset: offset)
        // `smoothedPosition`, not `position`: this is the RENDERING path, the one consumer
        // allowed to be gentle. The review path keeps the stepwise truth (recorder-parity
        // design, 2026-08-19 — presentation and diagnosis are different outputs).
        switch pointer.smoothedPosition(at: instant) {
        case .drawn(let point, let shape, let hotspot):
            return StagePlanner.placement(for: point, in: plan,
                                          ripplePhase: click?.ripplePhase(at: instant),
                                          shape: shape, hotspot: hotspot)
        case .blind, .suppressedByReviewer, .noObservationYet:
            return nil
        }
    }

    /// `basePlan` with the camera applied for `compositionTime`, or unchanged when the log
    /// carried no accepted click — a recording whose every chain was refused zooms not at
    /// all, which is the correct picture of "nothing passed the gates" rather than a
    /// fallback that invents a target.
    ///
    /// `public` for the same reason `pointerPlacement` is: `startRequest(_:)` takes a type
    /// only AVFoundation constructs, so this is the seam a test can reach.
    public func cameraPlan(_ basePlan: RenderPlan, at compositionTime: CMTime) -> RenderPlan {
        guard compositionTime.isValid,
              let outputOffset = Nanoseconds(rationalSeconds: compositionTime.value,
                                             timescale: compositionTime.timescale),
              // Same conversion as `pointerPlacement`, and it must be: a camera aimed in
              // source time while the pointer was placed in output time would draw the cursor
              // outside the region the camera framed, on every frame after the first cut.
              let offset = Self.sourceOffset(forOutput: outputOffset)
        else { return basePlan }
        let (_, _, anchor, camera) = loadedTracks()
        guard let anchor, let camera else { return basePlan }
        let state = camera.state(at: anchor.instant(atOffset: offset))
        return RenderPlan(outputWidth: basePlan.outputWidth, outputHeight: basePlan.outputHeight,
                          card: basePlan.card, cornerRadius: basePlan.cornerRadius,
                          style: basePlan.style, pointer: basePlan.pointer,
                          contentZoom: state.zoom, contentCentre: state.centre)
    }

    /// The caption on screen at an OUTPUT time, or `nil`.
    ///
    /// Converted to source time first, for the reason `editTimeline` gives: the cues are stamped
    /// in source time and `compositionTime` is an output time, so after the first cut a lookup
    /// that skipped this would show the caption from wherever the cut had moved.
    private func captionOverlay(at compositionTime: CMTime) -> CaptionOverlay? {
        guard unsafe Self.burnsInCaptions, !(unsafe Self.captions.isEmpty) else { return nil }
        let outputOffset = Nanoseconds(CMTimeConvertScale(
            compositionTime, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value)
        guard let source = Self.sourceOffset(forOutput: outputOffset),
              let cue = unsafe Self.captions.cue(at: source) else { return nil }
        return CaptionOverlay(text: cue.text, style: unsafe Self.captionStyle)
    }

    /// The text overlays on screen at an OUTPUT time. Converted to source time first, for the
    /// reason `captionOverlay(at:)` gives.
    private func textOverlays(at compositionTime: CMTime) -> [TextOverlay] {
        guard !(unsafe Self.texts.isEmpty) else { return [] }
        let outputOffset = Nanoseconds(CMTimeConvertScale(
            compositionTime, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value)
        guard let source = Self.sourceOffset(forOutput: outputOffset) else { return [] }
        return unsafe Self.texts.items(at: source)
            .map { TextOverlay(text: $0.text, style: $0.style) }
    }

    /// The regions to hide on this frame.
    ///
    /// **Falls back to hiding EVERYTHING covered when the output time cannot be mapped**, rather
    /// than to hiding nothing. Every other lookup here returns "draw none" on a failure, which is
    /// the safe answer for a cursor and the unsafe one for a redaction: the failure mode of the
    /// safe-looking choice is a frame that shows what a person hid.
    private func redactedRegions(at compositionTime: CMTime) -> [RedactionRegion] {
        guard !(unsafe Self.redactions.isEmpty) else { return [] }
        let outputOffset = Nanoseconds(CMTimeConvertScale(
            compositionTime, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value)
        guard let source = Self.sourceOffset(forOutput: outputOffset) else {
            return unsafe Self.redactions.items
                .filter { $0.coversEverything && !$0.region.isEmpty }.map(\.region)
        }
        return unsafe Self.redactions.regions(at: source)
    }

    /// Reads `Self.observationLogURL` at most once per instance, caching success or failure alike.
    /// Check and set are one critical section; the lock is never held across `render`.
    private func loadedTracks() -> (pointer: PointerTrack?, click: ClickTrack?,
                                    anchor: EpochAnchor?, camera: CameraMotion?) {
        // The shared statics are read under the "published before playback starts" guarantee.
        lock.withLock {
            if !(unsafe tracksLoaded) {
                unsafe tracksLoaded = true
                if let url = unsafe Self.observationLogURL,
                   let built = try? unsafe Self.buildTracks(from: url, overrides: Self.overrides,
                                                            framingOverrides: Self.framingOverrides) {
                    unsafe pointerTrack = built.pointer
                    unsafe clickTrack = built.click
                    unsafe camera = built.camera
                    unsafe logAnchor = built.anchor
                }
            }
            return unsafe (pointerTrack, clickTrack, logAnchor, camera)
        }
    }

    /// Turns one observation log into a `PointerTrack` and a `ClickTrack` in one pass.
    /// `overrides` is a parameter, not read from the log: a reviewer's decision is a
    /// project-level judgement, not an observed fact.
    private static func buildTracks(from url: URL, overrides: [CursorOverride],
                                    framingOverrides: [FramingOverride] = []) throws
        -> (pointer: PointerTrack, click: ClickTrack, anchor: EpochAnchor?, camera: CameraMotion) {
        let lines = try JSONLReader.linesOfFile(at: url).lines
        var samples: [PointerSample] = []
        var blindIntervals: [BlindInterval] = []
        var buttonEvents: [ButtonEvent] = []
        var anchor: EpochAnchor?
        var planEntries: [FramingPlan.Entry] = []
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
            case "axChain":
                // **Every decision is kept now, accepted and refused alike.** This used to
                // keep the targets and discard the refusals one call after the gate named
                // them, so a recording that zoomed nowhere could not say why. `FramingPlan`
                // holds both; `review-ui` reads it, and a reviewer's override attaches to it.
                let record = try ObservationLog.decode(line) as AXChainRecord
                planEntries.append(FramingPlan.Entry(instant: record.instant,
                                                     decision: FramingGate.decide(for: record),
                                                     clickPosition: record.clickPosition,
                                                     clickRevision: record.clickRevision))
            default:
                break
            }
        }
        let pointer = PointerTrack(samples: samples, blindIntervals: blindIntervals, overrides: overrides)
        let click = ClickTrack(events: buttonEvents)
        // Overrides first, the gate second — the resolution order IS the producer-value rule.
        let plan = FramingPlan(entries: planEntries)
        // **The pointer fallback is on**, which is what makes a recording zoom at all when
        // accessibility is unavailable — a real recording measured eleven frames with the card
        // identical in every one, because every chain came back `hitTestReturnedNothing`.
        // Derive, then adjust. The order is the producer-value rule: a person's correction is
        // applied to whatever the gate concluded this time, so re-deriving cannot discard it
        // and cannot silently ignore it either.
        let derived = ZoomBlock.blocks(
            for: plan.framedClicks(with: framingOverrides,
                                   pointerFallbackRevision: plan.fallbackRevision))
        // `unsafe`: `zoomAdjustments` is a `nonisolated(unsafe)` static, read here under the
        // same "published before playback starts" guarantee as every other seam on this type.
        let camera = CameraMotion(blocks: unsafe zoomAdjustments.applied(to: derived))
        return (pointer: pointer, click: click, anchor: anchor, camera: camera)
    }
}
