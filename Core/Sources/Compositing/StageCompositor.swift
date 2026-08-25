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

    /// Whether pressed shortcuts are drawn as badges. **On by default**: the recorder writes
    /// `key` records for exactly this, the row has claimed the badges since Phase 3, and a
    /// recording with no approved shortcut in it draws nothing either way. The track itself
    /// is read from the observation log with the pointer's, not set from outside.
    public nonisolated(unsafe) static var showsKeystrokes = true

    /// How the drawn cursor looks. Set on the same terms as the seams above.
    public nonisolated(unsafe) static var cursorStyle: CursorStyle = .default

    /// Where the camera sits, or `nil` for a recording without one. Set on the same terms as the
    /// seams above.
    public nonisolated(unsafe) static var cameraStyle: CameraOverlayStyle?
    /// The part of the recording used at all. Set on the same terms as the seams above.
    public nonisolated(unsafe) static var crop: CropRect = .whole
    /// Which of the composition's video tracks is the camera. **Set by whoever built the
    /// composition** — `CameraComposition.combine` returns it — because nothing about a track
    /// says what it is, and picking "the last video track" would break the moment a composition
    /// carried three.
    public nonisolated(unsafe) static var cameraTrackID: CMPersistentTrackID?

    /// Everything the compositor renders from, as one value.
    ///
    /// **The statics are process-global because AVFoundation owns compositor instances**, which
    /// this file has said since it was written — there is nowhere to hang per-render state. That
    /// is workable while one thing renders at a time and the thing rendering is the thing on
    /// screen. It stops being workable the moment a render is DEFERRED: a job queued now and run
    /// in two minutes would draw whatever the statics say then, which is whatever the person has
    /// edited since.
    ///
    /// So a caller that means "render what I meant when I asked" captures this first and applies
    /// it before rendering. `renderer` is deliberately absent — it is a `CIContext` and a device,
    /// shared by everything, and not part of what a frame LOOKS like.
    public struct Settings: Sendable {
        var style: StageStyle
        var observationLogURL: URL?
        var overrides: [CursorOverride]
        var editTimeline: EditTimeline?
        var framingOverrides: [FramingOverride]
        var zoomAdjustments: [ZoomAdjustment]
        var captions: CaptionTrack
        var captionStyle: CaptionStyle
        var burnsInCaptions: Bool
        var texts: TextTrack
        var redactions: RedactionTrack
        var showsKeystrokes: Bool
        var cursorStyle: CursorStyle
        var cameraStyle: CameraOverlayStyle?
        var crop: CropRect
        var cameraTrackID: CMPersistentTrackID?
    }

    /// What the compositor would draw right now.
    public nonisolated static func settings() -> Settings {
        unsafe Settings(style: style, observationLogURL: observationLogURL, overrides: overrides,
                        editTimeline: editTimeline, framingOverrides: framingOverrides,
                        zoomAdjustments: zoomAdjustments, captions: captions,
                        captionStyle: captionStyle, burnsInCaptions: burnsInCaptions,
                        texts: texts, redactions: redactions, showsKeystrokes: showsKeystrokes,
                        cursorStyle: cursorStyle,
                        cameraStyle: cameraStyle, crop: crop, cameraTrackID: cameraTrackID)
    }

    /// Puts them all back. Every field, so a value captured before one was added cannot leave a
    /// stale static behind — which is the failure mode a partial restore has and a total one
    /// cannot.
    public nonisolated static func apply(_ settings: Settings) {
        unsafe style = settings.style
        unsafe observationLogURL = settings.observationLogURL
        unsafe overrides = settings.overrides
        unsafe editTimeline = settings.editTimeline
        unsafe framingOverrides = settings.framingOverrides
        unsafe zoomAdjustments = settings.zoomAdjustments
        unsafe captions = settings.captions
        unsafe captionStyle = settings.captionStyle
        unsafe burnsInCaptions = settings.burnsInCaptions
        unsafe texts = settings.texts
        unsafe redactions = settings.redactions
        unsafe showsKeystrokes = settings.showsKeystrokes
        unsafe cursorStyle = settings.cursorStyle
        unsafe cameraStyle = settings.cameraStyle
        unsafe crop = settings.crop
        unsafe cameraTrackID = settings.cameraTrackID
    }

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
    /// The camera, built with the tracks from the same log and queried per frame — re-baked
    /// under the output's zoom ceiling the first time a frame says what the output is, and
    /// again only if that ceiling changes, which within one compositor instance it does not.
    private nonisolated(unsafe) var camera: CameraMotion?
    private nonisolated(unsafe) var cameraCeiling: Double = .infinity
    /// The pressed shortcuts, from the same log.
    private nonisolated(unsafe) var keystrokes: KeystrokeTrack?
    /// The movement the pointer path was baked under. A change re-bakes it, the way a change
    /// of zoom ceiling re-bakes the camera: the spring is stateful, so its answer cannot be
    /// adjusted per frame the way a colour or a size can.
    private nonisolated(unsafe) var pathMovement: PointerPath.Tuning.Movement = .standard
    private nonisolated(unsafe) var tracksLoaded = false

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        // Write-once-then-read, published before any `startRequest` callback can see it.
        unsafe renderContext = newRenderContext
    }

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        // Read under the "published before any callback" guarantee, not under `lock`.
        // **The screen is the first track that is NOT the camera.** With one video track this
        // is the same as `.first`; with two it is the difference between drawing the recording
        // and drawing a face at full frame.
        let cameraTrackID = unsafe Self.cameraTrackID
        guard let trackID = request.sourceTrackIDs
                .map(\.int32Value)
                .first(where: { $0 != cameraTrackID }),
              let source = request.sourceReadOnlyPixelBuffer(byTrackID: trackID),
              let context = unsafe renderContext,
              let destination = context.newPixelBuffer(),
              let renderer = unsafe Self.renderer else {
            Self.recordDroppedFrame()
            request.finish(with: CompositorError.notConfigured)
            return
        }
        // **The card is fitted to the CROPPED aspect, not the recording's.** `StagePlanner` fits
        // a rectangle inside the output, and handing it the uncropped size would letterbox a
        // cropped recording as though it were still 16:9 — the bars would be exactly the part
        // that was cropped away.
        let crop = unsafe Self.crop
        let cropped = crop.size(ofSourceWidth: source.size.width,
                                sourceHeight: source.size.height)
        let basePlan = StagePlanner.plan(
            outputWidth: Int(context.size.width), outputHeight: Int(context.size.height),
            sourceWidth: cropped.width, sourceHeight: cropped.height,
            style: unsafe Self.style)
        // The camera first: the pointer's placement is computed THROUGH the resulting plan
        // (`StagePlanner.placement` maps by `RenderPlan.contentX/Y`), so a pointer drawn
        // against the un-zoomed plan would sit where the user never pointed.
        // The source's pixels across the card are what bound the zoom — see
        // `FramingDepth.zoomCeiling`; the cropped width, because that is what the card shows.
        let aimed = cameraPlan(basePlan, at: request.compositionTime,
                               sourcePixelWidth: cropped.width)
        let plan = RenderPlan(outputWidth: aimed.outputWidth, outputHeight: aimed.outputHeight,
                              card: aimed.card, cornerRadius: aimed.cornerRadius,
                              style: aimed.style,
                              pointer: pointerPlacement(at: request.compositionTime, in: aimed),
                              contentZoom: aimed.contentZoom,
                              contentCentre: aimed.contentCentre,
                              caption: captionOverlay(at: request.compositionTime),
                              texts: textOverlays(at: request.compositionTime),
                              redactions: redactedRegions(at: request.compositionTime),
                              cursorStyle: unsafe Self.cursorStyle,
                              // **A hidden camera produces no overlay at all**, rather than one
                              // the renderer then has to know to skip. `Camera.hide` is a Rust recorder's
                              // switch for "not in this one" as distinct from "throw the footage
                              // away", and the cheapest place to honour it is before a plan
                              // carries it.
                              camera: (unsafe Self.cameraStyle)
                                  .flatMap { $0.isHidden ? nil : CameraOverlay(style: $0) },
                              crop: crop,
                              keystroke: keystrokeBadge(at: request.compositionTime))
        do {
            // Scoped so the plain `CVPixelBuffer` never outlives the call.
            // The camera's buffer, when the composition carries one. Read inside the same
            // scope as the screen's so neither plain `CVPixelBuffer` outlives the call.
            let cameraBuffer = cameraTrackID
                .flatMap { request.sourceReadOnlyPixelBuffer(byTrackID: $0) }
            try source.withUnsafeBuffer { sourceBuffer in
                if let cameraBuffer {
                    try cameraBuffer.withUnsafeBuffer { camera in
                        try renderer.render(plan, source: sourceBuffer, camera: camera,
                                            into: destination)
                    }
                } else {
                    try renderer.render(plan, source: sourceBuffer, camera: nil,
                                        into: destination)
                }
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
        // `presentedPosition`, not `position`: this is the RENDERING path, the one consumer
        // allowed to be gentle. The review path keeps the stepwise truth (recorder-parity
        // design, 2026-08-19 — presentation and diagnosis are different outputs), and the
        // presented reading is the spring-followed cursor with the lerp as its floor.
        switch pointer.presentedPosition(at: instant) {
        case .drawn(let point, let shape, let hotspot):
            let style = unsafe Self.cursorStyle
            // The idle fade and the lean are presentation, computed here beside the
            // position they belong to. The lean reads the spring's own velocity in OUTPUT
            // pixels — the content's scale under the camera included — so a flick across a
            // zoomed-in card leans as much as the same flick across the whole recording.
            let opacity = style.hidesWhenIdle
                ? pointer.idleOpacity(at: instant, hideAfter: style.idleDelay) : 1
            let velocity = pointer.presentedVelocity(at: instant) ?? (x: 0, y: 0)
            let tilt = CursorTilt.degrees(
                velocityXPixelsPerSecond: velocity.x * plan.card.width * plan.contentZoom,
                amount: style.tilt)
            let frameSeconds = (unsafe renderContext)?.videoComposition.frameDuration.seconds
            let smear = Self.cursorSmear(velocity: velocity, plan: plan,
                                         frameSeconds: frameSeconds ?? 1.0 / 60)
            return StagePlanner.placement(for: point, in: plan,
                                          ripplePhase: click?.ripplePhase(at: instant),
                                          shape: shape, hotspot: hotspot,
                                          opacity: opacity, tiltDegrees: tilt,
                                          smearRadius: smear?.radius ?? 0,
                                          smearAngle: smear?.angle ?? 0)
        case .blind, .suppressedByReviewer, .noObservationYet:
            return nil
        }
    }

    /// The shortcut badge on screen at an OUTPUT time, or `nil`. Converted to source time and
    /// then to the recorder's clock exactly as the pointer is: a press is an observation.
    public func keystrokeBadge(at compositionTime: CMTime) -> KeystrokeBadge? {
        guard unsafe Self.showsKeystrokes, compositionTime.isValid,
              let outputOffset = Nanoseconds(rationalSeconds: compositionTime.value,
                                             timescale: compositionTime.timescale),
              let offset = Self.sourceOffset(forOutput: outputOffset) else { return nil }
        let (_, _, anchor, _) = loadedTracks()
        guard let anchor, let track = lock.withLock({ unsafe keystrokes }) else { return nil }
        return track.badge(at: anchor.instant(atOffset: offset))
    }

    /// `basePlan` with the camera applied for `compositionTime`, or unchanged when the log
    /// carried no accepted click — a recording whose every chain was refused zooms not at
    /// all, which is the correct picture of "nothing passed the gates" rather than a
    /// fallback that invents a target.
    ///
    /// `public` for the same reason `pointerPlacement` is: `startRequest(_:)` takes a type
    /// only AVFoundation constructs, so this is the seam a test can reach.
    ///
    /// `sourcePixelWidth` is how many of the recording's pixels the card shows at zoom 1 —
    /// the cropped width. With it the camera is baked under `FramingDepth.zoomCeiling`, so a
    /// zoom never stretches a source pixel past `maximumMagnification`; without it (`nil`,
    /// the tests' seam) the camera aims at each block's own depth.
    public func cameraPlan(_ basePlan: RenderPlan, at compositionTime: CMTime,
                           sourcePixelWidth: Int? = nil) -> RenderPlan {
        guard compositionTime.isValid,
              let outputOffset = Nanoseconds(rationalSeconds: compositionTime.value,
                                             timescale: compositionTime.timescale),
              // Same conversion as `pointerPlacement`, and it must be: a camera aimed in
              // source time while the pointer was placed in output time would draw the cursor
              // outside the region the camera framed, on every frame after the first cut.
              let offset = Self.sourceOffset(forOutput: outputOffset)
        else { return basePlan }
        let ceiling = sourcePixelWidth.map {
            FramingDepth.zoomCeiling(sourcePixels: Double($0), cardPixels: basePlan.card.width)
        } ?? .infinity
        let (_, _, anchor, camera) = loadedTracks(zoomCeiling: ceiling)
        guard let anchor, let camera else { return basePlan }
        let state = camera.state(at: anchor.instant(atOffset: offset))
        // The exposure this frame stands for is the composition's own frame duration —
        // the one number a smear length needs that `Render` does not have.
        let frameSeconds = (unsafe renderContext)?.videoComposition.frameDuration.seconds
        return RenderPlan(outputWidth: basePlan.outputWidth, outputHeight: basePlan.outputHeight,
                          card: basePlan.card, cornerRadius: basePlan.cornerRadius,
                          style: basePlan.style, pointer: basePlan.pointer,
                          contentZoom: state.zoom, contentCentre: state.centre,
                          motionBlur: Self.motionBlur(for: state, card: basePlan.card,
                                                      outputHeight: basePlan.outputHeight,
                                                      frameSeconds: frameSeconds ?? 1.0 / 60))
    }

    /// **The cursor's own smear for one frame, under the SAME shutter the card gets.**
    ///
    /// A frame is one exposure, so everything that moves across it smears — making the card's
    /// blur automatic and the cursor's a knob would be two answers to one question. There is
    /// no `CursorStyle` field here for that reason; `StageCompositor.shutterFraction` governs
    /// both. ScreenKite ships this as an inspector slider and Screen Studio splits its blur
    /// three ways (cursor / zooming / panning, guide/animations); the effect is theirs, the
    /// derivation from an exposure is this project's.
    ///
    /// **The card's pan is added to the cursor's own travel**, because the cursor's smear is
    /// its displacement across the FRAME and the frame is moving too: a cursor held still
    /// while the camera pans is travelling across the picture just as fast as one moving over
    /// a still camera. `plan.motionBlur.panRadius` is half the card's travel, so the whole of
    /// it is twice that, taken at `panAngle`.
    ///
    /// **The zoom's radial term is left out**, and that is a real omission rather than an
    /// oversight: it varies with distance from the card's centre, so a point sample would need
    /// its own offset threaded through, and at the cursor it is a fraction of a pixel except
    /// during a whip zoom with the cursor at the frame's edge. Named here so the day it
    /// matters, it is a known gap and not a discovery.
    nonisolated static func cursorSmear(velocity: (x: Double, y: Double), plan: RenderPlan,
                                        frameSeconds: Double) -> (radius: Double, angle: Double)? {
        guard frameSeconds > 0, frameSeconds.isFinite,
              velocity.x.isFinite, velocity.y.isFinite else { return nil }
        let exposure = frameSeconds * shutterFraction
        var travelX = velocity.x * plan.card.width * plan.contentZoom * exposure
        var travelY = velocity.y * plan.card.height * plan.contentZoom * exposure
        if let card = plan.motionBlur, card.panRadius > 0 {
            travelX += cos(card.panAngle) * card.panRadius * 2
            travelY += sin(card.panAngle) * card.panRadius * 2
        }
        let length = hypot(travelX, travelY)
        guard length >= motionBlurThreshold else { return nil }
        let capped = min(length, Double(plan.outputHeight) * maximumBlurFraction)
        return (radius: capped / 2, angle: atan2(travelY, travelX))
    }

    /// **A 180° shutter.** Film exposes each frame for half its duration, and that is the
    /// smear an audience has learned to read as motion rather than as blur; a full-frame
    /// smear reads as a defocus and none reads as judder. a Swift recorder's `MotionBlurSettings`
    /// arrives at an intensity in the same range by eye.
    static let shutterFraction: Double = 0.5
    /// The smear below which the filter is not worth its cost — under a pixel and a half a
    /// blur is a slightly softer frame with nothing to show for it.
    static let motionBlurThreshold: Double = 1.5
    /// The longest smear, as a fraction of the output height: 2% is ~22 px at 1080p, which
    /// is a fast pan's whole exposure. Past it the picture is unreadable for the frames it
    /// lasts and the cap is what keeps a whip pan legible.
    static let maximumBlurFraction: Double = 0.02

    /// The content's smear for one frame, from the camera's velocities. Pure and internal
    /// so `StageCompositorTests` can drive it with a state rather than a composition.
    ///
    /// A centre moving at `v` normalised units/s at zoom `z` moves the content across the
    /// card at `v × z × card` pixels/s — the sign is the content's, opposite to the camera's,
    /// which a symmetric blur does not care about. A zoom changing at `ż` scales the content
    /// by `ż/z` per second, so a point at the card's edge, `card/2` from the centre, moves
    /// `ż/z × card/2` pixels/s.
    nonisolated static func motionBlur(for state: CameraState, card: StageRect,
                                       outputHeight: Int, frameSeconds: Double) -> MotionBlur? {
        guard state.isMoving, frameSeconds > 0, frameSeconds.isFinite else { return nil }
        let exposure = frameSeconds * shutterFraction
        let cap = Double(outputHeight) * maximumBlurFraction

        let panX = state.velocityX * state.zoom * card.width * exposure
        let panY = state.velocityY * state.zoom * card.height * exposure
        let panLength = min(hypot(panX, panY), cap)
        let zoomLength = min(abs(state.zoomVelocity) / max(state.zoom, 1)
                             * max(card.width, card.height) / 2 * exposure, cap)
        guard panLength >= motionBlurThreshold || zoomLength >= motionBlurThreshold else {
            return nil
        }
        return MotionBlur(panRadius: panLength >= motionBlurThreshold ? panLength / 2 : 0,
                          panAngle: atan2(panY, panX),
                          zoomAmount: zoomLength >= motionBlurThreshold ? zoomLength : 0,
                          centreX: card.x + card.width / 2, centreY: card.y + card.height / 2)
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
        let style = unsafe Self.captionStyle
        // The words are only assembled when they will be drawn: splitting and marking on every
        // frame of a caption nobody asked to highlight is work for nothing.
        let words = style.highlightsSpokenWord ? Self.words(of: cue, at: source) : []
        return CaptionOverlay(text: cue.text, style: style, words: words)
    }

    /// A cue's words with the one being said marked.
    ///
    /// **Matched by walking the cue's own word spans, not by splitting its text.** The two do not
    /// line up: a recogniser's runs do not split on spaces — the reason `CaptionBuilder` times
    /// phrases by alphanumeric character count — so `text.split(" ")[n]` is not `words[n]`. The
    /// spans carry the text they were recognised from, and that is what is drawn.
    ///
    /// With no word timings the array is empty and the renderer draws the line whole, which is
    /// the honest fallback: a highlight computed by dividing the line's duration evenly would be
    /// wrong on every line where somebody paused.
    static func words(of cue: CaptionCue, at time: Nanoseconds) -> [CaptionWord] {
        guard !cue.words.isEmpty else { return [] }
        return cue.words.map { word in
            CaptionWord(text: word.text,
                        isSpoken: time.rawValue >= word.start.rawValue
                            && time.rawValue < word.end.rawValue)
        }
    }

    /// The text overlays on screen at an OUTPUT time. Converted to source time first, for the
    /// reason `captionOverlay(at:)` gives.
    private func textOverlays(at compositionTime: CMTime) -> [TextOverlay] {
        guard !(unsafe Self.texts.isEmpty) else { return [] }
        let outputOffset = Nanoseconds(CMTimeConvertScale(
            compositionTime, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value)
        guard let source = Self.sourceOffset(forOutput: outputOffset) else { return [] }
        return unsafe Self.texts.items(at: source)
            .map { TextOverlay(text: $0.text, style: $0.style,
                               animation: $0.animationState(at: source)) }
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
    ///
    /// `zoomCeiling` re-bakes the camera when it differs from the one it was baked under —
    /// the first camera query of an instance, in practice, since the ceiling is a function
    /// of the output and the crop and both are fixed for a composition. The pointer queries
    /// pass `.infinity` and never trigger a bake: a pointer does not zoom.
    private func loadedTracks(zoomCeiling: Double = .infinity)
        -> (pointer: PointerTrack?, click: ClickTrack?, anchor: EpochAnchor?, camera: CameraMotion?) {
        // The shared statics are read under the "published before playback starts" guarantee.
        lock.withLock {
            if !(unsafe tracksLoaded) {
                unsafe tracksLoaded = true
                if let url = unsafe Self.observationLogURL,
                   let built = try? unsafe Self.buildTracks(from: url, overrides: Self.overrides,
                                                            framingOverrides: Self.framingOverrides) {
                    unsafe pointerTrack = built.pointer
                    unsafe pathMovement = built.movement
                    unsafe clickTrack = built.click
                    unsafe camera = built.camera
                    unsafe cameraCeiling = built.camera.zoomCeiling
                    unsafe keystrokes = built.keystrokes
                    unsafe logAnchor = built.anchor
                }
            }
            let wanted = (unsafe Self.cursorStyle).movement
            if unsafe pathMovement != wanted, let existing = unsafe pointerTrack {
                unsafe pointerTrack = existing.moving(wanted)
                unsafe pathMovement = wanted
            }
            if zoomCeiling.isFinite, let current = unsafe camera,
               unsafe cameraCeiling != max(zoomCeiling, 1.0) {
                unsafe camera = current.limited(toZoomCeiling: zoomCeiling)
                unsafe cameraCeiling = unsafe camera?.zoomCeiling ?? .infinity
            }
            return unsafe (pointerTrack, clickTrack, logAnchor, camera)
        }
    }

    /// Turns one observation log into a `PointerTrack` and a `ClickTrack` in one pass.
    /// `overrides` is a parameter, not read from the log: a reviewer's decision is a
    /// project-level judgement, not an observed fact.
    private static func buildTracks(from url: URL, overrides: [CursorOverride],
                                    framingOverrides: [FramingOverride] = []) throws
        -> (pointer: PointerTrack, click: ClickTrack, anchor: EpochAnchor?, camera: CameraMotion,
            keystrokes: KeystrokeTrack, movement: PointerPath.Tuning.Movement) {
        let lines = try JSONLReader.linesOfFile(at: url).lines
        var samples: [PointerSample] = []
        var blindIntervals: [BlindInterval] = []
        var buttonEvents: [ButtonEvent] = []
        var presses: [KeystrokeTrack.Press] = []
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
            case "key":
                // **Read at last.** The writer has emitted these since Phase 2 and this
                // `switch` fell through to `default` on every one of them.
                let key = try ObservationLog.decode(line) as KeySample
                presses.append(KeystrokeTrack.Press(instant: key.instant, shortcut: key.shortcut))
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
        // The button-down instants feed the presentation path, where the cursor's spring
        // stiffens into a click so it has arrived when the ripple starts — see `PointerPath`.
        let movement = (unsafe cursorStyle).movement
        let pointer = PointerTrack(samples: samples, blindIntervals: blindIntervals,
                                   overrides: overrides,
                                   clickInstants: buttonEvents.filter { $0.phase == .down }
                                       .map(\.instant),
                                   tuning: PointerPath.Tuning.default.moving(movement))
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
        // **The presented cursor is what the camera follows inside a zoom** — the same
        // reading the renderer draws, so the camera and the drawn pointer agree about where
        // the person is. `Framing` cannot name `PointerTrack`, so it arrives as a function.
        let camera = CameraMotion(blocks: unsafe zoomAdjustments.applied(to: derived),
                                  cursor: { instant in
            if case .drawn(let point, _, _) = pointer.presentedPosition(at: instant) { return point }
            return nil
        })
        return (pointer: pointer, click: click, anchor: anchor, camera: camera,
                keystrokes: KeystrokeTrack(presses: presses), movement: movement)
    }
}
