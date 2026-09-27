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
    /// Guards every seam below.
    ///
    /// **They were `nonisolated(unsafe)` with a comment claiming they are "set once before the
    /// composition reaches AVFoundation".** That was true when it was written and stopped being
    /// true when the style picker shipped: `StageStylePicker.publish()` writes `style` on every
    /// slider tick, while a preview is playing and an existing compositor is reading it on
    /// AVFoundation's render queue.
    ///
    /// **`StageStyle` contains a `String`** — `StageBackground.image(filename:)` — so a torn
    /// read there is not a frame that looks wrong, it is a retain count read from a pointer
    /// that is being replaced. Changing the background while the preview plays is an ordinary
    /// thing to do.
    ///
    /// A lock per access, about twenty reads a frame: measured against the frame budgets, which
    /// are 8 ms at 1080p and 22 at 4K. This costs nothing that instrument can see.
    private static let seamLock = NSLock()

    /// Set once before the composition reaches AVFoundation, so it is published before any callback.
    private nonisolated(unsafe) static var _renderer: (any FrameRendering)?
    public static var renderer: (any FrameRendering)? {
        get { seamLock.withLock { unsafe _renderer } }
        set { seamLock.withLock { unsafe _renderer = newValue } }
    }
    /// The stage's look — background, padding, corner radius, shadow.
    ///
    /// **`public` since the style picker.** It was internal on the stated grounds that "no
    /// caller outside this file sets `style`", which was true and was the problem: the app
    /// shipped one hard-coded look, and every comparable recorder lets a person choose one.
    /// Set on the same terms as the other seams here — before the composition is built,
    /// because AVFoundation owns every compositor instance.
    private nonisolated(unsafe) static var _style: StageStyle = .default
    public static var style: StageStyle {
        get { seamLock.withLock { unsafe _style } }
        set { seamLock.withLock { unsafe _style = newValue } }
    }
    /// The observation log the pointer track is read from; `nil` draws no pointer.
    private nonisolated(unsafe) static var _observationLogURL: URL?
    public static var observationLogURL: URL? {
        get { seamLock.withLock { unsafe _observationLogURL } }
        set { seamLock.withLock { unsafe _observationLogURL = newValue } }
    }

    /// A reviewer's decisions to suppress the pointer, set before playback starts and never read
    /// from the observation log.
    private nonisolated(unsafe) static var _overrides: [CursorOverride] = []
    public static var overrides: [CursorOverride] {
        get { seamLock.withLock { unsafe _overrides } }
        set { seamLock.withLock { unsafe _overrides = newValue } }
    }
    /// **What survived editing, and where each surviving nanosecond came from.**
    ///
    /// `nil` means no edits — output time IS source time, which is the case every recording
    /// starts in and the reason a bug here hides until the first cut. Once a cut exists,
    /// `startRequest` is handed OUTPUT times while every observation record is stamped in
    /// SOURCE time, so the pointer and the camera must be looked up through this or they land
    /// by however much was removed before them. Set on the same terms as the seams below.
    private nonisolated(unsafe) static var _editTimeline: EditTimeline?
    public static var editTimeline: EditTimeline? {
        get { seamLock.withLock { unsafe _editTimeline } }
        set { seamLock.withLock { unsafe _editTimeline = newValue } }
    }

    /// A reviewer's decisions about where the camera frames — set on the same terms and for
    /// the same reason as `overrides`. Applied by `FramingPlan.framedClicks(with:)`, which
    /// consults them BEFORE the gate, so a re-derivation cannot replace an authored value.
    private nonisolated(unsafe) static var _framingOverrides: [FramingOverride] = []
    public static var framingOverrides: [FramingOverride] {
        get { seamLock.withLock { unsafe _framingOverrides } }
        set { seamLock.withLock { unsafe _framingOverrides = newValue } }
    }
    /// A person's changes to the derived zooms — where each starts, how long it lasts, whether
    /// it happens. Set on the same terms as the seams above. See `ZoomAdjustment` for why they
    /// are keyed on the click rather than on the block.
    private nonisolated(unsafe) static var _zoomAdjustments: [ZoomAdjustment] = []
    public static var zoomAdjustments: [ZoomAdjustment] {
        get { seamLock.withLock { unsafe _zoomAdjustments } }
        set { seamLock.withLock { unsafe _zoomAdjustments = newValue } }
    }

    /// The captions to burn in, in the recording's SOURCE time, or empty for none. Set on the
    /// same terms as the seams above.
    ///
    /// **Source time, and looked up through `sourceOffset(forOutput:)` like everything else
    /// here.** A track already retimed through the edit would be right until the next cut and
    /// wrong afterwards, in exactly the way `editTimeline`'s own comment describes. Retiming for
    /// a SIDECAR file is a different job with a different answer — see
    /// `CaptionTrack.retimed(through:)`, which the export uses and this does not.
    private nonisolated(unsafe) static var _captions = CaptionTrack()
    public static var captions: CaptionTrack {
        get { seamLock.withLock { unsafe _captions } }
        set { seamLock.withLock { unsafe _captions = newValue } }
    }
    /// How a burnt-in caption looks. Separate from `style`, which is the card's look: a person
    /// turning captions off should not have to give up their background.
    private nonisolated(unsafe) static var _captionStyle: CaptionStyle = .default
    public static var captionStyle: CaptionStyle {
        get { seamLock.withLock { unsafe _captionStyle } }
        set { seamLock.withLock { unsafe _captionStyle = newValue } }
    }
    /// Whether to draw them at all. False leaves `captions` in place, so turning burn-in off and
    /// on again does not discard a transcript that took a minute to produce.
    private nonisolated(unsafe) static var _burnsInCaptions = false
    public static var burnsInCaptions: Bool {
        get { seamLock.withLock { unsafe _burnsInCaptions } }
        set { seamLock.withLock { unsafe _burnsInCaptions = newValue } }
    }

    /// Text overlays, in the recording's SOURCE time. Set on the same terms as the seams above,
    /// and looked up the same way — see `captionOverlay(at:)`.
    ///
    /// No `burnsIn` twin: a person who put a word on the screen put it there on purpose, and a
    /// title that could be silently switched off would be a title nobody trusts is in the export.
    private nonisolated(unsafe) static var _texts = TextTrack()
    public static var texts: TextTrack {
        get { seamLock.withLock { unsafe _texts } }
        set { seamLock.withLock { unsafe _texts = newValue } }
    }

    /// Parts of the recording to hide. Set on the same terms as the seams above.
    private nonisolated(unsafe) static var _redactions = RedactionTrack()
    public static var redactions: RedactionTrack {
        get { seamLock.withLock { unsafe _redactions } }
        set { seamLock.withLock { unsafe _redactions = newValue } }
    }
    /// The arrows, boxes and ellipses a person drew over the recording — see `AnnotationTrack`.
    /// Anchored to the RECORDING, so they move with the camera rather than sitting still while
    /// the thing they point at slides away underneath them.
    private nonisolated(unsafe) static var _annotations = AnnotationTrack()
    public static var annotations: AnnotationTrack {
        get { seamLock.withLock { unsafe _annotations } }
        set { seamLock.withLock { unsafe _annotations = newValue } }
    }

    /// Whether pressed shortcuts are drawn as badges. **On by default**: the recorder writes
    /// `key` records for exactly this, the row has claimed the badges since Phase 3, and a
    /// recording with no approved shortcut in it draws nothing either way. The track itself
    /// is read from the observation log with the pointer's, not set from outside.
    private nonisolated(unsafe) static var _showsKeystrokes = true
    public static var showsKeystrokes: Bool {
        get { seamLock.withLock { unsafe _showsKeystrokes } }
        set { seamLock.withLock { unsafe _showsKeystrokes = newValue } }
    }

    /// How the drawn cursor looks. Set on the same terms as the seams above.
    private nonisolated(unsafe) static var _cursorStyle: CursorStyle = .default
    public static var cursorStyle: CursorStyle {
        get { seamLock.withLock { unsafe _cursorStyle } }
        set { seamLock.withLock { unsafe _cursorStyle = newValue } }
    }

    /// Where the camera sits, or `nil` for a recording without one. Set on the same terms as the
    /// seams above.
    private nonisolated(unsafe) static var _cameraStyle: CameraOverlayStyle?
    public static var cameraStyle: CameraOverlayStyle? {
        get { seamLock.withLock { unsafe _cameraStyle } }
        set { seamLock.withLock { unsafe _cameraStyle = newValue } }
    }
    /// The part of the recording used at all. Set on the same terms as the seams above.
    private nonisolated(unsafe) static var _crop: CropRect = .whole
    public static var crop: CropRect {
        get { seamLock.withLock { unsafe _crop } }
        set { seamLock.withLock { unsafe _crop = newValue } }
    }

    /// **The share of the output frame the recording occupies, so zoom depth is decided for
    /// the frame being exported rather than for the recording's shape.**
    ///
    /// `StagePlanner` fits and never crops, so a variant that is not the recording's own shape
    /// leaves bars and shrinks everything — a 16:9 recording covers about 0.32 of a 9:16 frame,
    /// and a control legible in landscape comes out a little over half the length in portrait.
    /// Until this seam existed, a portrait export inherited landscape's depths and looked it.
    ///
    /// **A plain `Double` rather than the `AspectVariant` it comes from, because the module graph
    /// says so**: this target cannot name `AspectVariant`. The app tier computes
    /// `variant.coverage(ofSourceAspect:)` and publishes the number, as it already does `crop`.
    ///
    /// **1 is the recording's own shape and the right value to start at** — not a "safe default"
    /// standing in for a measurement: a composition nobody has told about a variant is being
    /// asked to render the recording as recorded.
    private nonisolated(unsafe) static var _outputCoverage: Double = 1
    public static var outputCoverage: Double {
        get { seamLock.withLock { unsafe _outputCoverage } }
        set { seamLock.withLock { unsafe _outputCoverage = newValue } }
    }

    /// **How much of the derived zoom to use, everywhere at once.** 1 is what the gates
    /// decided; 0 is a recording that never zooms; 2 is the ceiling.
    ///
    /// The one control per-block adjustments could not stand in for — correcting forty blocks
    /// one at a time to say "less, everywhere" is a different act from saying it once — and
    /// a sensible ceiling. It is applied where the depth is DERIVED, so a person's own
    /// per-block adjustment still lands on top of it: the producer-value rule puts authored
    /// values after derived ones, and a dial that overrode them would have that backwards.
    private nonisolated(unsafe) static var _zoomIntensity: Double = FramingDepth.neutralIntensity
    public static var zoomIntensity: Double {
        get { seamLock.withLock { unsafe _zoomIntensity } }
        set { seamLock.withLock { unsafe _zoomIntensity = newValue } }
    }
    /// How fast the camera moves between framings — see `CameraPace`. A seam like
    /// `zoomIntensity`, and captured in `Settings` with it.
    private nonisolated(unsafe) static var _cameraPace: CameraPace = .standard
    public static var cameraPace: CameraPace {
        get { seamLock.withLock { unsafe _cameraPace } }
        set { seamLock.withLock { unsafe _cameraPace = newValue } }
    }
    /// Which of the composition's video tracks is the camera. **Set by whoever built the
    /// composition** — `CameraComposition.combine` returns it — because nothing about a track
    /// says what it is, and picking "the last video track" would break the moment a composition
    /// carried three.
    private nonisolated(unsafe) static var _cameraTrackID: CMPersistentTrackID?
    public static var cameraTrackID: CMPersistentTrackID? {
        get { seamLock.withLock { unsafe _cameraTrackID } }
        set { seamLock.withLock { unsafe _cameraTrackID = newValue } }
    }

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
        var annotations: AnnotationTrack
        var showsKeystrokes: Bool
        var cursorStyle: CursorStyle
        var cameraStyle: CameraOverlayStyle?
        var crop: CropRect
        var cameraTrackID: CMPersistentTrackID?
        // **The amount was missing, and so an export queued at one amount rendered at whatever
        // was set when it ran.** Found when the pace was added beside it.
        var zoomIntensity: Double
        var cameraPace: CameraPace
    }

    /// What the compositor would draw right now.
    public nonisolated static func settings() -> Settings {
        Settings(style: style, observationLogURL: observationLogURL, overrides: overrides,
                        editTimeline: editTimeline, framingOverrides: framingOverrides,
                        zoomAdjustments: zoomAdjustments, captions: captions,
                        captionStyle: captionStyle, burnsInCaptions: burnsInCaptions,
                        texts: texts, redactions: redactions, annotations: annotations,
                        showsKeystrokes: showsKeystrokes,
                        cursorStyle: cursorStyle,
                        cameraStyle: cameraStyle, crop: crop, cameraTrackID: cameraTrackID,
                        zoomIntensity: zoomIntensity, cameraPace: cameraPace)
    }

    /// Puts them all back. Every field, so a value captured before one was added cannot leave a
    /// stale static behind — which is the failure mode a partial restore has and a total one
    /// cannot.
    public nonisolated static func apply(_ settings: Settings) {
        style = settings.style
        observationLogURL = settings.observationLogURL
        overrides = settings.overrides
        editTimeline = settings.editTimeline
        framingOverrides = settings.framingOverrides
        zoomAdjustments = settings.zoomAdjustments
        captions = settings.captions
        captionStyle = settings.captionStyle
        burnsInCaptions = settings.burnsInCaptions
        texts = settings.texts
        redactions = settings.redactions
        annotations = settings.annotations
        showsKeystrokes = settings.showsKeystrokes
        cursorStyle = settings.cursorStyle
        cameraStyle = settings.cameraStyle
        crop = settings.crop
        cameraTrackID = settings.cameraTrackID
        zoomIntensity = settings.zoomIntensity
        cameraPace = settings.cameraPace
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
    private static func recordDroppedFrame(_ reason: Diagnostics.Refusal) {
        diagnosticsLock.withLock {
            unsafe _diagnostics.framesDropped += 1
            unsafe _diagnostics.refusals[reason, default: 0] += 1
        }
    }

    /// `framesDropped` counts `startRequest`'s failure paths, its leading guards and the
    /// `catch` around `render`. Compositor failures only: `AVPlayer` display-time drops and
    /// seek-cancelled requests never reach this file.
    public struct Diagnostics: Sendable {
        public internal(set) var framesDropped = 0

        /// **How many of each, because the total could not be acted on.** A count of dropped
        /// frames says something is wrong; it does not say whether the decode failed, this app
        /// forgot to publish a renderer, or the machine ran out of buffers — and those have
        /// different owners. Read after playback or an export.
        public internal(set) var refusals: [Refusal: Int] = [:]

        /// Why frames were refused. Six, and every one of them was reported as the same thing
        /// until 2026-09-16.
        public enum Refusal: String, Sendable, Hashable, CaseIterable {
            case noScreenTrack, noSourceBuffer, noRenderContext
            case noDestinationBuffer, noRenderer, renderThrew
        }

        /// The refusals that happened, worst first, as one line. **What a status line or a log
        /// can actually carry** — the dictionary is the record, this is the sentence.
        /// Empty string when nothing was refused, which is a fact and not an absence.
        public var refusalSummary: String {
            refusals.sorted { ($0.value, $0.key.rawValue) > ($1.value, $1.key.rawValue) }
                .map { "\($0.key.rawValue) x\($0.value)" }
                .joined(separator: ", ")
        }
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
    /// Where the source drew inside the capture buffer, per frame. `.unknown` until the log is
    /// read and for every recording whose log never said — which is every recording made before
    /// `ContentCropSample` existed, and is why an existing project renders unchanged.
    private nonisolated(unsafe) var contentCrops: ContentCropTrack = .unknown
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
        let cameraTrackID = Self.cameraTrackID
        // **Five separate refusals, each saying which it is.** They were one `guard` and one
        // error, so a console line saying the compositor refused a frame could not say why —
        // see `CompositorError`. Written as a nested function rather than five guards so the
        // counter and the `finish` stay in one place and cannot drift apart.
        func refuse(_ reason: CompositorError) {
            Self.recordDroppedFrame(reason.refusal)
            request.finish(with: reason)
        }
        guard let trackID = request.sourceTrackIDs
                .map(\.int32Value)
                .first(where: { $0 != cameraTrackID })
        else { return refuse(.noScreenTrack) }
        guard let source = request.sourceReadOnlyPixelBuffer(byTrackID: trackID)
        else { return refuse(.noSourceBuffer) }
        guard let context = unsafe renderContext
        else { return refuse(.noRenderContext) }
        guard let destination = context.newPixelBuffer()
        else { return refuse(.noDestinationBuffer) }
        guard let renderer = Self.renderer
        else { return refuse(.noRenderer) }
        // **The card is fitted to the CROPPED aspect, not the recording's.** `StagePlanner` fits
        // a rectangle inside the output, and handing it the uncropped size would letterbox a
        // cropped recording as though it were still 16:9 — the bars would be exactly the part
        // that was cropped away.
        let authored = Self.crop
        // **Two crops, composed, and the order is the whole behaviour.** `authored` is what a
        // person drew; `content` is where ScreenCaptureKit actually put the picture inside a
        // buffer it is not allowed to resize (see `ContentCropTrack`). A person draws on the
        // picture they can SEE, so their fractions are fractions of the window, not of the
        // buffer — `authored.within(content)`, never the reverse.
        let content = contentCrop(at: request.compositionTime)
        let crop = authored.within(content)
        let cropped = crop.size(ofSourceWidth: source.size.width,
                                sourceHeight: source.size.height)
        // **The ceiling is computed from the AUTHORED crop alone, and that is a cost decision.**
        // `loadedTracks(zoomCeiling:)` re-bakes the whole camera whenever the ceiling it is
        // handed differs from the one it baked under, and the comment there rested on the crop
        // being fixed for a composition — which the content crop is not. Feeding it a number
        // that moves would re-derive every zoom block on every frame of a window drag. What is
        // given up is a ceiling that is slightly too generous for the seconds a window was
        // smaller than its buffer; what is kept is a camera that is baked once.
        let authoredWidth = authored.size(ofSourceWidth: source.size.width,
                                          sourceHeight: source.size.height).width
        let basePlan = StagePlanner.plan(
            outputWidth: Int(context.size.width), outputHeight: Int(context.size.height),
            sourceWidth: cropped.width, sourceHeight: cropped.height,
            style: Self.style)
        // The camera first: the pointer's placement is computed THROUGH the resulting plan
        // (`StagePlanner.placement` maps by `RenderPlan.contentX/Y`), so a pointer drawn
        // against the un-zoomed plan would sit where the user never pointed.
        // The source's pixels across the card are what bound the zoom — see
        // `FramingDepth.zoomCeiling`. The AUTHORED width rather than the composed one, for the
        // reason given where `authoredWidth` is computed: a ceiling that moved with the window
        // would re-bake the camera on every frame of a resize.
        let aimed = cameraPlan(basePlan, at: request.compositionTime,
                               sourcePixelWidth: authoredWidth)
        let plan = RenderPlan(outputWidth: aimed.outputWidth, outputHeight: aimed.outputHeight,
                              card: aimed.card, cornerRadius: aimed.cornerRadius,
                              style: aimed.style,
                              pointer: pointerPlacement(at: request.compositionTime, in: aimed),
                              contentZoom: aimed.contentZoom,
                              contentCentre: aimed.contentCentre,
                              caption: captionOverlay(at: request.compositionTime),
                              texts: textOverlays(at: request.compositionTime),
                              redactions: redactedRegions(at: request.compositionTime),
                              cursorStyle: Self.cursorStyle,
                              // **A hidden camera produces no overlay at all**, rather than one
                              // the renderer then has to know to skip. Hiding is "not in this
                              // one" as distinct from "throw the footage away", and the
                              // cheapest place to honour it is before a plan carries it.
                              camera: cameraOverlay(
                                  at: request.compositionTime, basePlan: basePlan,
                                  sourcePixelWidth: authoredWidth,
                                  // The camera picture's own aspect, for the dodge's zone. Read
                                  // off the buffer's size rather than assumed: a rounded camera
                                  // is `width / aspect` tall and the zone must be the rectangle
                                  // actually drawn.
                                  cameraAspect: cameraTrackID
                                      .flatMap { request.sourceReadOnlyPixelBuffer(byTrackID: $0) }
                                      .map { Double($0.size.width) / Double(max($0.size.height, 1)) }
                                      ?? 1),
                              crop: crop,
                              keystroke: keystrokeBadge(at: request.compositionTime),
                              // Computed against `aimed` — the plan the camera has already
                              // moved — for the same reason the pointer is: an annotation
                              // placed against the un-zoomed plan would sit where nobody drew
                              // it on every frame the camera was in.
                              annotations: annotationOverlays(at: request.compositionTime,
                                                              in: aimed),
                              // The fade at a clip's start or end. Read through the same
                              // `editTimeline` static every other time conversion goes through,
                              // and against the OUTPUT offset — a fade is measured in what a
                              // viewer watches, not in what the recording contains.
                              cardOpacity: Self.cardOpacity(at: request.compositionTime))
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
            Self.recordDroppedFrame(.renderThrew)
            request.finish(with: error)
        }
    }

    /// Why a frame was refused.
    ///
    /// **These were one case called `notConfigured` and that cost a diagnosis.** A person
    /// reported a crash after burning in captions and replaying, and the console said
    /// `<<<< CustomVideoCompositor >>>> signalled err=-12784` — which is AVFoundation
    /// reporting that this compositor called `finish(with:)`. Five different things reach
    /// that line and they are five different defects: a composition with no screen track is a
    /// build error in the instruction, an unreadable source buffer is a decode failure, a
    /// missing render context is an ordering bug in AVFoundation's own callbacks, a refused
    /// destination buffer is memory pressure, and a nil renderer is this app failing to
    /// publish one. One name for all five meant the only honest thing to say about that log
    /// was "the compositor refused a frame", which is where the investigation stopped.
    ///
    /// `Equatable` so callers can compare rather than pattern-match.
    public enum CompositorError: Error, Equatable {
        /// No track in the request that is not the camera. The composition names tracks this
        /// compositor never gets, or names only the camera.
        case noScreenTrack
        /// The screen track is there and its pixels are not. A decode that did not land.
        case noSourceBuffer
        /// `renderContextChanged` has not arrived, or arrived after the first request.
        case noRenderContext
        /// The render context refused a destination buffer — its pool is exhausted.
        case noDestinationBuffer
        /// Nothing published a renderer. This app's own fault and the one worth an alarm.
        case noRenderer

        /// **Kept so the previous spelling still compiles and still means something.** Every
        /// one of the five was this; code and tests that compared against it were not wrong,
        /// they were coarse.
        public static let notConfigured = CompositorError.noRenderer

        /// Every refusal a guard in `startRequest` can raise. Named so a test can assert that
        /// the `catch` around `render` keeps a counter none of these uses.
        public static let allRefusals: [CompositorError] =
            [.noScreenTrack, .noSourceBuffer, .noRenderContext, .noDestinationBuffer, .noRenderer]

        /// The counter this refusal belongs to. Total rather than partial, so a case added
        /// here cannot quietly stop being counted.
        var refusal: Diagnostics.Refusal {
            switch self {
            case .noScreenTrack: return .noScreenTrack
            case .noSourceBuffer: return .noSourceBuffer
            case .noRenderContext: return .noRenderContext
            case .noDestinationBuffer: return .noDestinationBuffer
            case .noRenderer: return .noRenderer
            }
        }
    }

    // MARK: - the pointer track

    /// `.drawn(p)` becomes a placement in `plan`'s output-pixel space with `ClickTrack`'s ripple
    /// phase at that instant; every other `PointerReading` draws nothing. Cases are named, not
    /// defaulted, so a new one is a compile error. `public` as the test seam, since
    /// `startRequest(_:)` takes a type only AVFoundation can construct.
    /// How visible the recording is at this composition time.
    ///
    /// `1` with no edit and `1` past the end, for `EditTimeline.visibility(atOutput:)`'s reason:
    /// a frame nobody can see has nothing to be wrong about, and an optional here would put the
    /// same `?? 1` at every call site.
    nonisolated static func cardOpacity(at compositionTime: CMTime) -> Double {
        guard compositionTime.isValid,
              let timeline = editTimeline, timeline.hasAnyFade,
              let offset = Nanoseconds(rationalSeconds: compositionTime.value,
                                       timescale: compositionTime.timescale)
        else { return 1 }
        return timeline.visibility(atOutput: offset)
    }

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
        guard let timeline = editTimeline else { return offset }
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
        case .drawn(let drawnPoint, let shape, let hotspot):
            let style = Self.cursorStyle
            // **The loop, before the placement and after the spring.** It reads the presented
            // position — the spring-followed one — so the glide home starts from where the
            // cursor is DRAWN, not from a recorded sample the spring has not reached yet;
            // starting from the latter would make the cursor jump backward onto its own trail
            // at the instant the glide began. Progress is in OUTPUT time, because the last
            // frame that has to match the first is the export's last frame, not the take's.
            let point: NormalizedPoint
            if style.loopsToStart,
               let duration = outputDuration(),
               let progress = CursorLoop.progress(
                   outputOffset: outputOffset, outputDuration: duration,
                   // The same fallback the smear uses, for the same reason: a compositor
                   // asked before AVFoundation has handed it a render context has no better
                   // number, and 1/60 is what every export in this app asks for.
                   frameDuration: (unsafe renderContext)?.videoComposition.frameDuration.seconds
                       ?? 1.0 / 60),
               let home = openingPosition(pointer: pointer, anchor: anchor) {
                point = CursorLoop.position(actual: drawnPoint, home: home, progress: progress)
            } else {
                point = drawnPoint
            }
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
                                          smearAngle: smear?.angle ?? 0,
                                          // The press comes from the same track the ripple
                                          // does, at the same instant, so the two cannot
                                          // disagree about which click is current.
                                          pressScale: click?.pressScale(at: instant) ?? 1)
        case .blind, .suppressedByReviewer, .noObservationYet:
            return nil
        }
    }

    /// The camera on this frame, or `nil` when the recording has none or it is hidden.
    ///
    /// **A hidden camera produces no overlay at all**, rather than one the renderer then has to
    /// know to skip. Hiding is the switch for "not in this one" as distinct from "throw
    /// the footage away", and the cheapest place to honour it is before a plan carries it.
    ///
    /// **With `avoidsCursor` on, the style's placement is replaced by the dodge schedule's.**
    /// The schedule is baked on the first frame that asks and reused — see `dodgeSchedule` —
    /// so preview, export and scrubbing all read the same moves. `public` for the reason
    /// `cameraPlan` and `pointerPlacement` are: it is the seam a test can reach without
    /// standing up AVFoundation.
    public func cameraOverlay(at compositionTime: CMTime, basePlan: RenderPlan,
                              sourcePixelWidth: Int?, cameraAspect: Double) -> CameraOverlay? {
        guard let style = Self.cameraStyle, !style.isHidden else { return nil }
        guard style.avoidsCursor,
              compositionTime.isValid,
              let outputOffset = Nanoseconds(rationalSeconds: compositionTime.value,
                                             timescale: compositionTime.timescale),
              let schedule = dodgeSchedule(style: style, basePlan: basePlan,
                                           sourcePixelWidth: sourcePixelWidth,
                                           cameraAspect: cameraAspect)
        else { return CameraOverlay(style: style) }
        guard !schedule.isStill else { return CameraOverlay(style: style) }
        let placed = schedule.placement(at: outputOffset)
        // `changing(x:y:)` clears the preset, which is right: while dodging the camera is not
        // on one, and `rect` reads the coordinates when there is no preset.
        return CameraOverlay(style: style.changing(x: placed.x, y: placed.y))
    }

    /// **The dodge schedule, baked once per (style, output, aspect, length) and reused.**
    ///
    /// Baking samples the presented cursor at 30 Hz across the whole output, through the same
    /// `cameraPlan` → `pointerPlacement` path a frame takes, so the cursor's place in the frame
    /// includes the zoom in force at each instant — a dodge computed against the un-zoomed frame
    /// would react to where the cursor is NOT. Thirty samples a second over a ten-minute video
    /// is eighteen thousand lookups, each a binary search or a spline evaluation; measured well
    /// under the first frame's budget.
    ///
    /// **Computed outside the lock, stored inside it.** `cameraPlan` and `pointerPlacement`
    /// each take `lock` themselves, so a bake under `dodgeLock` that called them would be fine —
    /// but a bake under `lock` would deadlock. The two locks are separate for that reason, and
    /// a race where two frames bake at once produces two identical schedules, the second of
    /// which wins; that costs a bake and corrupts nothing.
    private func dodgeSchedule(style: CameraOverlayStyle, basePlan: RenderPlan,
                               sourcePixelWidth: Int?, cameraAspect: Double)
    -> CameraDodge.Schedule? {
        guard let duration = outputDuration() else { return nil }
        let key = DodgeKey(style: style, outputWidth: basePlan.outputWidth,
                           outputHeight: basePlan.outputHeight,
                           aspectThousandths: Int((cameraAspect * 1000).rounded()),
                           duration: duration)
        if let cached = dodgeLock.withLock({ unsafe dodgeKey == key ? unsafe dodge : nil }) {
            return cached
        }

        let perSecond = 30
        let seconds = Double(duration.rawValue) / 1_000_000_000
        let count = Int((seconds * Double(perSecond)).rounded(.down)) + 1
        var samples: [CameraDodge.Sample] = []
        samples.reserveCapacity(count)
        // `i / 30`, not an accumulating `t += 1/30`: the accumulation drifts by a few
        // ulps per step, and a sample that drifted across a 1/600 s tick would be a sample
        // taken at a different frame from the one the schedule says it was.
        for i in 0..<count {
            let t = Double(i) / Double(perSecond)
            let time = CMTime(seconds: t, preferredTimescale: 600)
            let aimed = cameraPlan(basePlan, at: time, sourcePixelWidth: sourcePixelWidth)
            let placement = pointerPlacement(at: time, in: aimed)
            samples.append(CameraDodge.Sample(offset: Nanoseconds(Int64(t * 1e9)),
                                              x: placement?.x, y: placement?.y))
        }
        let built = CameraDodge.schedule(samples: samples, style: style,
                                         outputWidth: basePlan.outputWidth,
                                         outputHeight: basePlan.outputHeight,
                                         sourceAspect: cameraAspect)
        dodgeLock.withLock {
            unsafe dodge = built
            unsafe dodgeKey = key
        }
        return built
    }

    private struct DodgeKey: Hashable {
        let style: CameraOverlayStyle
        let outputWidth: Int
        let outputHeight: Int
        let aspectThousandths: Int
        let duration: Nanoseconds
    }
    private let dodgeLock = NSLock()
    // Both guarded by `dodgeLock`; every access is inside `dodgeLock.withLock`.
    private nonisolated(unsafe) var dodge: CameraDodge.Schedule?
    private nonisolated(unsafe) var dodgeKey: DodgeKey?

    /// Where the drawn cursor is at the video's FIRST frame — the place the loop glides back
    /// to. `nil` when the pointer has no answer there (blind, suppressed, or not yet observed),
    /// in which case there is nothing to loop to and the cursor is left alone; inventing a
    /// home for it would send it gliding to a point nobody recorded.
    private func openingPosition(pointer: PointerTrack, anchor: EpochAnchor) -> NormalizedPoint? {
        guard let sourceStart = Self.sourceOffset(forOutput: Nanoseconds(0)) else { return nil }
        guard case .drawn(let point, _, _) = pointer.presentedPosition(
            at: anchor.instant(atOffset: sourceStart)) else { return nil }
        return point
    }

    /// How long the OUTPUT is — the edit's length when there is an edit, otherwise the end of
    /// the composition's last instruction. `nil` when neither is known, which is what a
    /// compositor asked before AVFoundation has handed it a render context answers.
    ///
    /// **Not a third static seam.** The handoff warns that `outputCoverage` and `zoomIntensity`
    /// lie unless the app publishes them; a duration static would be a third thing to forget.
    /// Both sources here are already in the compositor's hands — `editTimeline` is checked
    /// against every export, and the render context arrives before the first frame.
    private func outputDuration() -> Nanoseconds? {
        if let timeline = Self.editTimeline { return timeline.outputDuration }
        guard let context = unsafe renderContext,
              let last = context.videoComposition.instructions.last else { return nil }
        let end = CMTimeRangeGetEnd(last.timeRange)
        guard end.isValid, end.isNumeric else { return nil }
        return Nanoseconds(rationalSeconds: end.value, timescale: end.timescale)
    }

    /// The shortcut badge on screen at an OUTPUT time, or `nil`. Converted to source time and
    /// then to the recorder's clock exactly as the pointer is: a press is an observation.
    public func keystrokeBadge(at compositionTime: CMTime) -> KeystrokeBadge? {
        guard Self.showsKeystrokes, compositionTime.isValid,
              let outputOffset = Nanoseconds(rationalSeconds: compositionTime.value,
                                             timescale: compositionTime.timescale),
              let offset = Self.sourceOffset(forOutput: outputOffset) else { return nil }
        let (_, _, anchor, _) = loadedTracks()
        guard let anchor, let track = lock.withLock({ unsafe keystrokes }) else { return nil }
        return track.badge(at: anchor.instant(atOffset: offset))
    }

    /// The part of the buffer the SOURCE drew into at an output time — `.whole` when the log
    /// never said, which is every recording made before `ContentCropSample` existed.
    ///
    /// Converted to source time and then to the recorder's clock exactly as the pointer is: the
    /// content rect is an observation of the capture, so a cut that reorders the recording has
    /// to move it with everything else. A crop read in output time would, after the first cut,
    /// crop each frame to where the window was at some other moment.
    ///
    /// `public` for `pointerPlacement`'s reason: `startRequest(_:)` takes a type only
    /// AVFoundation constructs, so this is the seam a test can reach.
    public func contentCrop(at compositionTime: CMTime) -> CropRect {
        guard compositionTime.isValid,
              let outputOffset = Nanoseconds(rationalSeconds: compositionTime.value,
                                             timescale: compositionTime.timescale),
              let offset = Self.sourceOffset(forOutput: outputOffset) else { return .whole }
        let (_, _, anchor, _) = loadedTracks()
        guard let anchor else { return .whole }
        return lock.withLock { unsafe contentCrops }.crop(at: anchor.instant(atOffset: offset))
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
    /// blur automatic and the cursor's a knob would be two answers to one question. There is no
    /// `CursorStyle` field for that reason; `StageCompositor.shutterFraction` governs both.
    ///
    /// **The card's pan is added to the cursor's own travel**, because the smear is displacement
    /// across the FRAME and the frame is moving too: a cursor held still while the camera pans
    /// crosses the picture just as fast as one moving over a still camera.
    /// `plan.motionBlur.panRadius` is half the card's travel, so the whole is twice it.
    ///
    /// **The zoom's radial term is left out**, a real omission rather than an oversight: it
    /// varies with distance from the card's centre, so a point sample would need its own offset
    /// threaded through, and at the cursor it is a fraction of a pixel except during a whip zoom
    /// with the cursor at the frame's edge. Named so it is a known gap, not a discovery.
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
    /// smear reads as a defocus and none reads as judder. A motion-blur setting
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
        guard Self.burnsInCaptions, !(Self.captions.isEmpty) else { return nil }
        let outputOffset = Nanoseconds(CMTimeConvertScale(
            compositionTime, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value)
        guard let source = Self.sourceOffset(forOutput: outputOffset),
              let cue = Self.captions.cue(at: source) else { return nil }
        let style = Self.captionStyle
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
        guard !(Self.texts.isEmpty) else { return [] }
        let outputOffset = Nanoseconds(CMTimeConvertScale(
            compositionTime, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value)
        guard let source = Self.sourceOffset(forOutput: outputOffset) else { return [] }
        return Self.texts.items(at: source)
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
        guard !(Self.redactions.isEmpty) else { return [] }
        let outputOffset = Nanoseconds(CMTimeConvertScale(
            compositionTime, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value)
        guard let source = Self.sourceOffset(forOutput: outputOffset) else {
            return Self.redactions.items
                .filter { $0.coversEverything && !$0.region.isEmpty }.map(\.region)
        }
        return Self.redactions.regions(at: source)
    }

    /// The annotations on screen at an OUTPUT time, with their points mapped into output pixels.
    ///
    /// **Two conversions, and they are different ones.** The TIME goes from output back to
    /// source, for the reason `captionOverlay(at:)` gives — the track is stamped in source time
    /// and a cut moves everything after it. The SPACE goes the other way, from the recording's
    /// normalised coordinates into the frame, through `RenderPlan.contentX/contentY` — the same
    /// mapping `StagePlanner.placement` puts the drawn cursor through. Doing the second one by
    /// hand here is how a pointer and an arrow would come to disagree about where the same click
    /// was, which is `1a98402`'s class of defect arriving through a different door.
    ///
    /// Returns none when the output time cannot be mapped, unlike `redactedRegions(at:)` which
    /// falls back to hiding everything. The asymmetry is deliberate and it is about what each
    /// failure costs: a missing arrow is a missing hint, and a missing redaction is a leak.
    private func annotationOverlays(at compositionTime: CMTime,
                                    in plan: RenderPlan) -> [AnnotationOverlay] {
        guard !(Self.annotations.isEmpty) else { return [] }
        let outputOffset = Nanoseconds(CMTimeConvertScale(
            compositionTime, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value)
        guard let source = Self.sourceOffset(forOutput: outputOffset) else { return [] }
        return Self.annotations.items(at: source).compactMap { item in
            let state = item.animationState(at: source)
            return AnnotationOverlay(
                shape: item.shape,
                startX: plan.contentX(ofNormalised: item.startX),
                startY: plan.contentY(ofNormalised: item.startY),
                endX: plan.contentX(ofNormalised: item.endX),
                endY: plan.contentY(ofNormalised: item.endY),
                style: item.style.clamped,
                opacity: state.opacity, scale: state.scale,
                // Carried through: an overlay built without it is a callout with nothing to say,
                // which `AnnotationOverlay.isEmpty` treats as nothing to draw.
                text: item.text, imageName: item.imageName)
        }
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
                if let url = Self.observationLogURL,
                   let built = try? Self.buildTracks(from: url, overrides: Self.overrides,
                                                            framingOverrides: Self.framingOverrides) {
                    unsafe pointerTrack = built.pointer
                    unsafe pathMovement = built.movement
                    unsafe clickTrack = built.click
                    unsafe camera = built.camera
                    unsafe cameraCeiling = built.camera.zoomCeiling
                    unsafe keystrokes = built.keystrokes
                    unsafe logAnchor = built.anchor
                    unsafe contentCrops = built.contentCrops
                }
            }
            let wanted = (Self.cursorStyle).movement
            if unsafe pathMovement != wanted, let existing = unsafe pointerTrack {
                unsafe pointerTrack = existing.moving(wanted)
                unsafe pathMovement = wanted
            }
            // A pace changed since the tracks were built re-bakes the camera here, for the reason
            // a changed cursor movement re-derives the path just above.
            let pace = Self.cameraPace
            if let current = unsafe camera, current.pace != pace {
                unsafe camera = current.pacing(pace)
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
            keystrokes: KeystrokeTrack, movement: PointerPath.Tuning.Movement,
            contentCrops: ContentCropTrack) {
        let lines = try JSONLReader.linesOfFile(at: url).lines
        var samples: [PointerSample] = []
        var blindIntervals: [BlindInterval] = []
        var buttonEvents: [ButtonEvent] = []
        var presses: [KeystrokeTrack.Press] = []
        var anchor: EpochAnchor?
        var planEntries: [FramingPlan.Entry] = []
        var contentCrops: [ContentCropSample] = []
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
            case "contentCrop":
                // **Read in the same pass as everything else, and not lazily.** A second pass
                // over the log to find these would decode every line twice for a record that
                // occurs a handful of times in a recording.
                contentCrops.append(try ObservationLog.decode(line) as ContentCropSample)
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
        let movement = (cursorStyle).movement
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
                                   pointerFallbackRevision: plan.fallbackRevision),
            coverage: outputCoverage, intensity: zoomIntensity)
        // `unsafe`: `zoomAdjustments` is a `nonisolated(unsafe)` static, read here under the
        // same "published before playback starts" guarantee as every other seam on this type.
        // **The presented cursor is what the camera follows inside a zoom** — the same
        // reading the renderer draws, so the camera and the drawn pointer agree about where
        // the person is. `Framing` cannot name `PointerTrack`, so it arrives as a function.
        let camera = CameraMotion(blocks: zoomAdjustments.applied(to: derived),
                                  cursor: { instant in
            if case .drawn(let point, _, _) = pointer.presentedPosition(at: instant) { return point }
            return nil
        }, pace: cameraPace)
        return (pointer: pointer, click: click, anchor: anchor, camera: camera,
                keystrokes: KeystrokeTrack(presses: presses), movement: movement,
                contentCrops: ContentCropTrack(samples: contentCrops))
    }
}
