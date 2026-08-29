import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers
// Both halves of the runnable tier, split in Phase 3A-4: `Compositing` for the
// compositor and the exporter, `Capture` for `ObservationWriter`'s log paths. The product
// this app target links is `SoredemoHeadless`, which vends both.
import Capture
import Geometry
import Overlays
import Compositing
import Framing
import Project
import Render
import Timeline
import Variants
import SwiftUI

/// A window hosting a preview and an Export button. Standard SwiftUI with no hand-rolled glass:
/// standard components get Liquid Glass automatically and respond to the system-level Liquid
/// Glass slider, which a custom surface does not.
struct StageWindow: View {
    /// Where the self-view was left during the recording, so the stage opens with the camera
    /// there rather than back at the default — see `CameraSelfView`.
    var initialCameraStyle: CameraOverlayStyle = .default
    /// How much later than the screen the camera began. Measured by the recorder; zero for a
    /// project opened from disk, which is a gap this does not close — see the doc comment on
    /// `CameraComposition.combine`.
    var cameraStartOffsetNanos: Int64 = 0
    @State private var player: AVPlayer?
    /// The asset the current item was built from. Held because `AVAudioMix` addresses that
    /// asset's tracks, and after a cut the item's asset is a composition rather than the file.
    @State private var playingAsset: AVAsset?
    /// The video track's thumbnails. Owned here so a cache is not discarded on every edit.
    @State private var filmstrip = Filmstrip()
    /// Where the camera sits on the stage. Authored, and saved with the rest of the look.
    @State private var cameraStyle = CameraOverlayStyle.default
    /// One-shot, because `initialCameraStyle` seeds `cameraStyle` and a saved project's own
    /// value must win over it — the load runs after this and would otherwise be overwritten.
    @State private var hasSeededCameraStyle = false
    /// The part of the recording used at all, and whether its handles are showing.
    @State private var crop = CropRect.whole
    @State private var isCropping = false
    @State private var failure: String?
    // MARK: - export-basic
    @State private var exportStatus: String?
    // MARK: - review-ui
    /// Every framing decision the gate made, and the reviewer's own. Owned here rather than
    /// by the inspector so it survives the inspector being closed.
    @State private var review = FramingReviewModel()
    /// The stage's look. Owned here beside `review` so a change survives the inspector being
    /// closed, and so both the preview and the export read the same chosen style.
    @State private var stageStyle = StageStyleModel()
    /// The output shape. Drives the preview as well as the export: a person choosing Portrait
    /// and then seeing a landscape preview has been shown the wrong thing.
    @State private var variant = AspectVariant.landscape
    /// Whether the shape on screen is one a person picked or restored, rather than the
    /// starting value. Nothing reads it yet — it is what a future default would have to
    /// consult, and it is set at both the places that could make a choice, so adding that
    /// default is a one-line change rather than an audit of who assigns `variant`.
    @State private var chosenShapeDeliberately = false
    /// How loud each recorded source is in the export. Two sources, because the master keeps
    /// system audio and the microphone apart — see `AudioMix`.
    @State private var audioMix = AudioMix.unchanged
    /// Noise removal on the microphone track. **`nil` is off**, and off is the default: this
    /// rewrites what a person hears, and a recorder that quietly processed everybody's voice
    /// would be making a decision that is not its to make.
    @State private var noiseReduction: NoiseReduction.Settings?
    /// What the last attempt to clean the microphone did, or why it could not. Shown, never
    /// swallowed — a person who turned this on and heard no difference is owed the reason.
    @State private var noiseReductionNote: String?
    /// The cleaned microphone, once it exists. Rebuilt when the settings change; cleared when
    /// the feature is turned off.
    @State private var cleanedMicrophone: URL?
    /// Each audio track's integrated loudness, by index — see `Loudness`. Measured lazily, the
    /// first time levelling is asked for, because it decodes the whole audio track and most
    /// recordings are never levelled. Cleared when a different recording is loaded.
    @State private var measuredLoudness: [Int: Double] = [:]
    /// The music bed under the recording — see `MusicBed`. Its file lives in the package, so
    /// this is a filename and the URL is derived where it is needed.
    @State private var music = MusicBed.none
    /// The composition's music track, and the envelope it follows. Both are rebuilt with the
    /// composition rather than per frame: the track is a track and the envelope is a volume
    /// automation, and `AVAudioMix` takes them together.
    @State private var musicTrackID: CMPersistentTrackID?
    /// Why a chosen piece did not become the bed, or `nil`. Reported rather than swallowed: a
    /// person who chose music and got silence is owed the reason.
    @State private var musicFailure: String?
    // MARK: - project
    /// Where this recording has been saved, if it has. `nil` is a scratch recording, which is
    /// what "Save" turns into a project and what makes closing worth asking about.
    @State private var savedPackage: URL?
    /// The edit as it was when last saved, so "has anything changed" compares against what is
    /// on disk rather than against nothing.
    @State private var savedEdit = EditState.untouched
    @State private var projectStatus: String?
    // MARK: - basic-edit
    /// What survives editing. **Replaced a pair of trim sliders**, which could express one
    /// kept span and nothing else: no cut in the middle, no seeing where a cut was made, no
    /// undo. Owned here so it survives the inspector being closed.
    @State private var timeline = TimelineEditorModel()
    /// Bumped when an edit is committed, to rebuild the composition against the cut asset.
    @State private var editRevision = 0
    @State private var isReviewShown = true
    @State private var inspectorTab = InspectorTab.project
    /// How tall the timeline area is, remembered between launches — see the divider's comment.
    @AppStorage("timelineHeight") private var timelineHeight: Double = 210
    @AppStorage("timelineCollapsed") private var isTimelineCollapsed = false

    /// The band the timeline may be dragged within. A floor because a strip shorter than its
    /// tracks is a strip nothing can be aimed at; a ceiling because a timeline taller than the
    /// preview is an editor that cannot show what it is editing.
    static let minimumTimelineHeight: Double = 150
    static let maximumTimelineHeight: Double = 480
    /// What a GIF export would be. Held even while exporting MP4, so a person who switches the
    /// save panel's format popup does not find the options reset to defaults.
    @State private var gifSettings = GIFSettings.balanced
    /// How many bits the MP4 export gets. Held here beside `gifSettings` for its reason — the
    /// save panel is presented from this window and must not find the choice reset.
    @State private var quality = ExportQuality.best
    /// How large the exported picture is, and what it is written as. Held beside `quality` for
    /// its reason — the save panel must not find them reset.
    // **The recording's own size, not 1080p.** Measured: a 3024×1964 Retina capture exported
    // at the 1080p default came out 1662×1080, six pixels in ten discarded before the card's
    // inset discarded more — the softness every review of the export complained about, and
    // the only control that could undo it defaulted to the wrong rung. `available` lists
    // `.matchRecording` first for the reason `ExportResolution` gives; the default agrees.
    @State private var resolution = ExportResolution.matchRecording
    @State private var codec = ExportCodec.h264
    /// The recording's own short side in pixels, so `Match Recording` has something to match.
    /// Read from the asset when it loads; 1080 until then, which is what the export used to be
    /// pinned to anyway.
    @State private var recordingShortSide = 1080
    /// The recording's own pixel size. **Both dimensions, because a SHAPE needs both** — the
    /// short side alone sizes an output but cannot say what shape the recording is, and
    /// `AspectVariant.matching(width:height:)` is what removes the pillarbox a laptop
    /// recording gets in every one of the three presets.
    @State private var recordingSize = (width: 1920, height: 1080)
    /// How much of the derived zoom to use, over the whole recording. **One dial, because
    /// correcting forty blocks one at a time to say "less, everywhere" is a different act from
    /// saying it once** — and because per-block adjustments still land on top of it, so a person
    /// who has tuned three zooms by hand does not lose them by moving this.
    @State private var zoomIntensity = FramingDepth.neutralIntensity

    /// **The share of the output frame the recording occupies in the chosen shape**, which
    /// is what `StageCompositor.outputCoverage` needs to decide zoom depth for the frame
    /// being exported rather than for the recording's own shape.
    ///
    /// **Computed from the CROPPED size, not the recorded one.** Cropping changes the
    /// source's aspect, so a crop re-frames every zoom exactly as a variant change does; a
    /// coverage read off the recorded size would go stale the moment somebody cropped.
    private var outputCoverage: Double {
        let cropped = crop.size(ofSourceWidth: recordingSize.width,
                                sourceHeight: recordingSize.height)
        guard cropped.width > 0, cropped.height > 0 else { return 1 }
        return variant.coverage(ofSourceAspect: Double(cropped.width) / Double(cropped.height))
    }
    /// How many frames a second the export writes, and what the recording itself has. Matching
    /// by default, because a capture's rate is a decision somebody already made.
    @State private var frameRate = ExportFrameRate.matchRecording
    @State private var recordingFrameRate = 60
    /// The captions. Owned here beside `stageStyle` so a change survives the inspector being
    /// closed, and so the preview and the export read the same track.
    @State private var captions = CaptionsModel()
    /// Titles and notes drawn over the picture. Owned here beside `captions` for the same reason.
    @State private var texts = TextOverlaysModel()
    /// Parts of the recording a person has hidden.
    @State private var redactions = RedactionsModel()
    @State private var annotations = AnnotationsModel()

    /// What the inspector is showing. See `inspector` for why there are two.
    enum InspectorTab: String, CaseIterable, Hashable {
        case project, selection, captions, transcript, text, hide, mark

        var title: String {
            switch self {
            case .project: "Project"
            case .selection: "Zooms"
            case .captions: "Overlays"
            case .transcript: "Transcript"
            case .text: "Text"
            case .hide: "Hide"
            case .mark: "Mark"
            }
        }

        /// The tab's icon, and its lane's colour when selected — so the Text tab and the Text
        /// track on the timeline are visibly the same thing.
        var icon: String {
            switch self {
            case .project: "slider.horizontal.3"
            case .selection: "plus.magnifyingglass"
            case .captions: "captions.bubble"
            case .transcript: "text.quote"
            case .text: "textformat"
            case .hide: "eye.slash"
            case .mark: "arrow.up.right"
            }
        }

        var tint: Color {
            switch self {
            case .project: Theme.accent
            case .selection: Theme.Lane.zoom
            case .captions: Theme.Lane.caption
            // **No lane colour, because the transcript is not a lane.** It is a second way of
            // addressing the clips — a sentence names a span of the recording the way a
            // selection does — so it takes the app's own accent rather than borrowing the
            // caption lane's and implying it edits captions.
            case .transcript: Theme.accent
            case .text: Theme.Lane.text
            case .hide: Theme.Lane.hide
            case .mark: Theme.Lane.mark
            }
        }
    }
    /// Bumped whenever an override changes, to rebuild the composition. **The preview has to
    /// move**: the completion rule says a row is not done while the behaviour its name claims
    /// is not observable in the product, and an override that only changed a list would not
    /// be a review surface — it would be a form.
    @State private var reviewRevision = 0
    let mediaURL: URL
    /// What a saved project decided, applied once when this window loads. `nil` for a fresh
    /// recording, which is the common case.
    let pendingEdit: EditState?
    /// The camera's file beside the recording, or `nil` when there is none. Passed in rather
    /// than derived here: the recorder knows whether a camera ran, and a window that guessed by
    /// probing for a filename would show camera controls for a file left by an earlier attempt.
    var cameraURL: URL?

    /// **The DEFAULT output size** — `AspectVariant.landscape` at a 1920 longest edge — kept
    /// as constants because the render-parity check in
    /// `scripts/cross-boundary-digest-probe.swift` reads them directly, and a check whose
    /// dimensions moved with a picker would be checking a different thing each run.
    ///
    /// The live preview and the export both use `size(for:)` below, so a person who chooses
    /// Portrait sees and exports Portrait. These two stay the landscape answer and are
    /// derived from the same function rather than written out twice.
    static let outputWidth = AspectVariant.landscape.dimensions(longestEdge: 1920).width
    static let outputHeight = AspectVariant.landscape.dimensions(longestEdge: 1920).height

    /// **Re-rendered at the variant's own dimensions, never cropped from the landscape one.**
    /// `StagePlanner` fits and never fills, so a portrait export of a landscape recording
    /// letterboxes rather than cutting the sides off — the part of the screen the demo was
    /// happening in is often exactly what a crop would remove.
    /// **The export size, which used to be the constant 1920.** Measured on a real recording:
    /// the capture was 3024×1964 and every export came out 1920×1080, so six pixels in ten were
    /// thrown away and there was no control that could ask for them back. `ExportResolution`
    /// picks by short side — a native editor's choice, and the only one that describes a portrait
    /// output as well as a landscape one.
    static func size(for variant: AspectVariant, resolution: ExportResolution,
                     recordingShortSide: Int) -> (width: Int, height: Int) {
        let shape = variant.dimensions(longestEdge: 1920)
        let aspect = Double(shape.width) / Double(max(shape.height, 1))
        return resolution.size(forAspect: aspect, recordingShortSide: recordingShortSide)
    }

    var body: some View {
        // **No sidebar.** It held one row — the recording's filename — which is a whole column
        // spent on a label. The filename is the window's TITLE now, with `navigationDocument`
        // giving it the proxy icon and path popup every document window on this system has.
        // a Swift recorder's editor is `HSplitView { preview + timeline | inspector }` and a native editor's
        // left column is a media browser with content in it; neither spends a column on a name.
        //
        // **The timeline sits under the preview**, where every editor in
        // `../opensource/Screen Record Opensource/` puts it: a timeline is read along its length
        // while watching the picture above it, and an inspector is read down a column.
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                CanvasBar(variant: $variant, crop: $crop, isCropping: $isCropping,
                          outputWidth: Self.size(for: variant, resolution: resolution,
                                recordingShortSide: recordingShortSide).width,
                          outputHeight: Self.size(for: variant, resolution: resolution,
                                recordingShortSide: recordingShortSide).height,
                          onChange: { reviewRevision += 1 })
                Divider().overlay(Theme.Line.hairline)
                Group {
                    if let player {
                        PreviewView(player: player)
                    } else if let failure {
                        ContentUnavailableView("Could not build the preview",
                                               systemImage: "exclamationmark.triangle",
                                               description: Text(failure))
                    } else {
                        // **Named, not a bare spinner.** The wait here is a decode: the first
                        // frame of a 4K recording, and then the motion pass behind it. A
                        // spinner alone in a black rectangle reads as something having gone
                        // wrong.
                        VStack(spacing: Space.snug) {
                            ProgressView()
                            Text("Loading the recording\u{2026}")
                                .font(Type.detail).foregroundStyle(.secondary)
                        }
                    }
                }
                // **Both axes, and only one of them was here.** With `maxHeight` alone this
                // container took the width of whatever was inside it — a `ProgressView` is a few
                // points across — and `Theme.Surface.preview` painted that: a tall black sliver
                // down the middle of the editor while a recording loaded. The player branch hid
                // it, because an `NSViewRepresentable` expands on its own.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.Surface.preview)
                // Handles for whatever the inspector is editing — see `PreviewOverlay`.
                .overlay {
                    let size = Self.size(for: variant, resolution: resolution,
                                recordingShortSide: recordingShortSide)
                    PreviewOverlay(outputWidth: size.width, outputHeight: size.height,
                                   texts: texts, redactions: redactions, tab: inspectorTab,
                                   onChange: { reviewRevision += 1 },
                                   cameraStyle: $cameraStyle,
                                   hasCamera: cameraURL != nil && !cameraStyle.isHidden)
                }
                .overlay {
                    if isCropping {
                        let size = Self.size(for: variant, resolution: resolution,
                                recordingShortSide: recordingShortSide)
                        CropOverlay(crop: $crop, outputWidth: size.width,
                                    outputHeight: size.height,
                                    onCommit: { reviewRevision += 1 })
                    }
                }
                if let player {
                    Divider()
                    TransportBar(player: player, model: timeline)
                }
            }
            .frame(minHeight: 240)

            // **A divider this file owns, not `VSplitView`'s.** SwiftUI's split views cannot be
            // collapsed programmatically and do not remember where they were left, and both are
            // things a person expects of an editor: a native editor gives every one of its five
            // panels an `autosaveName` and a collapse, and the reason is that a timeline you
            // have to re-drag every launch is one you stop dragging.
            SplitHandle { delta in
                timelineHeight = min(max(timelineHeight - delta, Self.minimumTimelineHeight),
                                     Self.maximumTimelineHeight)
            }

            VStack(spacing: 0) {
                EditorToolbar(model: timeline, onChange: { editRevision += 1 },
                              isCollapsed: isTimelineCollapsed) {
                    isTimelineCollapsed.toggle()
                }
                if !isTimelineCollapsed {
                    Divider()
                    TimelineEditor(model: timeline, onChange: { editRevision += 1 },
                                   filmstrip: filmstrip,
                                   texts: texts.track, captions: captions.track,
                                   redactions: redactions.track)
                        .padding(Space.regular)
                        .frame(height: timelineHeight - EditorToolbar.height)
                }
            }
            .animation(.easeOut(duration: 0.18), value: isTimelineCollapsed)
        }
        .background(Theme.Surface.base)
        // **Pinned to dark.** Chrome around a picture shifts how its colours read: a light
        // surround makes a recording look darker and less saturated than it is, so a person
        // grading a background gradient in a light window is judging it wrong. Every editor in
        // the reference set is dark by default for this reason. The menu bar panel is NOT — it
        // lives in the system's menu bar, where a dark panel in a light system looks broken.
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .navigationTitle(mediaURL.deletingPathExtension().lastPathComponent)
        .navigationDocument(savedPackage ?? mediaURL)
        .task(id: mediaURL) { await load() }
        // **The mix changes what you hear WITHOUT reloading anything.** A mute applied by
        // rebuilding the player item would reload the asset, lose the position and go silent
        // for as long as that took — so a person testing whether to keep their narration would
        // be judging it across a gap. `AVPlayerItem.audioMix` is honoured mid-playback, which
        // is the whole reason this is a separate path from the export's.
        .task(id: audioMix) {
            guard let item = player?.currentItem, let asset = playingAsset else { return }
            // Measured from the recording's own file, once, and only when somebody asks for
            // levelling — a full audio decode for a feature most projects never turn on would
            // be a second of work on every open. See `Loudness.measure(contentsOf:)`.
            if audioMix.targetLoudness != nil, measuredLoudness.isEmpty {
                measuredLoudness = await Loudness.measure(contentsOf: mediaURL)
            }
            await AudioMixBuilder.apply(audioMix, to: item, of: asset, measured: measuredLoudness,
                                        musicTrackID: musicTrackID, musicRamps: musicRamps)
        }
        // **Registered on every change, not once.** The closure captures this view's current
        // state, so a stale one would save an older edit than the one being asked about.
        .onChange(of: hasUnsavedChanges, initial: true) {
            UnsavedWorkGuard.shared.update(hasUnsavedChanges: hasUnsavedChanges) {
                saveProject()
                return savedPackage != nil && currentEditState() == savedEdit
            }
        }
        // The preview follows the chosen shape: showing landscape while Portrait is selected
        // would be showing the wrong thing, which is the fault this surface exists against.
        .task { CodecVerdicts.shared.askOnce() }
        .task {
            guard !hasSeededCameraStyle else { return }
            hasSeededCameraStyle = true
            cameraStyle = initialCameraStyle
        }
        .task(id: variant) { await load() }
        // **A full rebuild, not a mix change.** Noise removal replaces a whole audio TRACK in
        // the composition, which `audioMix`'s cheaper path above cannot do — that one only moves
        // volume ramps on tracks that are already there.
        .task(id: noiseReduction) { if noiseReduction != nil || cleanedMicrophone != nil { await load() } }
        // **The file, not the whole bed.** Changing the piece means a different track in the
        // composition and a rebuild; changing its level or its ducking is a volume automation,
        // which the sibling below re-applies without touching the asset.
        .task(id: music.filename) { if music.filename != nil || musicTrackID != nil { await load() } }
        .task(id: music) {
            guard let item = player?.currentItem, let asset = playingAsset else { return }
            await AudioMixBuilder.apply(audioMix, to: item, of: asset, measured: measuredLoudness,
                                        musicTrackID: musicTrackID, musicRamps: musicRamps)
        }
        // Rebuilding on a COMMITTED edit, not on every drag event: `load()` builds an
        // `AVVideoComposition` over a freshly cut asset, and doing that per pixel of a
        // selection drag would make the strip unusable.
        .task(id: editRevision) { if editRevision > 0 { await load() } }
        // **The playhead has to move the player, or it is decoration.** It is dragged in
        // SOURCE time and the player counts in OUTPUT time, so the seek goes through the
        // edit; a position inside a cut has no output time and the player stays where it is
        // rather than jumping to zero.
        // Keyed on the REQUEST, not the position: playback writes the position several times a
        // second, and seeking the player to where it already is would stall it. See
        // `TimelineEditorModel.seekRequest`.
        .task(id: timeline.seekRequest) {
            guard let player,
                  let output = timeline.edit.outputTime(atSource: timeline.playhead)
            else { return }
            await player.seek(to: CMTime(value: output.rawValue, timescale: 1_000_000_000),
                              toleranceBefore: .zero, toleranceAfter: .zero)
        }
        // `reviewRevision` and not `review.overrides`: the composition is rebuilt when a
        // decision changes, and a counter says exactly that. Observing the array would also
        // fire on a load that merely restored the same decisions.
        // **A style change does not rebuild anything.** `StageCompositor` reads its style,
        // cursor, captions, text and redactions from statics at render time, so a change is
        // already in force for the next frame — while playing, it simply appears. What a PAUSED
        // player needs is a reason to draw the frame it is already showing, which a zero-distance
        // seek is. Rebuilding instead reloaded the asset, lost the position and stopped the
        // sound, which is why every slider used to interrupt playback.
        // **Every control bumps this on EVERY change, not when a drag ends.** The statics
        // reach the compositor immediately — `.task(id: cameraStyle)` and its siblings below —
        // so a PLAYING preview already shows a change as it happens. A PAUSED one has no reason
        // to redraw the frame it is holding, and this is that reason. Deferring the bump to
        // `onEditingChanged`'s end-of-drag meant a paused preview did not move while a slider
        // did, and the picture caught up only when the drag finished or playback resumed —
        // which is a control people learn not to trust.
        //
        // **Seeking on every tick is safe, and it is AVPlayer that makes it so.** A seek issued
        // while one is in progress supersedes it: the earlier completion handler is called with
        // `finished: false` and only the last one lands. `.task(id:)` cancels the previous task
        // on each new id as well, so nothing accumulates on either side.
        .task(id: reviewRevision) {
            guard reviewRevision > 0, let player else { return }
            // **Only when PAUSED, and that is the fix.** The seek is here to give a stopped
            // player a reason to redraw the frame it is already showing. Running it during
            // playback stops the playback — `AVPlayer.seek` does not resume — so dragging a
            // slider halted the video, and what a person saw was a control that did nothing
            // until they pressed play again. The comment above already said "while playing, it
            // simply appears"; the guard to match it was never written.
            guard player.timeControlStatus != .playing else { return }
            await player.seek(to: player.currentTime(),
                              toleranceBefore: .zero, toleranceAfter: .zero)
        }
        // **The two statics that only `load()` was writing.** Everything else in the inspector
        // publishes its own — `StageStylePicker`, `CaptionsPanel`, `TextPanel` and
        // `RedactionPanel` each set theirs the moment a control moves — so the camera and the
        // crop were the two whose changes waited for the next composition rebuild. A control
        // that takes effect on some later unrelated action is a control people learn not to
        // trust.
        .task(id: zoomIntensity) {
            StageCompositor.zoomIntensity = zoomIntensity
            // The lane and the camera read one derivation; without this the blocks a person
            // sees would keep the depths the dial just changed.
            refreshDerivedZooms()
        }
        .task(id: crop) {
            StageCompositor.crop = crop
            // Coverage depends on the cropped aspect, so it moves with the crop or it lies.
            StageCompositor.outputCoverage = outputCoverage
        }
        .task(id: cameraStyle) {
            guard StageCompositor.cameraTrackID != nil else { return }
            StageCompositor.cameraStyle = cameraStyle
        }
        .inspector(isPresented: $isReviewShown) {
            // **A vertical rail, not a row of tabs across the top.** ScreenKite and a native editor
            // both put the section switcher on the panel's edge as a column of icons, and the
            // reason shows as soon as there are more than three: a horizontal strip competes
            // with the panel's own width, which is the dimension a 300-point inspector has none
            // of to spare. A rail costs 40 points of width once and nothing per section.
            HStack(spacing: 0) {
                inspectorRail
                Divider().overlay(Theme.Line.hairline)
                inspector
            }
            .background(Theme.Surface.panel)
            .inspectorColumnWidth(min: InspectorWidth.minimum + 40,
                                  ideal: InspectorWidth.ideal + 40,
                                  max: InspectorWidth.maximum + 40)
        }
        .toolbar {
            // A plain toolbar `Button`, not a `.commands { CommandGroup }` menu item: `.commands`
            // can only attach to a `Scene`, never to a plain `View`.
            ToolbarItem {
                // **Always enabled once there is something to save.** It used to disable itself
                // when nothing had changed and say "Saved", which is a correct statement and a
                // dead end: a person who wants a second copy somewhere else has no way to ask
                // for one, and a button that cannot be pressed cannot explain that either.
                // The dirty state is still shown — in the title — rather than in whether the
                // control works.
                // **The menu carries the ALTERNATIVE, not a copy of the button.** It used to
                // repeat "Save" as its first item, which is the action pressing the button
                // already performs — the same command written twice, which reads as a control
                // nobody finished. A split button's menu is for what the button does not do.
                //
                // **And the label is an action, not a status.** It read "Save…" whenever
                // anything was unsaved and "Saved" otherwise: the ellipsis promised a dialog
                // that a project with a home never shows, and "Saved" labelled a button that
                // is deliberately still pressable (see above) with a statement rather than a
                // verb. The ellipsis is now exactly the HIG's rule — present only while
                // saving really would ask where — and the dirty state stays in the title,
                // where this file already put it.
                Menu {
                    Button("Save As…") { saveProject(askingForDestination: true) }
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                } label: {
                    Text(savedPackage == nil ? "Save\u{2026}" : "Save")
                } primaryAction: {
                    saveProject()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(player == nil)
            }
            // **Export stays pressable while one is running.** It used to be replaced by a
            // progress readout, which made "a master and a small copy" a thing you had to sit
            // and wait to ask for twice. The running job's progress moved into the queue beside
            // it — see `ExportQueueButton`.
            ToolbarItem {
                Button("Export…") { startExport() }
                    .disabled(player == nil)
            }
            ToolbarItem { ExportQueueButton() }
            // **Full screen, because the green button does not offer it here.**
            //
            // Measured in an isolated app on 2026-08-26: `toggleFullScreen(_:)` enters full
            // screen under EVERY activation policy — `.regular`, `.accessory`, and accessory
            // switched to regular — so the folklore that an accessory app cannot go full screen
            // is wrong, at least on this system. What is genuinely missing is the row in the
            // green button's own menu, which this app does not control.
            //
            // So the command is offered directly, which is what `../opensource/…/a native editor`
            // does: its `MainMenu` adds an explicit "Enter Full Screen" wired to
            // `NSWindow.toggleFullScreen(_:)` rather than relying on the button. ⌃⌘F is the
            // system's own shortcut for it, so the keystroke a person already knows works.
            ToolbarItem {
                Button {
                    (NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil)
                } label: {
                    Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .keyboardShortcut("f", modifiers: [.control, .command])
                .help("Enter Full Screen (\u{2303}\u{2318}F)")
            }
            ToolbarItem {
                Button {
                    isReviewShown.toggle()
                } label: {
                    Label("Review", systemImage: "sidebar.right")
                }
            }
        }
        .alert("Project", isPresented: Binding(
            get: { projectStatus != nil }, set: { if !$0 { projectStatus = nil } })
        ) {
            Button("OK") { projectStatus = nil }
        } message: {
            Text(projectStatus ?? "")
        }
        .alert("Export", isPresented: Binding(
            get: { exportStatus != nil }, set: { if !$0 { exportStatus = nil } })
        ) {
            Button("OK") { exportStatus = nil }
        } message: {
            Text(exportStatus ?? "")
        }
    }

    /// Everything the preview needs configured before a composed frame can be read: the shared
    /// compositor statics and the `AVVideoComposition` itself. Kept as its own function so the
    /// render-parity check exercises the same code the real preview runs, rather than a copy.
    /// **Takes an asset, not a URL** — the preview and the export both compose an already-cut
    /// `EditedAsset`, which has no URL of its own. `observationLogFor` still names the media
    /// file, because the log belongs to the recording rather than to any edit of it.
    static func configuredComposition(for mediaURL: URL,
                                      variant: AspectVariant = .landscape,
                                      resolution: ExportResolution = .matchRecording,
                                      recordingShortSide: Int = 1080) async throws
        -> AVVideoComposition {
        try await configuredComposition(for: AVURLAsset(url: mediaURL),
                                        logForMediaURL: mediaURL,
                                        resolution: resolution,
                                        recordingShortSide: recordingShortSide,
                                        variant: variant)
    }

    static func configuredComposition(for asset: AVAsset,
                                      logForMediaURL mediaURL: URL? = nil,
                                      resolution: ExportResolution = .matchRecording,
                                      recordingShortSide: Int = 1080,
                                      variant: AspectVariant = .landscape) async throws
        -> AVVideoComposition {
        StageCompositor.renderer = try CoreImageFrameRenderer()
        // Where an image background is read from. Set before the composition reaches
        // AVFoundation, on the same terms as every other static here.
        CoreImageFrameRenderer.imageBaseURL = mediaURL.map(ProjectStore.packageURL(forMediaAt:))
        // A fresh recording gets a fresh drop count; a stale one must not read as this file's.
        StageCompositor.resetDiagnostics()
        // `expectedLogURL(forMediaURL:)` names where a log for this media would be; it does not
        // claim one exists. The filesystem check decides between "no log" and "a log", which
        // `PointerReading`'s cases keep distinguishable — `nil` means draw no pointer.
        let candidateLogURL = mediaURL.flatMap { ObservationWriter.expectedLogURL(forMediaURL: $0) }
        StageCompositor.observationLogURL = candidateLogURL.flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
        }
        let size = size(for: variant, resolution: resolution,
                        recordingShortSide: recordingShortSide)
        return try await CompositionBuilder.composition(
            for: asset, outputWidth: size.width, outputHeight: size.height,
            frameDuration: CMTime(value: 1, timescale: 60))
    }

    /// **Two tabs: what the whole export is, and what is selected.**
    ///
    /// Both Swift editors in the reference set organise an inspector this way — a Swift recorder has
    /// exactly Settings and Segment, a native editor switches its tab set on what kind of thing is
    /// selected. The reason is that the two answer different questions: "how should this video
    /// look" is asked once, and "what is this thing I just clicked" is asked constantly. A flat
    /// list mixes them, so the answer to the second is always somewhere below the answer to the
    /// first.
    /// The inspector's section rail — a column of icons on the panel's edge.
    ///
    /// **A rail, not a row of tabs across the top.** ScreenKite and a native editor both put the
    /// section switcher on the edge, and the reason shows as soon as there are more than three:
    /// a horizontal strip competes with the panel's own width, which is the dimension a
    /// 300-point inspector has none of to spare. A rail costs 40 points once and nothing per
    /// section added after.
    @ViewBuilder var inspectorRail: some View {
        VStack(spacing: Space.tight) {
            ForEach(InspectorTab.allCases, id: \.self) { tab in
                InspectorTabButton(tab: tab, isSelected: inspectorTab == tab) {
                    inspectorTab = tab
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Space.snug)
        .frame(width: 40)
        .background(Theme.Surface.base)
    }

    @ViewBuilder private var inspector: some View {
        VStack(spacing: 0) {
            // The section's name, since the rail shows only icons.
            Text(inspectorTab.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Ink.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.roomy)
                .padding(.vertical, Space.snug + 2)

            Divider().overlay(Theme.Line.hairline)

            switch inspectorTab {
            case .project:
                List {
                    Section("Output") { outputControls }
                    Section("Look") {
                        StageStylePicker(model: stageStyle, onChange: { reviewRevision += 1 },
                                         packageURL: ProjectStore.packageURL(forMediaAt: mediaURL))
                    }
                    if cameraURL != nil {
                        Section("Camera") { cameraControls }
                    }
                    Section("Cursor") {
                        StageStylePicker(model: stageStyle,
                                         onChange: { reviewRevision += 1 }).cursorControls
                    }
                    Section("Audio") { audioControls }
                    Section("Animated GIF") { gifControls }
                }
                .listStyle(.sidebar)
            case .selection:
                List {
                    Section("Zoom amount") { zoomIntensityControl }
                    FramingReviewSections(model: review, onChange: { reviewRevision += 1 },
                                          playhead: timeline.playhead)
                }
                .listStyle(.sidebar)
            case .transcript:
                TranscriptPanel(
                    transcript: captions.transcript,
                    edit: timeline.edit,
                    onDelete: { range, name in timeline.removeSourceRange(range, named: name) },
                    onSeek: { timeline.movePlayhead(to: $0) })
            case .captions:
                let size = Self.size(for: variant, resolution: resolution,
                                recordingShortSide: recordingShortSide)
                CaptionsPanel(model: captions, mediaURL: mediaURL, edit: timeline.edit,
                              outputWidth: size.width, outputHeight: size.height,
                              onChange: { reviewRevision += 1 })
            case .text:
                TextPanel(model: texts, playhead: timeline.playhead,
                          onChange: { reviewRevision += 1 })
            case .hide:
                RedactionPanel(model: redactions, playhead: timeline.playhead,
                               onChange: { reviewRevision += 1 })
            case .mark:
                AnnotationPanel(model: annotations, playhead: timeline.playhead,
                                onChange: { reviewRevision += 1 })
            }
        }
    }

    /// Where the camera sits. **Shown only when the recording HAS one** — controls for a track
    /// that does not exist are controls a person changes and sees nothing happen.
    ///
    /// **The nine-place grid is gone, because the camera can be dragged.** It was added when
    /// the only alternative was two sliders, and that argument was sound then — almost every
    /// camera goes in a corner, and finding a corner by aiming two sliders is a job. It stopped
    /// being sound when the overlay became draggable: pointing at where the camera should go IS
    /// the grid's whole justification, and dragging it there is the same gesture with none of
    /// the chrome. Two controls for one decision is one more than the decision has.
    @ViewBuilder private var cameraControls: some View {
        Toggle("Show camera", isOn: Binding(
            get: { !cameraStyle.isHidden },
            set: { cameraStyle = cameraStyle.changing(isHidden: !$0); reviewRevision += 1 }))
        // **The room behind the person, cut away or kept** — see `PersonMask`.
        //
        // Turning it on warms Vision's models on a detached task. The first segmentation of each
        // level costs one to two seconds loading the model and every one after it costs 21 ms;
        // paid here, seconds before anybody scrubs to a frame with a camera in it, it is never
        // paid on a frame somebody is waiting for. Detached because it is not the picker's job
        // to wait for it, and nothing about the answer is needed to draw the next frame.
        Picker("Background", selection: Binding(
            get: { cameraStyle.background },
            set: { cameraStyle = cameraStyle.changing(background: $0)
                   if $0 == .removed { Task.detached(priority: .utility) { PersonMask.warmUp() } }
                   reviewRevision += 1 })) {
            ForEach(CameraOverlayStyle.Background.allCases, id: \.self) {
                Text($0.displayName).tag($0)
            }
        }
        // **The system's own blur is one control away and is not reimplemented here.** Portrait
        // mode runs inside the camera pipeline for free; a hand-written blur would be slower and
        // worse. Said in the interface because somebody looking for "blur my background" will
        // look here first, and sending them two clicks away beats offering them a worse copy.
        if cameraStyle.background == .keep {
            Text("To blur the background instead, turn on Portrait in the camera effects.")
                .font(Type.detail).foregroundStyle(.secondary)
        } else {
            // **The cost, on screen, before it is discovered.** Cutting a person out is 21 ms a
            // frame — measured — on top of everything else a frame costs, and somebody whose
            // preview has just become less smooth is owed the reason rather than left to
            // conclude the app got slower. Nothing is sent anywhere: this runs on this Mac.
            Text("Cut out on this Mac, frame by frame — around 21 ms each, so previews and "
                 + "exports take longer with this on.")
                .font(Type.detail).foregroundStyle(.secondary)
        }
        // **A cut-out person has no card**, so the controls that shape one are not offered while
        // the background is gone. They keep their values — switching back restores the card
        // exactly — they simply do nothing, and a control that does nothing is one people
        // conclude is broken. The same argument the corner slider already makes for a circle.
        if cameraStyle.background == .keep {
            Picker("Shape", selection: Binding(
                get: { cameraStyle.shape },
                set: { cameraStyle = cameraStyle.changing(shape: $0); reviewRevision += 1 })) {
                ForEach(CameraOverlayStyle.Shape.allCases, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
        }
        // **Only for the shape that has corners.** A slider that does nothing on a circle and
        // nothing on a square is a slider people conclude is broken.
        if cameraStyle.shape == .rounded, cameraStyle.background == .keep {
            Slider(value: Binding(
                get: { cameraStyle.cornerFraction },
                set: { cameraStyle = cameraStyle.changing(cornerFraction: $0)
                       reviewRevision += 1 }),
                   in: 0...0.5) { Text("Corner") }
        }
        Slider(value: Binding(get: { cameraStyle.widthFraction },
                              set: { cameraStyle = cameraStyle.changing(widthFraction: $0)
                                     reviewRevision += 1 }),
               in: 0.05...0.5) { Text("Size") }
        // **How much the camera shrinks while the stage is zoomed in.** A zoom makes the picture
        // bigger, and a camera that holds its width is covering a larger share of a smaller area
        // — which is exactly when it is most in the way. a Rust recorder models this as `scale_during_zoom`;
        // 1 holds the size, which is what this did before the control existed.
        Slider(value: Binding(get: { cameraStyle.scaleDuringZoom },
                              set: { cameraStyle = cameraStyle.changing(scaleDuringZoom: $0)
                                     reviewRevision += 1 }),
               in: 0.3...1) { Text("Shrink on zoom") }
        Slider(value: Binding(get: { cameraStyle.x },
                              set: { cameraStyle = cameraStyle.changing(x: $0)
                                     reviewRevision += 1 }),
               in: 0...1) { Text("Across") }
        Slider(value: Binding(get: { cameraStyle.y },
                              set: { cameraStyle = cameraStyle.changing(y: $0)
                                     reviewRevision += 1 }),
               in: 0...1) { Text("Up from the bottom") }
        // **Out of the cursor's way.** The classic flaw — a face over the thing being shown —
        // and Screen Studio's answer to it. The camera goes to a corner while the cursor is on
        // it and comes back once the cursor has been clear for a while; see `CameraDodge`.
        Toggle("Move out of the cursor's way", isOn: Binding(
            get: { cameraStyle.avoidsCursor },
            set: { cameraStyle = cameraStyle.changing(avoidsCursor: $0); reviewRevision += 1 }))
            .font(Type.detail)
        Toggle("Mirror", isOn: Binding(
            get: { cameraStyle.isMirrored },
            set: { cameraStyle = cameraStyle.changing(isMirrored: $0); reviewRevision += 1 }))
    }

    @ViewBuilder private var outputControls: some View {
        // The recording's own shape first when it is not already one of the three — see
        // `AspectVariant.available(recordingWidth:recordingHeight:)`.
        Picker("Shape", selection: Binding(
            get: { variant },
            set: { variant = $0; chosenShapeDeliberately = true })) {
            ForEach(AspectVariant.available(recordingWidth: recordingSize.width,
                                            recordingHeight: recordingSize.height),
                    id: \.self) { shape in
                Text(LocalizedStringKey(shape.name)).tag(shape)
            }
        }
        let size = Self.size(for: variant, resolution: resolution,
                                recordingShortSide: recordingShortSide)
        LabeledContent("Size", value: "\(size.width)\u{00D7}\(size.height)")
            .font(Type.detail).foregroundStyle(.secondary)

        // **A destination, as the four settings below it.** Choosing one sets them and then gets
        // out of the way — the four stay live, and changing any of them puts this back to
        // Custom rather than silently claiming an export is still "Web" when it is not. See
        // `ExportPreset`.
        Picker("For", selection: Binding(
            get: { ExportPreset.matching(resolution: resolution, codec: codec,
                                         frameRate: frameRate, quality: quality) },
            set: { chosen in
                guard let chosen else { return }
                resolution = chosen.resolution
                codec = chosen.codec
                frameRate = chosen.frameRate
                quality = chosen.quality
            })) {
            // Not selectable: "Custom" is a description of where the four controls are, not a
            // thing to choose. Choosing it would have to mean "put them back", and there is no
            // back to put them to.
            Text("Custom").tag(ExportPreset?.none)
            ForEach(ExportPreset.all, id: \.self) { preset in
                Text(LocalizedStringKey(preset.name)).tag(ExportPreset?.some(preset))
            }
        }
        if let preset = ExportPreset.matching(resolution: resolution, codec: codec,
                                              frameRate: frameRate, quality: quality) {
            Text(LocalizedStringKey(preset.detail))
                .font(Type.detail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        // **How large, by SHORT side.** A ladder written as 1920×1080 cannot describe a portrait
        // output, and this app exports portrait and square for the places people post them.
        Picker("Resolution", selection: Binding(
            get: { resolution }, set: { resolution = $0 })) {
            ForEach(ExportResolution.available(recordingShortSide: recordingShortSide),
                    id: \.self) { choice in
                Text(LocalizedStringKey(choice.displayName)).tag(choice)
            }
        }
        Picker("Frame rate", selection: Binding(
            get: { frameRate }, set: { frameRate = $0 })) {
            ForEach(ExportFrameRate.available(recording: recordingFrameRate),
                    id: \.self) { choice in
                Text(LocalizedStringKey(choice.displayName)).tag(choice)
            }
        }
        // **Codecs that are not ranked.** HEVC is the same picture at about half the file and
        // every Mac this runs on encodes it in hardware; ProRes is enormous and meant for handing
        // to an editor; H.264 plays everywhere without a question being asked.
        //
        // **Narrowed to two when the stage has no background**, because only two of them carry an
        // alpha channel and the other three do not fail when handed one — they encode the
        // transparency away and hand back a black rectangle. `MP4Exporter` refuses that pairing
        // by name, but a list somebody cannot choose wrongly from is better than a refusal they
        // have to read. See `TransparentExport`.
        Picker("Format", selection: Binding(get: { codec }, set: { codec = $0 })) {
            ForEach(stageStyle.isTransparent
                    ? TransparentExport.codecsThatCarryIt
                    : ExportCodec.allCases, id: \.self) { choice in
                Text(choice.displayName).tag(choice)
            }
        }
        // **Snapped rather than left dangling.** Somebody who had chosen H.264 and then made the
        // background transparent has a selection that is no longer in the list; SwiftUI would
        // show an empty picker and the export would refuse. Moving it to the smallest format that
        // works is visible — the picker changes in front of them — which is the difference
        // between this and a silent correction at export time.
        .task(id: stageStyle.isTransparent) {
            if stageStyle.isTransparent, !codec.carriesTransparency {
                codec = TransparentExport.codecsThatCarryIt[0]
            }
        }
        if stageStyle.isTransparent {
            Text("The background is transparent, so only formats that keep an alpha channel are "
                 + "offered. HEVC with Alpha is around a hundred times smaller than ProRes 4444 "
                 + "for the same picture.")
                .font(Type.detail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // **What this Mac's encoder actually does with a coloured edge**, asked rather than
        // tabulated — see `CodecVerdicts`. Silent when the probe could not run: "we could not
        // ask" and "the answer is no" are different things.
        if let note = CodecVerdicts.shared.note(for: codec) {
            Text(LocalizedStringKey(note))
                .font(Type.detail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // **How many bits the picture gets.** Nothing was choosing before, so AVFoundation did —
        // at a rate tuned for camera footage, which is the wrong content. See `ExportQuality`.
        if codec.takesBitRate {
            Picker("Quality", selection: Binding(
                get: { quality }, set: { quality = $0 })) {
                ForEach(ExportQuality.choices, id: \.self) { choice in
                    Text(LocalizedStringKey(choice.displayName)).tag(choice)
                }
            }
        }
        // **The estimate is why the picker is usable.** a Rust recorder shows one and calibrated it to
        // within 3% against real recordings; a quality control with no consequence attached is
        // three words to guess between.
        if let range = timeline.exportRange {
            // **Named in the sheet, because the button says "Export" either way.** Somebody who
            // marked a section an hour ago and came back to export has no other way to find out
            // that the file will be ten seconds long.
            let seconds = Double(range.upperBound - range.lowerBound) / 1_000_000_000
            LabeledContent("Range", value: TransportBar.timecode(seconds) + " of "
                           + TransportBar.timecode(Double(timeline.edit.outputDuration.rawValue) / 1e9))
                .font(Type.detail).foregroundStyle(Theme.accent)
        }
        LabeledContent("About", value: Self.fileSize(quality.estimatedBytes(
            outputWidth: size.width, outputHeight: size.height,
            frameRate: frameRate.frames(recording: recordingFrameRate),
            seconds: Double(timeline.editForExport.outputDuration.rawValue) / 1_000_000_000,
            codec: codec)))
            .font(Type.detail).foregroundStyle(.secondary)

        Divider()

        // **A separate button, not a third entry in the save panel's format popup.** Every
        // control above this — resolution, codec, quality, the size estimate — describes a
        // rendered picture, and none of them applies to a cut list. Folding it into the same
        // panel would offer somebody a bit rate for a text file.
        //
        // It also runs instantly rather than through `ExportQueue`: there is nothing to render.
        Button("Export Final Cut XML\u{2026}") { exportFinalCutXML() }
            .disabled(timeline.editForExport.isEmpty)
        // **What it carries and what it does not, before the click rather than after it.**
        // "Export to Final Cut" reads like a promise to carry everything, and the honest answer
        // is that it carries the cut and none of the look — which is exactly what somebody
        // finishing in another application wants, and nothing like what they would expect if
        // nobody said so.
        Text("The cut only — your clips and their in-points, against the original recording. "
             + "None of the look travels: no zooms, no cursor, no background, no camera. "
             + "DaVinci Resolve reads the same file.")
            .font(Type.detail).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Writes the cut as FCPXML, which Final Cut Pro and DaVinci Resolve both read.
    ///
    /// **Not queued.** `ExportQueue` exists because rendering takes minutes and a person should be
    /// able to set up a second job; this writes a few kilobytes of text and is finished before the
    /// panel has closed. Putting it in the queue would show a progress bar for something that has
    /// no progress.
    private func exportFinalCutXML() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "fcpxml") ?? .xml]
        panel.nameFieldStringValue = mediaURL.deletingPathExtension().lastPathComponent + ".fcpxml"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let name = mediaURL.deletingPathExtension().lastPathComponent
        let edit = timeline.editForExport
        let rate = recordingFrameRate
        let media = mediaURL
        Task {
            // **The recording's own properties, read from the file rather than from view state.**
            // `recordingShortSide` is the OUTPUT's short side and the variant may have changed
            // it; what an editing application has to be told is the size of the media it is
            // being pointed at.
            let asset = AVURLAsset(url: media)
            let duration = (try? await asset.load(.duration)) ?? .zero
            let track = try? await asset.loadTracks(withMediaType: .video).first
            // **Converted at the bridge and rotated to what is actually seen.** A phone recording
            // is encoded landscape with a rotation in `preferredTransform`; describing a sequence
            // by the encoded size would turn it on its side and letterbox every clip in it.
            let natural = (try? await track?.load(.naturalSize)) ?? .zero
            let transform = (try? await track?.load(.preferredTransform)) ?? .identity
            let size = CGGeometryBridge.displayedPixelSize(of: natural, transform: transform)
            let hasAudio = ((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty
                == false
            let source = FinalCutXML.Source(
                url: media,
                duration: Nanoseconds(Int64((duration.seconds * 1_000_000_000).rounded())),
                width: size.width, height: size.height,
                frameRate: rate, hasAudio: hasAudio)
            switch FinalCutXML.document(timeline: edit, source: source, projectName: name) {
            case .document(let xml):
                do {
                    try xml.write(to: destination, atomically: true, encoding: .utf8)
                    exportStatus = "Wrote \(destination.lastPathComponent)."
                } catch {
                    exportStatus = "Could not write \(destination.lastPathComponent): \(error)"
                }
            case .refused(let refusal):
                // Named rather than generic: the three reasons have three different fixes, and a
                // person told only that it failed cannot act on any of them.
                exportStatus = switch refusal {
                case .theEditKeepsNothing:
                    "The edit removes the whole recording, so there is no cut to export."
                case .theFrameRateIsNotAFrameRate:
                    "The recording reports no frame rate, and every time in the file has to be "
                        + "a whole frame."
                case .theRecordingHasNoSize:
                    "The recording reports no size, so there is no sequence to describe."
                }
            }
        }
    }

    /// A byte count as a person reads it. `ByteCountFormatStyle` rather than a hand-rolled
    /// divide: it is localised, and 1,2 GB in a comma-decimal locale is not something to
    /// reimplement.
    static func fileSize(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .file))
    }

    /// What a GIF export would be. In the project tab because it is a property of the OUTPUT,
    /// like the shape and the look beside it — the format is chosen in the save panel's popup,
    /// which is where macOS puts it.
    @ViewBuilder private var gifControls: some View {
        Picker("Frames", selection: $gifSettings.frameRate) {
            ForEach(GIFSettings.exactRates, id: \.self) { rate in
                Text("\(rate) fps").tag(rate)
            }
        }
        Picker("Longest edge", selection: $gifSettings.maximumLongestEdge) {
            Text("480 px").tag(480)
            Text("640 px").tag(640)
            Text("960 px").tag(960)
            Text("1280 px").tag(1280)
        }
        Toggle("Loop forever", isOn: $gifSettings.loops)

        let size = Self.size(for: variant, resolution: resolution,
                                recordingShortSide: recordingShortSide)
        let gif = gifSettings.size(fitting: size.width, height: size.height)
        // The size is worth stating because it is not the export size beside it, and the
        // "no sound" is worth stating because a person who recorded themselves talking would
        // otherwise find that out from the file.
        LabeledContent("GIF", value: "\(gif.width)\u{00D7}\(gif.height), no sound")
            .font(Type.detail).foregroundStyle(.secondary)
        // **A GIF has no inter-frame compression worth the name**, so its size is frames times
        // pixels and nothing else — a twenty-second 640-wide GIF is tens of megabytes, which is
        // past what most places accept. a Swift recorder warns for the same reason rather than letting
        // somebody find out from the upload.
        // `editForExport`, not `edit`: with a section marked, the file being estimated is
        // the section. A figure for the whole video beside a button that writes ten seconds of
        // it is worse than no figure.
        let seconds = Double(timeline.editForExport.outputDuration.rawValue) / 1_000_000_000
        let gifBytes = Int(Double(gif.width * gif.height) * 0.5 * 0.07
                           * Double(gifSettings.frameRate) * seconds)
        if gifBytes > 20_000_000 {
            Label("About \(Self.fileSize(gifBytes)) \u{2014} fewer frames or a smaller edge",
                  systemImage: "exclamationmark.triangle")
                .font(Type.detail).foregroundStyle(Signal.paused)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One row per recorded source: a level and a mute.
    ///
    /// **Mute is a separate control from a zero level**, which is what lets a person unmute
    /// back to where they had it — `AudioMix` keeps the two apart for that reason, and a UI
    /// that collapsed them would throw the level away.
    ///
    /// The level is shown as a percentage because that is what a person reads a volume in;
    /// `AudioMix` stores a linear gain, which is what `AVAudioMix` takes. The conversion is
    /// here, at the edge, rather than in the model.
    @ViewBuilder private var audioControls: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: Binding(
                get: { noiseReduction != nil },
                set: { noiseReduction = $0 ? .default : nil })
            ) {
                Text("Remove background noise")
            }
            .toggleStyle(.checkbox)
            .font(.caption)

            if noiseReduction != nil {
                HStack {
                    Text("Strength").font(.caption).foregroundStyle(.secondary)
                    LiveSlider(
                        value: noiseReduction?.strength
                            ?? NoiseReduction.Settings.default.strength,
                        // **Not the type's full 0…4 range.** Zero removes nothing, and above
                        // three the voice starts going with the room — a range whose ends are
                        // both useless is a slider that spends most of its travel doing harm.
                        range: 0.5...3.0,
                        commit: { strength in
                            noiseReduction = .init(
                                strength: strength,
                                floor: noiseReduction?.floor
                                    ?? NoiseReduction.Settings.default.floor)
                        })
                }
            }
            // **What it can and cannot do, on screen.** It takes out a fan, a hum, a laptop under
            // load — sound that is there the whole time. It does not take out a door, a keyboard
            // or a dog, and somebody who expects it to will conclude the feature is broken.
            Text(noiseReductionNote
                 ?? "Removes steady sound — a fan, a hum, air conditioning — from the microphone "
                    + "only. It cannot remove a one-off noise like a door or a keyboard.")
                .font(Type.detail)
                .foregroundStyle(noiseReductionNote == nil ? .secondary : Signal.paused)
        }
        .padding(.bottom, 2)

        ForEach(AudioMix.Source.allCases, id: \.self) { source in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Toggle(isOn: Binding(
                        get: { !audioMix.isMuted(source) },
                        set: { audioMix = audioMix.setting(source, muted: !$0) })
                    ) {
                        Text(source.displayName)
                    }
                    .toggleStyle(.checkbox)
                    Spacer()
                    Text("\(Int((audioMix.gain(for: source) * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(audioMix.isMuted(source) ? .tertiary : .secondary)
                }
                .font(.caption)
                Slider(value: Binding(
                    get: { audioMix.gain(for: source) },
                    set: { audioMix = audioMix.setting(source, gain: $0) }),
                       in: 0...AudioMix.maximumGain)
                    // A muted source's slider is disabled rather than hidden: the level is
                    // still there, and hiding it would suggest it had been lost.
                    .disabled(audioMix.isMuted(source))
            }
        }
        // **Levelling, which every comparable recorder ships and this had none of.** A demo's
        // narration sits at whatever level the microphone happened to be at, and every platform
        // it is posted to renormalises by loudness — so a file that ignores loudness is a file
        // the platform will change. ScreenKite calls it broadcast levelling. The target is in
        // LUFS because that is the unit the platforms publish theirs in; the measurement and
        // the gain that follows are `Loudness`'s.
        Divider()
        Toggle(isOn: Binding(
            get: { audioMix.targetLoudness != nil },
            set: { audioMix = audioMix.settingTargetLoudness(
                $0 ? Loudness.defaultTargetLUFS : nil) })
        ) {
            Text("Match a loudness target")
        }
        .toggleStyle(.checkbox)
        .font(.caption)
        if let target = audioMix.targetLoudness {
            HStack {
                Text("Target").font(.caption)
                Spacer()
                Text("\(Int(target.rounded())) LUFS")
                    .monospacedDigit().foregroundStyle(.secondary).font(.caption)
            }
            Slider(value: Binding(get: { target },
                                  set: { audioMix = audioMix.settingTargetLoudness($0.rounded()) }),
                   in: AudioMix.quietestTarget...AudioMix.loudestTarget)
            Text("YouTube and Spotify normalise to \u{2212}14; \u{2212}16 leaves a little headroom under it.")
                .font(Type.detail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if audioMix.changesAnything {
            Button("Reset audio") { audioMix = .unchanged; measuredLoudness = [:] }
                .buttonStyle(.link).font(.caption)
        }
        Divider()
        musicControls
    }

    /// **A music bed, and how far out of the way it gets when somebody speaks.**
    ///
    /// Both commercial recorders ship this and none of the open-source four do: Screen Studio's
    /// background audio "automatically lowers when you speak", ScreenKite calls it voice
    /// ducking. The file is copied into the project — `MusicBed` says why — and the envelope
    /// comes from the silences the timeline already found, so there is one answer to "where is
    /// the voice" rather than two.
    @ViewBuilder private var musicControls: some View {
        HStack {
            Text("Music").font(.caption)
            Spacer()
            if let name = music.filename {
                Text(name).font(Type.detail).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Button(music.filename == nil ? "Choose\u{2026}" : "Replace\u{2026}") {
                if let source = Self.chooseAudio() { adoptMusic(source) }
            }
            .buttonStyle(.link).font(.caption)
        }
        if let failure = musicFailure {
            Text(failure).font(Type.detail).foregroundStyle(Signal.paused)
                .fixedSize(horizontal: false, vertical: true)
        }
        if music.filename != nil {
            Toggle("Play the music", isOn: Binding(
                get: { music.isEnabled },
                set: { music = music.changing(isEnabled: $0) }))
                .toggleStyle(.checkbox).font(.caption)
            musicSlider("Music level", value: music.ducking.bedGain, upTo: 1) { value in
                let settings = music.ducking
                music = music.changing(ducking: MusicDucking.Settings(
                    bedGain: value, duckedGain: min(settings.duckedGain, value),
                    attack: settings.attack, release: settings.release, hold: settings.hold))
            }
            Toggle("Lower it while I speak", isOn: Binding(
                get: { music.ducks },
                set: { music = music.changing(ducks: $0) }))
                .toggleStyle(.checkbox).font(.caption)
            if music.ducks {
                musicSlider("Level while speaking", value: music.ducking.duckedGain,
                            upTo: music.ducking.bedGain) { value in
                    let settings = music.ducking
                    music = music.changing(ducking: MusicDucking.Settings(
                        bedGain: settings.bedGain, duckedGain: value,
                        attack: settings.attack, release: settings.release, hold: settings.hold))
                }
                if timeline.silences.isEmpty {
                    Text("Nothing on the microphone track reads as speech yet, so the bed stays "
                         + "at its own level.")
                        .font(Type.detail).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button("Remove the music") {
                music = MusicBed.none
                musicFailure = nil
            }
            .buttonStyle(.link).font(.caption)
        }
    }

    /// A level slider with its value written beside it. `upTo` is clamped away from zero
    /// because a `Slider` whose range is empty traps, and "level while speaking" has an upper
    /// bound that is itself a slider somebody can drag to nothing.
    @ViewBuilder private func musicSlider(_ title: String, value: Double, upTo: Double,
                                          commit: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text("\(Int((value * 100).rounded()))%")
                    .monospacedDigit().foregroundStyle(.secondary).font(.caption)
            }
            Slider(value: Binding(get: { min(value, max(upTo, 0.0001)) }, set: { commit($0) }),
                   in: 0...max(upTo, 0.0001))
        }
    }

    /// **Copied into the package, not referenced.** `StageStylePicker.useImageBackground`'s
    /// argument exactly: a bed pointing at a file on the Desktop works until that file moves,
    /// and music that silently becomes silence is worse than music never offered.
    private func adoptMusic(_ source: URL) {
        let packageURL = ProjectStore.packageURL(forMediaAt: mediaURL)
        let directory = packageURL.appending(path: MusicBed.directory, directoryHint: .isDirectory)
        let name = source.lastPathComponent
        guard MusicBed.isSafeFilename(name) else {
            musicFailure = "\(name) is not a name this can use."
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            let destination = directory.appending(path: name)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            musicFailure = "Could not copy \(name) into the project: \(error)"
            return
        }
        musicFailure = nil
        music = music.changing(filename: .some(name), isEnabled: true)
    }

    /// The open panel, audio only.
    @MainActor
    private static func chooseAudio() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - saving and opening

    /// Everything a person decided, gathered from the models that hold it.
    ///
    /// **Assembled here rather than held here**, because each model owns its own part and a
    /// second copy would be a second answer. This is the one place that knows the whole shape,
    /// which is what a file format needs and what nothing else does.
    private func currentEditState() -> EditState {
        EditState(
            timeline: timeline.hasEdits ? timeline.edit : nil,
            audioMix: audioMix,
            zoomAdjustmentData: timeline.zoomAdjustments.isEmpty
                ? nil : try? EditState.encoding(timeline.zoomAdjustments),
            framingOverrideData: review.overrides.isEmpty
                ? nil : try? EditState.encoding(review.overrides),
            styleData: try? EditState.encoding(stageStyle.style),
            outputShapeName: variant.name,
            captionTrackData: captions.track.isEmpty
                ? nil : try? EditState.encoding(captions.track),
            captionStyleData: captions.track.isEmpty
                ? nil : try? EditState.encoding(captions.style),
            burnsInCaptions: captions.burnsIn ? true : nil,
            textTrackData: texts.track.isEmpty ? nil : try? EditState.encoding(texts.track),
            redactionTrackData: redactions.track.isEmpty
                ? nil : try? EditState.encoding(redactions.track),
            annotationTrackData: annotations.track.isEmpty
                ? nil : try? EditState.encoding(annotations.track),
            cursorStyleData: try? EditState.encoding(stageStyle.cursor),
            cameraStyleData: cameraURL == nil
                ? nil : try? EditState.encoding(cameraStyle),
            cropData: crop.isWhole ? nil : try? EditState.encoding(crop),
            hidesKeystrokes: stageStyle.showsKeystrokes ? nil : true,
            musicData: music == .none ? nil : try? EditState.encoding(music),
            // Neutral is not a decision, so an untouched project stays untouched on disk.
            zoomIntensity: zoomIntensity == FramingDepth.neutralIntensity ? nil : zoomIntensity,
            // Absent means off, so a project nobody asked has nothing to say about it.
            noiseReductionData: noiseReduction.flatMap { try? EditState.encoding($0) })
    }

    /// The cleaned microphone track, made if it is asked for and does not exist yet.
    ///
    /// **Returns the map `EditedAsset.make` takes, keyed by track index**, because a Soredemo
    /// recording has system audio and a microphone as separate tracks and only one of them is a
    /// room. `NoiseReducedAudio.microphoneTrackIndex` is where that index is decided, from the
    /// same named order the mix and the waveform read.
    ///
    /// **Cached on disk, keyed by the settings.** The pass is a full decode and re-encode of the
    /// audio; doing it again on every preview rebuild would make the strength slider unusable.
    /// A settings change makes a different filename rather than deleting the old one, so
    /// switching back is instant.
    ///
    /// Every refusal is reported into `noiseReductionNote` rather than swallowed. A person who
    /// turned this on and heard no difference is owed the reason, and "there is no measurable
    /// silence in this recording" is a thing they can act on.
    private func microphoneSubstitution(for recording: AVAsset) async -> [Int: AVAsset] {
        guard let settings = noiseReduction,
              let index = NoiseReducedAudio.microphoneTrackIndex
        else { return [:] }

        // Inside the recording's own package, beside `media/` and `observations/`. A cleaned
        // track is derived from the recording and belongs with it: copying the project copies
        // it, and deleting the project takes it too.
        let destination = NoiseReducedAudio.destination(
            for: mediaURL, settings: settings,
            in: ProjectStore.packageURL(forMediaAt: mediaURL))
        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            cleanedMicrophone = destination
            return [index: AVURLAsset(url: destination)]
        }
        do {
            let outcome = try await NoiseReducedAudio.write(from: recording, to: destination,
                                                            trackIndex: index, settings: settings)
            switch outcome {
            case .reduced(let url):
                cleanedMicrophone = url
                noiseReductionNote = nil
                return [index: AVURLAsset(url: url)]
            case .refused(let refusal):
                // **Left ON in the interface.** Turning the switch back off here would look like
                // the app disagreeing with the person; the note says what happened and the
                // switch still says what they asked for.
                cleanedMicrophone = nil
                noiseReductionNote = "Noise removal did nothing: \(refusal)."
                return [:]
            }
        } catch {
            cleanedMicrophone = nil
            noiseReductionNote = "Noise removal could not run: \(error)."
            return [:]
        }
    }

    /// The bed's file inside the project package, or `nil` when there is none to play.
    private var musicFileURL: URL? {
        guard music.isAudible, let filename = music.filename else { return nil }
        return ProjectStore.packageURL(forMediaAt: mediaURL)
            .appending(path: MusicBed.directory, directoryHint: .isDirectory)
            .appending(path: filename)
    }

    /// **The envelope the bed follows, from the silences the timeline already found.** One
    /// decision about where the voice is: `SilenceFinder` makes it for the Silence lane and for
    /// auto-cutting, and `MusicDucking.speech(betweenSilences:over:)` turns the same answer
    /// inside out. A second detector here would be a second answer a person could catch
    /// disagreeing with the lane in front of them.
    ///
    /// Ducking off leaves the bed flat at its own level, which is what somebody laying music
    /// under a demo with no narration wants; no file leaves it empty, and `AudioMixBuilder`
    /// reads an empty envelope as silence rather than as unity.
    private var musicRamps: [MusicDucking.Ramp] {
        guard music.isAudible, let duration = timeline.duration else { return [] }
        guard music.ducks else {
            return MusicDucking.ramps(speech: [], over: duration, settings: music.ducking)
        }
        return MusicDucking.ramps(
            speech: MusicDucking.speech(betweenSilences: timeline.silences, over: duration),
            over: duration, settings: music.ducking)
    }

    /// True when what is on screen differs from what is on disk. A scratch recording is always
    /// unsaved, because nothing has been written yet — not because it has been edited.
    private var hasUnsavedChanges: Bool {
        savedPackage == nil || currentEditState() != savedEdit
    }

    /// `askingForDestination` is Save As: it asks even when this project already has a home,
    /// and moves the project to the new one — which is what "save as" means everywhere else.
    private func saveProject(askingForDestination: Bool = false) {
        let edit = currentEditState()
        let existing = askingForDestination ? nil : savedPackage
        let destination = existing ?? ProjectStore.chooseSaveDestination(
            defaultName: savedPackage?.deletingPathExtension().lastPathComponent
                ?? mediaURL.deletingPathExtension().lastPathComponent)
        guard let destination else { return }
        do {
            try ProjectStore.save(recordingAt: mediaURL, edit: edit, to: destination)
            savedPackage = destination
            savedEdit = edit
            projectStatus = "Saved to \(destination.lastPathComponent)."
        } catch {
            projectStatus = "Could not save: \(error)"
        }
    }

    /// Applies a saved edit to the models.
    ///
    /// **Every part is optional and an absent one is left alone**, so a project written before
    /// a field existed opens with that part at its default rather than cleared. A decode that
    /// FAILS is reported: a person whose zoom corrections were silently dropped would redo them
    /// and save over the file that still had them.
    private func restore(_ edit: EditState) {
        var failures: [String] = []
        if let saved = edit.timeline { timeline.restoreSavedEdit(saved) }
        audioMix = edit.audioMix
        do {
            noiseReduction = try EditState.decoding(edit.noiseReductionData,
                                                    as: NoiseReduction.Settings.self)
        } catch { failures.append("noise removal") }
        do {
            if let adjustments = try EditState.decoding(edit.zoomAdjustmentData,
                                                        as: [ZoomAdjustment].self) {
                timeline.restoreZoomAdjustments(adjustments)
            }
        } catch { failures.append("zoom adjustments") }
        do {
            if let overrides = try EditState.decoding(edit.framingOverrideData,
                                                      as: [FramingOverride].self) {
                review.restoreOverrides(overrides)
            }
        } catch { failures.append("framing decisions") }
        do {
            if let style = try EditState.decoding(edit.styleData, as: StageStyle.self) {
                stageStyle.restore(style)
            }
        } catch { failures.append("the look") }
        do {
            if let cursor = try EditState.decoding(edit.cursorStyleData, as: CursorStyle.self) {
                stageStyle.restoreCursor(cursor)
            }
        } catch { failures.append("the cursor") }
        stageStyle.setShowsKeystrokes(edit.hidesKeystrokes != true)
        // Clamped on the way in: it arrives from a file, which is rule 8's case, and a saved
        // negative would make every depth the ceiling rather than failing visibly.
        zoomIntensity = min(max(edit.zoomIntensity ?? FramingDepth.neutralIntensity, 0),
                            FramingDepth.maximumIntensity)
        do {
            if let saved = try EditState.decoding(edit.musicData, as: MusicBed.self) {
                music = saved
            }
        } catch { failures.append("the music") }
        do {
            if let camera = try EditState.decoding(edit.cameraStyleData,
                                                   as: CameraOverlayStyle.self) {
                cameraStyle = camera
            }
        } catch { failures.append("the camera") }
        do {
            if let saved = try EditState.decoding(edit.cropData, as: CropRect.self) {
                crop = saved
            }
        } catch { failures.append("the crop") }
        if let name = edit.outputShapeName {
            // **The matching shape is rebuilt rather than looked up.** It is deliberately not
            // in `all` — being in a list is exactly what would stop it depending on the
            // recording's size, which is the thing that makes it match.
            if name == AspectVariant.matchRecordingName,
               let own = AspectVariant.matching(width: recordingSize.width,
                                                height: recordingSize.height) {
                variant = own
                chosenShapeDeliberately = true
            } else if let shape = AspectVariant.all.first(where: { $0.name == name }) {
                variant = shape
                chosenShapeDeliberately = true
            }
        }
        do {
            // The style is restored even when the track failed to decode, so a person who
            // transcribes again does not also have to redo how it looks.
            let style = try EditState.decoding(edit.captionStyleData, as: CaptionStyle.self)
            if let track = try EditState.decoding(edit.captionTrackData, as: CaptionTrack.self) {
                captions.restore(track: track, style: style ?? captions.style,
                                 burnsIn: edit.burnsInCaptions ?? false)
            } else if let style {
                captions.setStyle(style)
            }
        } catch { failures.append("the captions") }
        do {
            if let track = try EditState.decoding(edit.textTrackData, as: TextTrack.self) {
                texts.restore(track)
            }
        } catch { failures.append("the text") }
        do {
            if let track = try EditState.decoding(edit.redactionTrackData,
                                                  as: RedactionTrack.self) {
                redactions.restore(track)
            }
            // **A redaction that failed to decode is reported louder than the rest**, because
            // opening a project and not being told the covers are gone is how a key gets
            // published. The shared failure list is the mechanism; this is the case it was
            // most worth having.
        } catch { failures.append("the hidden regions") }
        do {
            if let track = try EditState.decoding(edit.annotationTrackData,
                                                  as: AnnotationTrack.self) {
                annotations.restore(track)
            }
        } catch { failures.append("the marks") }
        savedEdit = edit
        if !failures.isEmpty {
            projectStatus = "Opened, but could not read \(failures.joined(separator: ", "))."
        }
    }

    /// **The lane's blocks, from the same call the camera makes.** Extracted the moment there
    /// were two callers: `load()` and the intensity dial. A second derivation with its own
    /// arguments is how a lane comes to disagree with the picture it is describing.
    @ViewBuilder private var zoomIntensityControl: some View {
        // **The one control that still commits on release, and it is not the camera's rule.**
        // Every other control in this window now refreshes on every change: publishing a static
        // and asking a paused player to redraw costs a seek, which AVPlayer coalesces. This one
        // is different in kind — `.task(id: zoomIntensity)` re-derives the zoom BLOCKS through
        // `refreshDerivedZooms`, which walks the framing plan and rebuilds the camera's baked
        // path, and doing that per pixel of slider travel is work rather than a redraw. The
        // lane's blocks move on release; the number under the thumb moves live.
        //
        // The comment here used to say "the same rule the camera sliders already use". That
        // stopped being true on 2026-08-26, when they stopped using it.
        Slider(value: $zoomIntensity, in: 0...FramingDepth.maximumIntensity, step: 0.1,
               onEditingChanged: { if !$0 { reviewRevision += 1 } }) {
            Text("Amount")
        }
        Text(zoomIntensityLabel)
            .font(Type.detail).foregroundStyle(.secondary)
    }

    /// Says what the dial does at the ends, because "0.0" and "2.0" do not.
    private var zoomIntensityLabel: String {
        let percent = Int((zoomIntensity * 100).rounded())
        if percent == 0 { return "No zoom anywhere. Every click is framed, none is magnified." }
        if percent == 100 { return "As derived. Adjustments you have made to single zooms still apply on top." }
        return "\(percent)% of the derived zoom. Adjustments to single zooms still apply on top."
    }

    private func refreshDerivedZooms() {
        timeline.setDerivedZooms(ZoomBlock.blocks(
            for: review.plan.framedClicks(with: review.overrides,
                                          pointerFallbackRevision: review.fallbackRevision),
            coverage: outputCoverage, intensity: zoomIntensity))
    }


    private func load() async {
        do {
            // Before the composition: `configuredComposition` reads
            // `StageCompositor.framingOverrides`, which `FramingReviewModel.load` publishes.
            review.load(observationLogAt: ObservationWriter.expectedLogURL(forMediaURL: mediaURL)
                .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
            // The crop before the composition: `StagePlanner` fits the card to the CROPPED
            // aspect, so a composition built while the static still said "whole" would size the
            // card for a recording that is no longer what is being drawn. It is also what
            // `outputCoverage` below is computed from, which is the other reason it goes first.
            StageCompositor.crop = crop
            let recording = AVURLAsset(url: mediaURL)
            // What `Match Recording` matches. Read once from the file, because it is a property
            // of the capture and no edit changes it.
            //
            // **Read before the zoom lane is built, and the order is load-bearing.** The lane's
            // depths now come from `outputCoverage`, which is computed from this size; reading
            // it afterwards meant the FIRST open of every project derived its zooms against the
            // 1920x1080 placeholder these properties start at, so a 3024x1964 recording exported
            // 9:16 showed one set of depths until something happened to rebuild.
            if let track = try await recording.loadTracks(withMediaType: .video).first {
                let natural = try await track.load(.naturalSize)
                recordingShortSide = Int(min(natural.width, natural.height).rounded())
                recordingSize = (width: Int(natural.width.rounded()),
                                 height: Int(natural.height.rounded()))
                // **The shape is NOT set from here, and the reason is a hazard rather than a
                // preference.** `.task(id: variant)` runs this function, so assigning `variant`
                // inside it cancels the very run doing the assigning — and `restore(_:)`, which
                // applies a saved shape, happens further down. A first draft did exactly that
                // and would have dropped a saved Portrait on the first open of a project,
                // silently, depending on where the cancellation landed. The recording's own
                // shape is offered in the picker instead; making it the default belongs
                // wherever a NEW recording is first handed to this window, not here.
                // `nominalFrameRate` is a Float and a capture reports 59.999996; rounding is what
                // makes "match the recording" mean 60 rather than a rate no container has.
                let nominal = try await track.load(.nominalFrameRate)
                if nominal > 0 { recordingFrameRate = Int(nominal.rounded()) }
            }
            // The lane draws the same blocks the camera integrates, derived from the same
            // plan and now at the same coverage — a second derivation would be a second
            // answer, and a second coverage would be a second answer that agreed in landscape
            // and diverged in portrait, which is worse.
            StageCompositor.outputCoverage = outputCoverage
            // The anchor first: the lane converts every block's absolute instant through it,
            // and blocks set before it would be drawn off the edge for one frame.
            timeline.setZoomAnchor(review.anchor)
            refreshDerivedZooms()
            if timeline.duration == nil {
                timeline.load(duration: try await recording.load(.duration).seconds)
                // **After `load`, which resets the models.** Restoring first would be wiped by
                // the reset, silently, and a person would see their saved edit vanish on open.
                if let pendingEdit {
                    restore(pendingEdit)
                    savedPackage = ProjectStore.packageURL(forMediaAt: mediaURL)
                }
                // After `load`, which resets the model: reading the envelope is slow enough
                // that a person sees the strip before it arrives, and it must not be wiped by
                // the reset it raced.
                await timeline.loadWaveform(from: recording)
            }
            // **The preview plays the EDITED asset, not the recording with an end time set.**
            // `EditedAsset` is what the export cuts with too, so the two cannot show different
            // videos — an edit a person can make but not see is a setting, not an edit.
            // **The cleaned microphone is substituted into the cut, so preview and export
            // cannot disagree.** Export is handed the asset the preview is playing — see
            // `runExport`'s header — so wiring it here wires both, and there is no second place
            // for the two to drift apart.
            let cut = try await EditedAsset.make(
                from: recording, by: timeline.edit,
                substitutingAudio: await microphoneSubstitution(for: recording))
            // The camera laid alongside the cut recording, so one composition sees both. Returns
            // the cut asset untouched when there is no camera, so the common path costs nothing.
            let combined = try await CameraComposition.combine(
                screen: cut, cameraURL: cameraURL,
                cameraStartOffset: CMTime(value: cameraStartOffsetNanos, timescale: 1_000_000_000),
                musicURL: musicFileURL)
            StageCompositor.cameraTrackID = combined.cameraTrackID
            musicTrackID = combined.musicTrackID
            StageCompositor.cameraStyle = combined.cameraTrackID == nil ? nil : cameraStyle
            let asset = combined.asset
            let composition = try await Self.configuredComposition(
                for: asset, logForMediaURL: mediaURL, resolution: resolution,
                recordingShortSide: recordingShortSide, variant: variant)
            let item = AVPlayerItem(asset: asset)
            item.videoComposition = composition
            // The mix is applied at load too, not only on change: reopening a saved project
            // with the microphone muted must sound muted before anyone touches a control.
            await AudioMixBuilder.apply(audioMix, to: item, of: asset)
            playingAsset = asset
            // **The filmstrip reads the UNCUT recording**, not the edited composition: the strip
            // is laid out in source time, and a composition's own timeline has already had the
            // cuts taken out of it — so a frame asked for at 30 s would come back from a
            // different moment after every edit.
            filmstrip.load(url: mediaURL)
            player = AVPlayer(playerItem: item)
        } catch {
            failure = "\(error)"
        }
    }

    /// Presents the save panel and queues what it chose. The panel comes first because a job
    /// with no destination is not a job — and because the panel's own format popup is where
    /// macOS puts the format chooser.
    private func startExport() {
        let panel = NSSavePanel()
        // **Two types, so the panel's own format popup is the format chooser.** an Electron recorder and
        // an Electron recorder both build a FormatSelector into the editor; on macOS that control already
        // exists and lives in the save panel, and a second one in the window would be a second
        // place to look for the same answer.
        // The chosen codec's container first, so the panel opens on it — ProRes is a `.mov`
        // and offering an `.mp4` for it would be offering a file other editors refuse.
        panel.allowedContentTypes = codec.fileExtension == "mov" ? [.quickTimeMovie, .gif]
                                                                 : [.mpeg4Movie, .quickTimeMovie, .gif]
        panel.nameFieldStringValue = mediaURL.deletingPathExtension().lastPathComponent
            + "." + codec.fileExtension
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        // **Queued rather than run, so a second export does not have to wait for a person.**
        // A 4K master and a small copy to send is two exports of one recording, and until this
        // the second could not even be set up until the first finished. See `ExportQueue`.
        //
        // The compositor's settings are captured HERE, not when the job runs: they are
        // process-global statics, and a job that started in two minutes would otherwise draw
        // whatever had been edited since.
        let settings = StageCompositor.settings()
        let asset = playingAsset
        // **The range is applied here, at the export, and nowhere else.** `timeline.edit` is
        // still what the preview plays: a marked section is a choice about one export, not an
        // edit to the project, and hiding the rest of the recording the moment somebody marks a
        // section would make it impossible to check the section against what surrounds it.
        let edit = timeline.editForExport
        let mix = audioMix
        // Captured with the rest of the job, for `runExport`'s reason: a queued export runs
        // later than the view that asked for it, and reading this then would read whatever had
        // been measured since.
        let loudness = measuredLoudness
        let bedTrack = musicTrackID
        let bedRamps = musicRamps
        let chosen = quality
        let chosenCodec = codec
        let frames = frameRate.frames(recording: recordingFrameRate)
        let gif = gifSettings
        let size = Self.size(for: variant, resolution: resolution,
                                recordingShortSide: recordingShortSide)
        let isGIF = destination.pathExtension.lowercased() == "gif"
        let queued = ExportQueue.shared.enqueue(destination: destination) { report in
            guard let asset else { return "There is nothing loaded to export." }
            StageCompositor.apply(settings)
            return await Self.runExport(asset: asset, to: destination, isGIF: isGIF,
                                        size: size, edit: edit, audioMix: mix,
                                        measuredLoudness: loudness,
                                        musicTrackID: bedTrack, musicRamps: bedRamps,
                                        quality: chosen, codec: chosenCodec,
                                        frameRate: frames, gifSettings: gif, report: report)
        }
        if queued == nil {
            // Named, because the only way somebody works out which of their jobs they collided
            // with is being told the filename. a native editor's `destinationInUse` says the same.
            exportStatus = "An export to \(destination.lastPathComponent) is already waiting."
        }
    }

    /// Runs one queued export and reports what went wrong, or `nil`.
    ///
    /// **Static, and every input passed in.** A queued job runs later than the view that asked
    /// for it, and reading `self` then would read whatever a person had changed since — which is
    /// the same argument `StageCompositor.settings()` makes about the statics, applied to view
    /// state. The parameters are the job.
    ///
    /// The asset is the one the preview is playing rather than the file on disk: the camera
    /// reaches the picture as a SECOND VIDEO TRACK laid alongside the cut asset, and a bare file
    /// has one. `StageCompositor.cameraTrackID` names a track in that composition too.
    static func runExport(asset: sending AVAsset, to destination: URL, isGIF: Bool,
                          size: (width: Int, height: Int), edit: EditTimeline,
                          audioMix: AudioMix, measuredLoudness: [Int: Double],
                          musicTrackID: CMPersistentTrackID?, musicRamps: [MusicDucking.Ramp],
                          quality: ExportQuality, codec: ExportCodec,
                          frameRate: Int, gifSettings: GIFSettings,
                          report: @escaping @MainActor (ExportProgress) -> Void) async -> String? {
        do {
            if isGIF {
                _ = try await GIFExporter.export(
                    asset: asset, to: destination,
                    outputWidth: size.width, outputHeight: size.height,
                    edit: edit, assetIsAlreadyEdited: true, settings: gifSettings,
                    onProgress: { progress in Task { @MainActor in report(progress) } })
            } else {
                _ = try await MP4Exporter.export(
                    asset: asset, to: destination,
                    outputWidth: size.width, outputHeight: size.height,
                    edit: edit, assetIsAlreadyEdited: true, audioMix: audioMix,
                    measuredLoudness: measuredLoudness,
                    musicTrackID: musicTrackID, musicRamps: musicRamps,
                    frameRate: frameRate, quality: quality, codec: codec,
                    onProgress: { progress in Task { @MainActor in report(progress) } })
            }
            return nil
        } catch is CancellationError {
            // Nothing to report: a person who cancelled knows they cancelled, and the exporter's
            // own cancellation has already deleted the partial file.
            return nil
        } catch {
            return "\(error)"
        }
    }


    /// Whole numbers without a trailing `.0`, which is what every rate on `exactRates` is.
    private func formatted(_ rate: Double) -> String {
        rate == rate.rounded() ? String(Int(rate)) : String(format: "%.1f", rate)
    }
}



