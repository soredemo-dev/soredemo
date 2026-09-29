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
    @Environment(\.undoManager) private var undoManager
    /// Where the self-view was left during the recording, so the stage opens with the camera
    /// there rather than back at the default — see `CameraSelfView`.
    var initialCameraStyle: CameraOverlayStyle = .default
    /// How much later than the screen the camera began. Measured by the recorder; zero for a
    /// project opened from disk, which is a gap this does not close — see the doc comment on
    /// `CameraComposition.combine`.
    var cameraStartOffsetNanos: Int64 = 0
    /// Everything a person decides about this recording — see `EditorViewModel`.
    @State private var editor = EditorViewModel()
    /// When the recording's file was made — for its name, read off the file (see `RecordingName`).
    @State private var recordedAt: Date?
    /// What this recording is called wherever a person sees a name. Never `master-00`.
    private var recordingName: String {
        RecordingName.display(for: mediaURL, savedPackage: editor.savedPackage, recordedAt: recordedAt)
    }
    @State private var player: AVPlayer?
    /// The asset the current item was built from. Held because `AVAudioMix` addresses that
    /// asset's tracks, and after a cut the item's asset is a composition rather than the file.
    @State private var playingAsset: AVAsset?
    /// The video track's thumbnails. Owned here so a cache is not discarded on every edit.
    @State private var filmstrip = Filmstrip()
    /// One-shot, because `initialCameraStyle` seeds `cameraStyle` and a saved project's own
    /// value must win over it — the load runs after this and would otherwise be overwritten.
    @State private var hasSeededCameraStyle = false
    @State private var isCropping = false
    /// Whether the safe-frame guides are drawn. **Off by default and not saved**: it is a thing
    /// to look at while deciding where something sits, not a property of the recording, and a
    /// guide left on from last week is furniture rather than information.
    @State private var showsSafeFrame = false
    @State private var failure: String?
    // MARK: - export-basic
    @State private var exportStatus: String?
    // MARK: - review-ui
    /// What the last attempt to clean the microphone did, or why it could not. Shown, never
    /// swallowed — a person who turned this on and heard no difference is owed the reason.
    @State private var noiseReductionNote: String?
    /// The cleaned microphone, once it exists. Rebuilt when the settings change; cleared when
    /// the feature is turned off.
    @State private var cleanedMicrophone: URL?
    /// Each audio track's integrated loudness, by index — see `Loudness`. Measured lazily, the
    /// first time levelling is asked for, because it decodes the whole audio track and most
    /// recordings are never levelled. Cleared when a different recording is loaded.
    @State private var measuredLoudness: [Int: Loudness.Reading] = [:]
    /// The composition's music track, and the envelope it follows. Both are rebuilt with the
    /// composition rather than per frame: the track is a track and the envelope is a volume
    /// automation, and `AVAudioMix` takes them together.
    @State private var musicTrackID: CMPersistentTrackID?
    /// Why a chosen piece did not become the bed, or `nil`. Reported rather than swallowed: a
    /// person who chose music and got silence is owed the reason.
    @State private var musicFailure: String?
    // MARK: - project
    // MARK: - basic-edit
    /// Bumped when an edit is committed, to rebuild the composition against the cut asset.
    @State private var editRevision = 0
    @State private var isReviewShown = true
    @State private var inspectorTab = InspectorTab.project
    /// Whether the window is given over to captions. See `CaptionEditor` for why an hour of
    /// caption work is not inspector work.
    @State private var isCaptionEditorShown = false
    /// How tall the timeline area is, remembered between launches — see the divider's comment.
    @AppStorage("timelineHeight") private var timelineHeight: Double = 210
    @AppStorage("timelineCollapsed") private var isTimelineCollapsed = false

    /// The band the timeline may be dragged within. A floor because a strip shorter than its
    /// tracks is a strip nothing can be aimed at; a ceiling because a timeline taller than the
    /// preview is an editor that cannot show what it is editing.
    static let minimumTimelineHeight: Double = 150
    static let maximumTimelineHeight: Double = 480
    /// How large the exported picture is, and what it is written as. Held beside `quality` for
    /// its reason — the save panel must not find them reset.
    // **The recording's own size, not 1080p.** Measured: a 3024×1964 Retina capture exported
    // at the 1080p default came out 1662×1080, six pixels in ten discarded before the card's
    // inset discarded more — the softness every review of the export complained about, and
    // the only control that could undo it defaulted to the wrong rung. `available` lists
    // `.matchRecording` first for the reason `ExportResolution` gives; the default agrees.


    /// What the inspector is showing. See `inspector` for why there are two.
    enum InspectorTab: String, CaseIterable, Hashable {
        // **`transcript` is gone and its content moved into `captions`.** They were two rail
        // icons over one subject — what was said — and the two lists look alike enough that a
        // person had to know which icon held which. One tab, one segmented control inside it;
        // see `CaptionsPanel.Words` for why the two lists stay two.
        case project, selection, captions, chapters, text, hide, mark

        var title: String {
            switch self {
            case .project: "Project"
            case .selection: "Zooms"
            // "Captions" rather than "Overlays": the tab is the recording's words now, and
            // "Overlays" was already a poor name for a tab whose contents were captions.
            case .captions: "Captions"
            case .chapters: "Chapters"
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
            // **A viewfinder, not a magnifier, since 2026-09-18.** The magnifier means
            // "zoom the TIMELINE in" one toolbar away (`EditorToolbar`'s ⌘=), and two
            // different meanings on one glyph is how a person learns that an icon is
            // decoration. A zoom here moves the camera onto a point somebody clicked, which
            // is what a viewfinder with a dot in it says and a magnifier does not.
            case .selection: "dot.viewfinder"
            case .captions: "captions.bubble"
            case .chapters: "list.bullet.rectangle"
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
            case .chapters: Theme.Lane.chapter
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
    /// Whether dragging the playhead plays what is under it. Passed down rather than read from a
    /// coordinator here: this window's job is to draw an edit, and a preference it looked up
    /// itself would be a second place the setting lives.
    var scrubAudioIsOn = true

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


    var body: some View {
        // **No sidebar.** It held one row — the recording's filename — which is a whole column
        // spent on a label. The filename is the window's TITLE now, with `navigationDocument`
        // giving it the proxy icon and path popup every document window on this system has.
        //
        // **The timeline sits under the preview**, because a timeline is read along its length
        // while watching the picture above it, and an inspector is read down a column.
        stage
            // **The one view that watches the playhead at the playhead's own rate.** Installed
            // here because this is where both models are; it draws nothing. See its header.
            .background(CaptionCueTracker(timeline: editor.timeline, captions: editor.captions))
            // **The window's undo stack, handed to the caption model.** ⌘Z and ⇧⌘Z come from
            // the system's Edit menu once something registers with this manager; the timeline
            // keeps its own `EditHistory`, which is a different stack for a different surface —
            // undoing a caption correction should not undo a cut.
            .onAppear { editor.captions.undoRecorder = undoManager }
            // **Stopped, not left to the player's release.** The sound of a recording played on
            // after its window was closed (2026-09-28); whatever else still holds the player, a
            // closed editor does not play.
            .onDisappear { player?.pause() }
            .onChange(of: undoManager) { editor.captions.undoRecorder = undoManager }
            // **The caption editor REPLACES the stage rather than floating over it.** A sheet
            // would have kept the timeline and the inspector behind it, which is exactly the
            // arrangement this mode exists to get out of the way — and there is one `AVPlayer`,
            // so two pictures of it on screen at once would be two views fighting over one
            // position. Swapping means the transport a person was using is the transport they
            // keep.
            .opacity(isCaptionEditorShown ? 0 : 1)
            .overlay {
                if isCaptionEditorShown, let player {
                    // No `AtPlayhead` here: `CaptionEditor` takes the timeline and confines
                    // the read to the waveform, which is the only part of it that moves.
                    CaptionEditor(
                        model: editor.captions, timeline: editor.timeline,
                        duration: editor.timeline.duration, waveform: editor.timeline.waveform,
                        pauses: editor.timeline.silences,
                        onSeek: { editor.timeline.movePlayhead(to: $0) },
                        onChange: { reviewRevision += 1 },
                        onClose: { isCaptionEditorShown = false },
                        picture: {
                            AnyView(VStack(spacing: 0) {
                                PreviewView(player: player)
                                Divider().overlay(Theme.Line.hairline)
                                TransportBar(player: player, model: editor.timeline)
                            })
                        })
                }
            }
    }

    @ViewBuilder private var stage: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                CanvasBar(variant: $editor.variant, crop: $editor.crop, isCropping: $isCropping,
                          showsSafeFrame: $showsSafeFrame,
                          outputWidth: editor.outputSize.width,
                          outputHeight: editor.outputSize.height,
                          onChange: { reviewRevision += 1 })
                Divider().overlay(Theme.Line.hairline)
                Group {
                    if let player {
                        PreviewView(player: player)
                    } else if let failure {
                        ContentUnavailableView("Could not build the preview",
                                               systemImage: "exclamationmark.triangle",
                                               description: Text(verbatim: failure))
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
                    let size = editor.outputSize
                    PreviewOverlay(outputWidth: size.width, outputHeight: size.height,
                                   texts: editor.texts, redactions: editor.redactions, tab: inspectorTab,
                                   onChange: { reviewRevision += 1 },
                                   cameraStyle: $editor.cameraStyle,
                                   hasCamera: cameraURL != nil && !editor.cameraStyle.isHidden)
                }
                .overlay {
                    if showsSafeFrame {
                        let size = editor.outputSize
                        SafeFrameOverlay(outputWidth: size.width, outputHeight: size.height)
                    }
                }
                .overlay {
                    if isCropping {
                        let size = editor.outputSize
                        CropOverlay(crop: $editor.crop, outputWidth: size.width,
                                    outputHeight: size.height,
                                    onCommit: { reviewRevision += 1 })
                    }
                }
                // **The picture's area is dark in both themes**, backdrop and everything drawn
                // over it: its ground is black whatever the window is, so a handle or a label in
                // the light theme's dark lane colours would vanish into it.
                .environment(\.colorScheme, .dark)
                if let player {
                    Divider()
                    TransportBar(player: player, model: editor.timeline)
                }
            }
            .frame(minHeight: 240)

            // **A divider this file owns, not `VSplitView`'s.** SwiftUI's split views cannot be
            // collapsed programmatically and do not remember where they were left, and both are
            // things a person expects of an editor. A timeline you have to re-drag every
            // launch is one you stop dragging.
            SplitHandle { delta in
                timelineHeight = min(max(timelineHeight - delta, Self.minimumTimelineHeight),
                                     Self.maximumTimelineHeight)
            }

            VStack(spacing: 0) {
                EditorToolbar(model: editor.timeline, onChange: { editRevision += 1 },
                              mediaURL: mediaURL,
                              isCollapsed: isTimelineCollapsed) {
                    isTimelineCollapsed.toggle()
                }
                if !isTimelineCollapsed {
                    Divider()
                    TimelineEditor(model: editor.timeline, onChange: { editRevision += 1 },
                                   filmstrip: filmstrip,
                                   texts: editor.texts.track, captions: editor.captions.track,
                                   redactions: editor.redactions.track, chapters: editor.chapters.track)
                        .padding(Space.regular)
                        .frame(height: timelineHeight - EditorToolbar.height)
                }
            }
            .animation(.easeOut(duration: 0.18), value: isTimelineCollapsed)
        }
        .background(Theme.Surface.base)
        // **Not pinned to dark any more** (2026-09-27): the window follows the Appearance
        // setting, and the reason this pin gave — a light surround misrepresents the picture —
        // is honoured where it applies, by the preview's black backdrop. See `Theme`.
        .tint(Theme.accent)
        // **A shortcut inside a toolbar menu is not registered until the menu is opened**, so
        // ⌥⌘E did nothing on a fresh window — measured. It lives here, on a live zero-sized
        // button, as the timeline's own shortcuts do (`TimelineEditor.shortcutLayer`).
        .background {
            Button("Export Frame…") { exportFrame() }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(player == nil)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .navigationTitle(Text(verbatim: recordingName))
        .navigationDocument(editor.savedPackage ?? mediaURL)
        .task(id: mediaURL) { await load() }
        // The setting can be changed while an editor is open; without this it would take a
        // reopen to have any effect, which reads as the switch not working.
        .task(id: scrubAudioIsOn) { editor.timeline.scrubAudio.isEnabled = scrubAudioIsOn }
        // **The mix changes what you hear WITHOUT reloading anything.** A mute applied by
        // rebuilding the player item would reload the asset, lose the position and go silent
        // for as long as that took — so a person testing whether to keep their narration would
        // be judging it across a gap. `AVPlayerItem.audioMix` is honoured mid-playback, which
        // is the whole reason this is a separate path from the export's.
        .task(id: editor.audioMix) {
            guard let item = player?.currentItem, let asset = playingAsset else { return }
            // Measured from the recording's own file, once, and only when somebody asks for
            // levelling — a full audio decode for a feature most projects never turn on would
            // be a second of work on every open. See `Loudness.measure(contentsOf:)`.
            if editor.audioMix.targetLoudness != nil, measuredLoudness.isEmpty {
                measuredLoudness = await Loudness.measure(contentsOf: mediaURL)
            }
            await AudioMixBuilder.apply(editor.audioMix, to: item, of: asset, measured: measuredLoudness,
                                        musicTrackID: musicTrackID, musicRamps: musicRamps)
        }
        // **Registered on every change, not once.** The closure captures this view's current
        // state, so a stale one would save an older edit than the one being asked about.
        .onChange(of: hasUnsavedChanges, initial: true) {
            UnsavedWorkGuard.shared.update(hasUnsavedChanges: hasUnsavedChanges,
                                           isNeverSaved: editor.savedPackage == nil) {
                saveProject()
                return editor.savedPackage != nil && editor.currentEditState(hasCamera: cameraURL != nil) == editor.savedEdit
            }
        }
        // The preview follows the chosen shape: showing landscape while Portrait is selected
        // would be showing the wrong thing, which is the fault this surface exists against.
        .task { CodecVerdicts.shared.askOnce() }
        .task(id: mediaURL) { recordedAt = RecordingName.creationDate(of: mediaURL) }
        .task {
            guard !hasSeededCameraStyle else { return }
            hasSeededCameraStyle = true
            editor.cameraStyle = initialCameraStyle
        }
        .task(id: editor.variant) { await load() }
        // **A full rebuild, not a mix change.** Noise removal replaces a whole audio TRACK in
        // the composition, which `audioMix`'s cheaper path above cannot do — that one only moves
        // volume ramps on tracks that are already there.
        .task(id: editor.noiseReduction) { if editor.noiseReduction != nil || cleanedMicrophone != nil { await load() } }
        // **The file, not the whole bed.** Changing the piece means a different track in the
        // composition and a rebuild; changing its level or its ducking is a volume automation,
        // which the sibling below re-applies without touching the asset.
        .task(id: editor.music.filename) { if editor.music.filename != nil || musicTrackID != nil { await load() } }
        .task(id: editor.music) {
            guard let item = player?.currentItem, let asset = playingAsset else { return }
            await AudioMixBuilder.apply(editor.audioMix, to: item, of: asset, measured: measuredLoudness,
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
        .task(id: editor.timeline.seekRequest) {
            guard let player,
                  let output = editor.timeline.edit.outputTime(atSource: editor.timeline.playhead)
            else { return }
            await player.seek(to: CMTime(value: output.rawValue, timescale: 1_000_000_000),
                              toleranceBefore: .zero, toleranceAfter: .zero)
        }
        // `reviewRevision` and not `review.overrides`: the composition is rebuilt when a
        // decision changes, and a counter says exactly that. Observing the array would also fire
        // on a load that merely restored the same decisions.
        //
        // **A style change rebuilds nothing; it seeks zero distance.** `StageCompositor` reads
        // style, cursor, captions, text and redactions from statics at render time, so a change
        // is already in force for the next frame and a PLAYING preview simply shows it. A PAUSED
        // one needs a reason to redraw the frame it is holding, which this is. Rebuilding instead
        // reloaded the asset, lost the position and stopped the sound — why every slider used to
        // interrupt playback — and deferring the bump to end-of-drag left a paused preview frozen
        // while the slider moved, which is a control people learn not to trust.
        //
        // **Seeking on every tick is safe, and AVPlayer is what makes it so.** A seek issued
        // while one is in progress supersedes it — the earlier handler gets `finished: false` —
        // and `.task(id:)` cancels the previous task, so nothing accumulates on either side.
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
        .task(id: editor.zoomIntensity) {
            StageCompositor.zoomIntensity = editor.zoomIntensity
            // The lane and the camera read one derivation; without this the blocks a person
            // sees would keep the depths the dial just changed.
            refreshDerivedZooms()
        }
        .task(id: editor.cameraPace) { StageCompositor.cameraPace = editor.cameraPace }
        .task(id: editor.crop) {
            StageCompositor.crop = editor.crop
            // Coverage depends on the cropped aspect, so it moves with the crop or it lies.
            StageCompositor.outputCoverage = editor.outputCoverage
        }
        .task(id: editor.cameraStyle) {
            guard StageCompositor.cameraTrackID != nil else { return }
            StageCompositor.cameraStyle = editor.cameraStyle
        }
        .inspector(isPresented: $isReviewShown) {
            // **A vertical rail, not a row of tabs across the top.** The reason shows as soon
            // as there are more than three sections: a horizontal strip competes
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
                // **Always enabled once there is something to save**, and the menu carries the
                // ALTERNATIVE rather than a copy of the button. It used to disable itself when
                // nothing had changed, say "Saved", and repeat Save as the menu's first item:
                // a person wanting a second copy elsewhere had no way to ask, a button that
                // cannot be pressed cannot explain that, and a split button whose menu repeats
                // its own action reads as a control nobody finished.
                //
                // **The label is an action, not a status.** "Save…" whenever anything was
                // unsaved promised a dialog that a project with a home never shows. The ellipsis
                // is now the HIG's rule — present only while saving really would ask where —
                // and the dirty state stays in the title, where this file already put it.
                Menu {
                    Button("Save As…") { saveProject(askingForDestination: true) }
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                } label: {
                    editor.savedPackage == nil ? Text("Save\u{2026}") : Text("Save")
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
                // A menu with a primary action, like Save: the button still exports the video,
                // and the frame under the playhead is one click further.
                Menu {
                    Button("Export Frame…") { exportFrame() }
                } label: {
                    Text("Export…")
                } primaryAction: {
                    startExport()
                }
                .disabled(player == nil)
            }
            // **A mode this app has needs a way in that does not require finding it.** The
            // button inside the Captions inspector section is where somebody already working on
            // captions will look; ⌘⇧C is what somebody who has used the mode once will reach
            // for, and neither of those is somebody discovering it. A toolbar item is.
            ToolbarItem {
                Button {
                    isCaptionEditorShown = true
                } label: {
                    Label("Captions", systemImage: "captions.bubble")
                }
                .disabled(editor.captions.track.isEmpty)
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .help(editor.captions.track.isEmpty
                      ? Text("Make captions first \u{2014} the Captions section in the inspector")
                      : Text("Captions at full width, with the waveform"))
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
            // So the command is offered directly: an explicit "Enter Full Screen" wired to
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
            get: { editor.projectStatus != nil }, set: { if !$0 { editor.projectStatus = nil } })
        ) {
            Button("OK") { editor.projectStatus = nil }
        } message: {
            Text(verbatim: editor.projectStatus ?? "")
        }
        .alert("Export", isPresented: Binding(
            get: { exportStatus != nil }, set: { if !$0 { exportStatus = nil } })
        ) {
            Button("OK") { exportStatus = nil }
        } message: {
            Text(verbatim: exportStatus ?? "")
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
        let renderer = try CoreImageFrameRenderer()
        StageCompositor.renderer = renderer
        // Where an image background is read from. Set before the composition reaches
        // AVFoundation, on the same terms as every other static here.
        CoreImageFrameRenderer.imageBaseURL = mediaURL.map(ProjectStore.packageURL(forMediaAt:))
        // Where a project's own fonts are read from. Set beside the image base and cleared with
        // it: a stale base would resolve THIS project's caption font out of the LAST project's
        // package, which draws correctly and is the wrong font.
        TextArt.fontBaseURL = CoreImageFrameRenderer.imageBaseURL
        TextArt.forgetProjectFonts()
        // The system's own cursor artwork, which the compositor cannot fetch for
        // itself — `HeadlessCheck` bans AppKit from that tier. Handed over here so
        // the preview and the export draw the same thing, and re-read on every
        // composition rather than cached: a macOS that redraws its cursors between
        // two exports should change the second one.
        await MainActor.run { SystemCursorShape.handArtworkToTheCompositor() }
        // A fresh recording gets a fresh drop count; a stale one must not read as this file's.
        StageCompositor.resetDiagnostics()
        // `expectedLogURL(forMediaURL:)` names where a log for this media would be; it does not
        // claim one exists. The filesystem check decides between "no log" and "a log", which
        // `PointerReading`'s cases keep distinguishable — `nil` means draw no pointer.
        let candidateLogURL = mediaURL.flatMap { ObservationWriter.expectedLogURL(forMediaURL: $0) }
        StageCompositor.observationLogURL = candidateLogURL.flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
        }
        // **The PREVIEW's size, which is not the export's, and that is the whole of this.**
        let size = EditorViewModel.previewSize(for: variant, resolution: resolution,
                                    recordingShortSide: recordingShortSide)
        // **One throwaway frame before AVFoundation asks for a real one.** `CIContext` compiles
        // its Metal kernels on first use, and without this the editor paid for that on the frame
        // somebody pressed play for — which is a frame that misses its deadline and is dropped.
        // Detached, so opening a project is not held up by it; at the preview's own size, since
        // warming a different size leaves the real one's allocations unmade.
        let warmStyle = StageCompositor.style
        Task.detached(priority: .utility) {
            renderer.warmUp(outputWidth: size.width, outputHeight: size.height, style: warmStyle)
        }
        return try await CompositionBuilder.composition(
            for: asset, outputWidth: size.width, outputHeight: size.height,
            frameDuration: CMTime(value: 1, timescale: 60))
    }

    /// **Two tabs: what the whole export is, and what is selected.**
    ///
    /// The two answer different questions: "how should this video look" is asked once, and
    /// "what is this thing I just clicked" is asked constantly. A flat
    /// list mixes them, so the answer to the second is always somewhere below the answer to the
    /// first.
    /// The inspector's section rail — a column of icons on the panel's edge.
    ///
    /// **A rail, not a row of tabs across the top.** The reason shows as soon as there are more
    /// than three sections: a horizontal strip competes with the panel's own width, which is the
    /// dimension a
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
            Text(LocalizedStringKey(inspectorTab.title))
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
                        StageStylePicker(model: editor.stageStyle, onChange: { reviewRevision += 1 },
                                         packageURL: ProjectStore.packageURL(forMediaAt: mediaURL))
                    }
                    if cameraURL != nil {
                        Section("Camera") { cameraControls }
                    }
                    Section("Cursor") {
                        StageStylePicker(model: editor.stageStyle,
                                         onChange: { reviewRevision += 1 }).cursorControls
                    }
                    Section("Audio") { audioControls }
                    Section("Animated GIF") { gifControls }
                }
                .listStyle(.sidebar)
            case .selection:
                List {
                    Section("Zoom amount") { zoomIntensityControl }
                    AtPlayhead(model: editor.timeline) { playhead in
                        FramingReviewSections(model: editor.review, onChange: { reviewRevision += 1 },
                                              playhead: playhead)
                    }
                }
                .listStyle(.sidebar)
            case .captions:
                let size = editor.outputSize
                // No `AtPlayhead`: the panel reads `captions.currentCueIndex`, which changes
                // when the highlighted cue changes rather than ten times a second.
                //
                // **The caption editor's way in moved INSIDE the panel**, into the Captions
                // half of it. Above the panel it sat over both halves, and it is the full-width
                // version of one of them — a button for captions floating over the transcript
                // is a control whose subject you have to work out.
                CaptionsPanel(model: editor.captions, mediaURL: mediaURL, recordingName: recordingName,
                              edit: editor.timeline.edit,
                              outputWidth: size.width, outputHeight: size.height,
                              onChange: { reviewRevision += 1 },
                              playheadNow: { editor.timeline.playhead },
                              onSeek: { editor.timeline.movePlayhead(to: $0) },
                              pauses: editor.timeline.silences,
                              transcript: editor.captions.transcript,
                              onDeleteRange: { range, name in
                                  editor.timeline.removeSourceRange(range, named: name)
                              },
                              onOpenEditor: { isCaptionEditorShown = true })
            case .chapters:
                AtPlayhead(model: editor.timeline) { playhead in
                    ChaptersPanel(model: editor.chapters, edit: editor.timeline.edit,
                                  transcript: editor.captions.transcript, playhead: playhead,
                                  onSeek: { editor.timeline.movePlayhead(to: $0) },
                                  onChange: { editRevision += 1 })
                }
            case .text:
                AtPlayhead(model: editor.timeline) { playhead in
                    TextPanel(model: editor.texts, playhead: playhead,
                              onChange: { reviewRevision += 1 })
                }
            case .hide:
                AtPlayhead(model: editor.timeline) { playhead in
                    RedactionPanel(model: editor.redactions, playhead: playhead,
                                   onChange: { reviewRevision += 1 })
                }
            case .mark:
                AtPlayhead(model: editor.timeline) { playhead in
                    AnnotationPanel(model: editor.annotations, playhead: playhead,
                                    packageURL: ProjectStore.packageURL(forMediaAt: mediaURL),
                                    onChange: { reviewRevision += 1 })
                }
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
            get: { !editor.cameraStyle.isHidden },
            set: { editor.cameraStyle = editor.cameraStyle.changing(isHidden: !$0); reviewRevision += 1 }))
        // **The room behind the person, cut away or kept** — see `PersonMask`.
        //
        // Turning it on warms Vision's models on a detached task. The first segmentation of each
        // level costs one to two seconds loading the model and every one after it costs 21 ms;
        // paid here, seconds before anybody scrubs to a frame with a camera in it, it is never
        // paid on a frame somebody is waiting for. Detached because it is not the picker's job
        // to wait for it, and nothing about the answer is needed to draw the next frame.
        Picker("Background", selection: Binding(
            get: { editor.cameraStyle.background },
            set: { editor.cameraStyle = editor.cameraStyle.changing(background: $0)
                   if $0 == .removed { Task.detached(priority: .utility) { PersonMask.warmUp() } }
                   reviewRevision += 1 })) {
            ForEach(CameraOverlayStyle.Background.allCases, id: \.self) {
                Text(LocalizedStringKey($0.displayName)).tag($0)
            }
        }
        // **The system's own blur is one control away and is not reimplemented here.** Portrait
        // mode runs inside the camera pipeline for free; a hand-written blur would be slower and
        // worse. Said in the interface because somebody looking for "blur my background" will
        // look here first, and sending them two clicks away beats offering them a worse copy.
        if editor.cameraStyle.background == .keep {
            Text("To blur the background instead, turn on Portrait in the camera effects.")
                .font(Type.detail).foregroundStyle(.secondary)
        } else {
            // **The cost, on screen, before it is discovered.** Cutting a person out is 21 ms a
            // frame — measured — on top of everything else a frame costs, and somebody whose
            // preview has just become less smooth is owed the reason rather than left to
            // conclude the app got slower. Nothing is sent anywhere: this runs on this Mac.
            Text("Cut out on this Mac, frame by frame — around 21 ms each, so previews and exports take longer with this on.")
                .font(Type.detail).foregroundStyle(.secondary)
        }
        // **A cut-out person has no card**, so the controls that shape one are not offered while
        // the background is gone. They keep their values — switching back restores the card
        // exactly — they simply do nothing, and a control that does nothing is one people
        // conclude is broken. The same argument the corner slider already makes for a circle.
        if editor.cameraStyle.background == .keep {
            Picker("Shape", selection: Binding(
                get: { editor.cameraStyle.shape },
                set: { editor.cameraStyle = editor.cameraStyle.changing(shape: $0); reviewRevision += 1 })) {
                ForEach(CameraOverlayStyle.Shape.allCases, id: \.self) {
                    Text(LocalizedStringKey($0.displayName)).tag($0)
                }
            }
        }
        // **Only for the shape that has corners.** A slider that does nothing on a circle and
        // nothing on a square is a slider people conclude is broken.
        if editor.cameraStyle.shape == .rounded, editor.cameraStyle.background == .keep {
            Slider(value: Binding(
                get: { editor.cameraStyle.cornerFraction },
                set: { editor.cameraStyle = editor.cameraStyle.changing(cornerFraction: $0)
                       reviewRevision += 1 }),
                   in: 0...0.5) { Text("Corner") }
        }
        Slider(value: Binding(get: { editor.cameraStyle.widthFraction },
                              set: { editor.cameraStyle = editor.cameraStyle.changing(widthFraction: $0)
                                     reviewRevision += 1 }),
               in: 0.05...0.5) { Text("Size") }
        // **How much the camera shrinks while the stage is zoomed in.** A zoom makes the picture
        // bigger, and a camera that holds its width is covering a larger share of a smaller area
        // — which is exactly when it is most in the way. 1 holds the size, which is what this
        // did before the control existed.
        Slider(value: Binding(get: { editor.cameraStyle.scaleDuringZoom },
                              set: { editor.cameraStyle = editor.cameraStyle.changing(scaleDuringZoom: $0)
                                     reviewRevision += 1 }),
               in: 0.3...1) { Text("Shrink on zoom") }
        Slider(value: Binding(get: { editor.cameraStyle.x },
                              set: { editor.cameraStyle = editor.cameraStyle.changing(x: $0)
                                     reviewRevision += 1 }),
               in: 0...1) { Text("Across") }
        Slider(value: Binding(get: { editor.cameraStyle.y },
                              set: { editor.cameraStyle = editor.cameraStyle.changing(y: $0)
                                     reviewRevision += 1 }),
               in: 0...1) { Text("Up from the bottom") }
        // **Out of the cursor's way.** The classic flaw is a face over the thing being shown.
        // The camera goes to a corner while the cursor is on it and comes back once the cursor
        // has been clear for a while; see `CameraDodge`.
        Toggle("Move out of the cursor's way", isOn: Binding(
            get: { editor.cameraStyle.avoidsCursor },
            set: { editor.cameraStyle = editor.cameraStyle.changing(avoidsCursor: $0); reviewRevision += 1 }))
            .font(Type.detail)
        Toggle("Mirror", isOn: Binding(
            get: { editor.cameraStyle.isMirrored },
            set: { editor.cameraStyle = editor.cameraStyle.changing(isMirrored: $0); reviewRevision += 1 }))
    }

    @ViewBuilder private var outputControls: some View {
        // The recording's own shape first when it is not already one of the three — see
        // `AspectVariant.available(recordingWidth:recordingHeight:)`.
        Picker("Shape", selection: Binding(
            get: { editor.variant },
            set: { editor.variant = $0; editor.chosenShapeDeliberately = true })) {
            ForEach(AspectVariant.available(recordingWidth: editor.recordingSize.width,
                                            recordingHeight: editor.recordingSize.height),
                    id: \.self) { shape in
                Text(LocalizedStringKey(shape.name)).tag(shape)
            }
        }
        let size = editor.outputSize
        LabeledContent("Size", value: "\(size.width)\u{00D7}\(size.height)")
            .font(Type.detail).foregroundStyle(.secondary)

        // **A destination, as the four settings below it.** Choosing one sets them and then gets
        // out of the way — the four stay live, and changing any of them puts this back to
        // Custom rather than silently claiming an export is still "Web" when it is not. See
        // `ExportPreset`.
        Picker("For", selection: $editor.preset) {
            // Not selectable: "Custom" is a description of where the four controls are, not a
            // thing to choose. Choosing it would have to mean "put them back", and there is no
            // back to put them to.
            Text("Custom").tag(ExportPreset?.none)
            ForEach(ExportPreset.all, id: \.self) { preset in
                Text(LocalizedStringKey(preset.name)).tag(ExportPreset?.some(preset))
            }
        }
        if let preset = editor.preset {
            Text(LocalizedStringKey(preset.detail))
                .font(Type.detail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        // **How large, by SHORT side.** A ladder written as 1920×1080 cannot describe a portrait
        // output, and this app exports portrait and square for the places people post them.
        Picker("Resolution", selection: Binding(
            get: { editor.resolution }, set: { editor.resolution = $0 })) {
            ForEach(ExportResolution.available(recordingShortSide: editor.recordingShortSide),
                    id: \.self) { choice in
                Text(LocalizedStringKey(choice.displayName)).tag(choice)
            }
        }
        Picker("Frame rate", selection: Binding(
            get: { editor.frameRate }, set: { editor.frameRate = $0 })) {
            ForEach(ExportFrameRate.available(recording: editor.recordingFrameRate),
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
        Picker("Format", selection: Binding(get: { editor.codec }, set: { editor.codec = $0 })) {
            ForEach(editor.stageStyle.isTransparent
                    ? TransparentExport.codecsThatCarryIt
                    : ExportCodec.allCases, id: \.self) { choice in
                Text(LocalizedStringKey(choice.displayName)).tag(choice)
            }
        }
        // **Snapped rather than left dangling.** Somebody who had chosen H.264 and then made the
        // background transparent has a selection that is no longer in the list; SwiftUI would
        // show an empty picker and the export would refuse. Moving it to the smallest format that
        // works is visible — the picker changes in front of them — which is the difference
        // between this and a silent correction at export time.
        .task(id: editor.stageStyle.isTransparent) { editor.keepCodecAbleToCarryTransparency() }
        if editor.stageStyle.isTransparent {
            Text("The background is transparent, so only formats that keep an alpha channel are offered. HEVC with Alpha is around a hundred times smaller than ProRes 4444 for the same picture.")
                .font(Type.detail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // **What this Mac's encoder actually does with a coloured edge**, asked rather than
        // tabulated — see `CodecVerdicts`. Silent when the probe could not run: "we could not
        // ask" and "the answer is no" are different things.
        if let note = CodecVerdicts.shared.note(for: editor.codec) {
            Text(LocalizedStringKey(note))
                .font(Type.detail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // **How many bits the picture gets.** Nothing was choosing before, so AVFoundation did —
        // at a rate tuned for camera footage, which is the wrong content. See `ExportQuality`.
        if editor.codec.takesBitRate {
            Picker("Quality", selection: Binding(
                get: { editor.quality }, set: { editor.quality = $0 })) {
                ForEach(ExportQuality.choices, id: \.self) { choice in
                    Text(LocalizedStringKey(choice.displayName)).tag(choice)
                }
            }
        }
        // **The estimate is why the picker is usable.** A quality control with no consequence
        // attached is three words to guess between.
        if let range = editor.timeline.exportRange {
            // **Named in the sheet, because the button says "Export" either way.** Somebody who
            // marked a section an hour ago and came back to export has no other way to find out
            // that the file will be ten seconds long.
            let seconds = Double(range.upperBound - range.lowerBound) / 1_000_000_000
            let whole = TransportBar.timecode(Double(editor.timeline.edit.outputDuration.rawValue) / 1e9)
            LabeledContent("Range") { Text("\(TransportBar.timecode(seconds)) of \(whole)") }
                .font(Type.detail).foregroundStyle(Theme.Ink.accent)
        }
        LabeledContent("About", value: Self.fileSize(editor.estimatedExportBytes))
            .font(Type.detail).foregroundStyle(.secondary)

        Divider()

        // **A separate button, not a third entry in the save panel's format popup.** Every
        // control above this — resolution, codec, quality, the size estimate — describes a
        // rendered picture, and none of them applies to a cut list. Folding it into the same
        // panel would offer somebody a bit rate for a text file.
        //
        // It also runs instantly rather than through `ExportQueue`: there is nothing to render.
        Button("Export Final Cut XML\u{2026}") { exportFinalCutXML() }
            .disabled(editor.timeline.editForExport.isEmpty)
        // **What it carries and what it does not, before the click rather than after it.**
        // "Export to Final Cut" reads like a promise to carry everything, and the honest answer
        // is that it carries the cut and none of the look — which is exactly what somebody
        // finishing in another application wants, and nothing like what they would expect if
        // nobody said so.
        Text("The cut only — your clips and their in-points, against the original recording, with the camera on its own lane. None of the look travels: no zooms, no cursor, no background. DaVinci Resolve reads the same file.")
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
        panel.nameFieldStringValue = recordingName + ".fcpxml"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let name = recordingName
        let edit = editor.timeline.editForExport
        let rate = editor.recordingFrameRate
        let media = mediaURL
        // **The camera and its offset, captured with the rest of the job.** The offset is
        // `cameraStart - screenStart`, measured by the recorder from the two recordings' own
        // first-frame instants — the same number the preview composites with.
        let cameraMedia = cameraURL
        let cameraOffset = cameraStartOffsetNanos
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
            // The camera's own shape, read from its own file: a webcam is almost never the
            // screen's aspect, and describing it by the screen's would letterbox it.
            var cameraSource: FinalCutXML.Source?
            if let cameraMedia {
                let cameraAsset = AVURLAsset(url: cameraMedia)
                let cameraDuration = (try? await cameraAsset.load(.duration)) ?? .zero
                if let cameraTrack = try? await cameraAsset.loadTracks(withMediaType: .video).first {
                    let natural = (try? await cameraTrack.load(.naturalSize)) ?? .zero
                    let transform = (try? await cameraTrack.load(.preferredTransform)) ?? .identity
                    let cameraSize = CGGeometryBridge.displayedPixelSize(of: natural,
                                                                        transform: transform)
                    let cameraAudio = ((try? await cameraAsset.loadTracks(withMediaType: .audio))
                                       ?? []).isEmpty == false
                    cameraSource = FinalCutXML.Source(
                        url: cameraMedia,
                        duration: Nanoseconds(Int64((cameraDuration.seconds * 1_000_000_000)
                            .rounded())),
                        width: cameraSize.width, height: cameraSize.height,
                        frameRate: rate, hasAudio: cameraAudio)
                }
            }
            switch FinalCutXML.document(timeline: edit, source: source, camera: cameraSource,
                                        cameraOffset: Nanoseconds(cameraOffset),
                                        projectName: name) {
            case .document(let xml):
                do {
                    try xml.write(to: destination, atomically: true, encoding: .utf8)
                    exportStatus = String(localized: "Wrote \(destination.lastPathComponent).")
                } catch {
                    exportStatus = String(localized:
                        "Could not write \(destination.lastPathComponent): \(String(describing: error))")
                }
            case .refused(let refusal):
                // Named rather than generic: the three reasons have three different fixes, and a
                // person told only that it failed cannot act on any of them.
                exportStatus = switch refusal {
                case .theEditKeepsNothing:
                    String(localized:
                        "The edit removes the whole recording, so there is no cut to export.")
                case .theFrameRateIsNotAFrameRate:
                    String(localized: "The recording reports no frame rate, and every time in the file has to be a whole frame.")
                case .theRecordingHasNoSize:
                    String(localized:
                        "The recording reports no size, so there is no sequence to describe.")
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
        Picker("Frames", selection: $editor.gifSettings.frameRate) {
            ForEach(GIFSettings.exactRates, id: \.self) { rate in
                Text("\(rate) fps").tag(rate)
            }
        }
        Picker("Longest edge", selection: $editor.gifSettings.maximumLongestEdge) {
            Text("480 px").tag(480)
            Text("640 px").tag(640)
            Text("960 px").tag(960)
            Text("1280 px").tag(1280)
        }
        Toggle("Loop forever", isOn: $editor.gifSettings.loops)

        let size = editor.outputSize
        let gif = editor.gifSettings.size(fitting: size.width, height: size.height)
        // The size is worth stating because it is not the export size beside it, and the
        // "no sound" is worth stating because a person who recorded themselves talking would
        // otherwise find that out from the file.
        LabeledContent("GIF", value: "\(gif.width)\u{00D7}\(gif.height), no sound")
            .font(Type.detail).foregroundStyle(.secondary)
        // **A GIF has no inter-frame compression worth the name**, so its size is frames times
        // pixels and nothing else — a twenty-second 640-wide GIF is tens of megabytes, which is
        // past what most places accept. Warned about here rather than letting somebody find
        // out from the upload.
        // `editForExport`, not `edit`: with a section marked, the file being estimated is
        // the section. A figure for the whole video beside a button that writes ten seconds of
        // it is worse than no figure.
        let seconds = Double(editor.timeline.editForExport.outputDuration.rawValue) / 1_000_000_000
        let gifBytes = Int(Double(gif.width * gif.height) * 0.5 * 0.07
                           * Double(editor.gifSettings.frameRate) * seconds)
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
                get: { editor.noiseReduction != nil },
                set: { editor.noiseReduction = $0 ? .default : nil })
            ) {
                Text("Remove background noise")
            }
            .toggleStyle(.checkbox)
            .font(.caption)

            if editor.noiseReduction != nil {
                HStack {
                    Text("Strength").font(.caption).foregroundStyle(.secondary)
                    LiveSlider(
                        value: editor.noiseReduction?.strength
                            ?? NoiseReduction.Settings.default.strength,
                        // **Not the type's full 0…4 range.** Zero removes nothing, and above
                        // three the voice starts going with the room — a range whose ends are
                        // both useless is a slider that spends most of its travel doing harm.
                        range: 0.5...3.0,
                        commit: { strength in
                            editor.noiseReduction = .init(
                                strength: strength,
                                floor: editor.noiseReduction?.floor
                                    ?? NoiseReduction.Settings.default.floor)
                        })
                }
            }
            // **What it can and cannot do, on screen.** It takes out a fan, a hum, a laptop under
            // load — sound that is there the whole time. It does not take out a door, a keyboard
            // or a dog, and somebody who expects it to will conclude the feature is broken.
            (noiseReductionNote.map { Text(verbatim: $0) }
                 ?? Text("Removes steady sound — a fan, a hum, air conditioning — from the microphone only. It cannot remove a one-off noise like a door or a keyboard."))
                .font(Type.detail)
                .foregroundStyle(noiseReductionNote == nil ? .secondary : Signal.paused)
        }
        .padding(.bottom, 2)

        ForEach(AudioMix.Source.allCases, id: \.self) { source in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Toggle(isOn: Binding(
                        get: { !editor.audioMix.isMuted(source) },
                        set: { editor.audioMix = editor.audioMix.setting(source, muted: !$0) })
                    ) {
                        Text(LocalizedStringKey(source.displayName))
                    }
                    .toggleStyle(.checkbox)
                    Spacer()
                    Text(verbatim: "\(Int((editor.audioMix.gain(for: source) * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(editor.audioMix.isMuted(source) ? .tertiary : .secondary)
                }
                .font(.caption)
                Slider(value: Binding(
                    get: { editor.audioMix.gain(for: source) },
                    set: { editor.audioMix = editor.audioMix.setting(source, gain: $0) }),
                       in: 0...AudioMix.maximumGain)
                    // A muted source's slider is disabled rather than hidden: the level is
                    // still there, and hiding it would suggest it had been lost.
                    .disabled(editor.audioMix.isMuted(source))
            }
        }
        // **Levelling, which every comparable recorder ships and this had none of.** A demo's
        // narration sits at whatever level the microphone happened to be at, and every platform
        // it is posted to renormalises by loudness — so a file that ignores loudness is a file
        // the platform will change. The target is in
        // LUFS because that is the unit the platforms publish theirs in; the measurement and
        // the gain that follows are `Loudness`'s.
        Divider()
        Toggle(isOn: Binding(
            get: { editor.audioMix.targetLoudness != nil },
            set: { editor.audioMix = editor.audioMix.settingTargetLoudness(
                $0 ? Loudness.defaultTargetLUFS : nil) })
        ) {
            Text("Match a loudness target")
        }
        .toggleStyle(.checkbox)
        .font(.caption)
        if let target = editor.audioMix.targetLoudness {
            HStack {
                Text("Target").font(.caption)
                Spacer()
                Text(verbatim: "\(Int(target.rounded())) LUFS")
                    .monospacedDigit().foregroundStyle(.secondary).font(.caption)
            }
            Slider(value: Binding(get: { target },
                                  set: { editor.audioMix = editor.audioMix.settingTargetLoudness($0.rounded()) }),
                   in: AudioMix.quietestTarget...AudioMix.loudestTarget)
            Text("YouTube and Spotify normalise to \u{2212}14; \u{2212}16 leaves a little headroom under it.")
                .font(Type.detail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if editor.audioMix.changesAnything {
            Button("Reset audio") { editor.audioMix = .unchanged; measuredLoudness = [:] }
                .buttonStyle(.link).font(.caption)
        }
        Divider()
        musicControls
    }

    /// **A music bed, and how far out of the way it gets when somebody speaks.**
    ///
    /// The file is copied into the project — `MusicBed` says why — and the envelope
    /// comes from the silences the timeline already found, so there is one answer to "where is
    /// the voice" rather than two.
    @ViewBuilder private var musicControls: some View {
        HStack {
            Text("Music").font(.caption)
            Spacer()
            if let name = editor.music.filename {
                Text(verbatim: name).font(Type.detail).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Button {
                if let source = Self.chooseAudio() { adoptMusic(source) }
            } label: {
                editor.music.filename == nil ? Text("Choose\u{2026}") : Text("Replace\u{2026}")
            }
            .buttonStyle(.link).font(.caption)
        }
        if let failure = musicFailure {
            Text(verbatim: failure).font(Type.detail).foregroundStyle(Signal.paused)
                .fixedSize(horizontal: false, vertical: true)
        }
        if editor.music.filename != nil {
            Toggle("Play the music", isOn: Binding(
                get: { editor.music.isEnabled },
                set: { editor.music = editor.music.changing(isEnabled: $0) }))
                .toggleStyle(.checkbox).font(.caption)
            musicSlider("Music level", value: editor.music.ducking.bedGain, upTo: 1) { value in
                let settings = editor.music.ducking
                editor.music = editor.music.changing(ducking: MusicDucking.Settings(
                    bedGain: value, duckedGain: min(settings.duckedGain, value),
                    attack: settings.attack, release: settings.release, hold: settings.hold))
            }
            Toggle("Lower it while I speak", isOn: Binding(
                get: { editor.music.ducks },
                set: { editor.music = editor.music.changing(ducks: $0) }))
                .toggleStyle(.checkbox).font(.caption)
            if editor.music.ducks {
                musicSlider("Level while speaking", value: editor.music.ducking.duckedGain,
                            upTo: editor.music.ducking.bedGain) { value in
                    let settings = editor.music.ducking
                    editor.music = editor.music.changing(ducking: MusicDucking.Settings(
                        bedGain: settings.bedGain, duckedGain: value,
                        attack: settings.attack, release: settings.release, hold: settings.hold))
                }
                if editor.timeline.silences.isEmpty {
                    Text("Nothing on the microphone track reads as speech yet, so the bed stays at its own level.")
                        .font(Type.detail).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button("Remove the music") {
                editor.music = MusicBed.none
                musicFailure = nil
            }
            .buttonStyle(.link).font(.caption)
        }
    }

    /// A level slider with its value written beside it. `upTo` is clamped away from zero
    /// because a `Slider` whose range is empty traps, and "level while speaking" has an upper
    /// bound that is itself a slider somebody can drag to nothing.
    @ViewBuilder private func musicSlider(_ title: LocalizedStringKey, value: Double, upTo: Double,
                                          commit: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(verbatim: "\(Int((value * 100).rounded()))%")
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
            musicFailure = String(localized: "\(name) is not a name this can use.")
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
            musicFailure = String(localized: "Could not copy \(name) into the project: \(String(describing: error))")
            return
        }
        musicFailure = nil
        editor.music = editor.music.changing(filename: .some(name), isEnabled: true)
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
        guard let settings = editor.noiseReduction,
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
                noiseReductionNote = String(localized: "Noise removal did nothing: \(String(describing: refusal)).")
                return [:]
            }
        } catch {
            cleanedMicrophone = nil
            noiseReductionNote = String(localized: "Noise removal could not run: \(String(describing: error)).")
            return [:]
        }
    }

    /// The bed's file inside the project package, or `nil` when there is none to play.
    private var musicFileURL: URL? {
        guard editor.music.isAudible, let filename = editor.music.filename else { return nil }
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
        guard editor.music.isAudible, let duration = editor.timeline.duration else { return [] }
        guard editor.music.ducks else {
            return MusicDucking.ramps(speech: [], over: duration, settings: editor.music.ducking)
        }
        return MusicDucking.ramps(
            speech: MusicDucking.speech(betweenSilences: editor.timeline.silences, over: duration),
            over: duration, settings: editor.music.ducking)
    }

    /// True when what is on screen differs from what is on disk. A scratch recording is always
    /// unsaved, because nothing has been written yet — not because it has been edited.
    private var hasUnsavedChanges: Bool {
        editor.savedPackage == nil || editor.currentEditState(hasCamera: cameraURL != nil) != editor.savedEdit
    }

    /// `askingForDestination` is Save As: it asks even when this project already has a home,
    /// and moves the project to the new one — which is what "save as" means everywhere else.
    private func saveProject(askingForDestination: Bool = false) {
        let edit = editor.currentEditState(hasCamera: cameraURL != nil)
        let existing = askingForDestination ? nil : editor.savedPackage
        let destination = existing ?? ProjectStore.chooseSaveDestination(
            defaultName: editor.savedPackage?.deletingPathExtension().lastPathComponent
                ?? recordingName)
        guard let destination else { return }
        do {
            try ProjectStore.save(recordingAt: mediaURL, edit: edit, to: destination)
            editor.savedPackage = destination
            editor.savedEdit = edit
            editor.projectStatus = String(localized: "Saved to \(destination.lastPathComponent).")
        } catch {
            editor.projectStatus = String(localized: "Could not save: \(String(describing: error))")
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
        Slider(value: $editor.zoomIntensity, in: 0...FramingDepth.maximumIntensity, step: 0.1,
               onEditingChanged: { if !$0 { reviewRevision += 1 } }) {
            Text("Amount")
        }
        Text(verbatim: zoomIntensityLabel)
            .font(Type.detail).foregroundStyle(.secondary)
        // The spring's damping stays at 1 whatever this says, so no pace overshoots.
        Picker("Speed", selection: $editor.cameraPace) {
            ForEach(CameraPace.allCases, id: \.self) { pace in
                Text(LocalizedStringKey(pace.displayName)).tag(pace)
            }
        }
        .onChange(of: editor.cameraPace) { reviewRevision += 1 }
    }

    /// Says what the dial does at the ends, because "0.0" and "2.0" do not.
    private var zoomIntensityLabel: String {
        let percent = Int((editor.zoomIntensity * 100).rounded())
        if percent == 0 { return String(localized: "No zoom anywhere. Every click is framed, none is magnified.") }
        if percent == 100 {
            return String(localized: "As derived. Adjustments you have made to single zooms still apply on top.")
        }
        return String(localized: "\(percent)% of the derived zoom. Adjustments to single zooms still apply on top.")
    }

    private func refreshDerivedZooms() {
        editor.timeline.setDerivedZooms(ZoomBlock.blocks(
            for: editor.review.plan.framedClicks(with: editor.review.overrides,
                                          pointerFallbackRevision: editor.review.fallbackRevision),
            coverage: editor.outputCoverage, intensity: editor.zoomIntensity))
    }


    private func load() async {
        do {
            // Before the composition: `configuredComposition` reads
            // `StageCompositor.framingOverrides`, which `FramingReviewModel.load` publishes.
            editor.review.load(observationLogAt: ObservationWriter.expectedLogURL(forMediaURL: mediaURL)
                .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
            // The crop before the composition: `StagePlanner` fits the card to the CROPPED
            // aspect, so a composition built while the static still said "whole" would size the
            // card for a recording that is no longer what is being drawn. It is also what
            // `outputCoverage` below is computed from, which is the other reason it goes first.
            StageCompositor.crop = editor.crop
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
                editor.recordingShortSide = Int(min(natural.width, natural.height).rounded())
                editor.recordingSize = (width: Int(natural.width.rounded()),
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
                if nominal > 0 { editor.recordingFrameRate = Int(nominal.rounded()) }
            }
            // The lane draws the same blocks the camera integrates, derived from the same
            // plan and now at the same coverage — a second derivation would be a second
            // answer, and a second coverage would be a second answer that agreed in landscape
            // and diverged in portrait, which is worse.
            StageCompositor.outputCoverage = editor.outputCoverage
            // The anchor first: the lane converts every block's absolute instant through it,
            // and blocks set before it would be drawn off the edge for one frame.
            editor.timeline.setZoomAnchor(editor.review.anchor)
            refreshDerivedZooms()
            if editor.timeline.duration == nil {
                editor.timeline.load(duration: try await recording.load(.duration).seconds)
                // **After `load`, which resets the models.** Restoring first would be wiped by
                // the reset, silently, and a person would see their saved edit vanish on open.
                if let pendingEdit {
                    editor.restore(pendingEdit)
                    editor.savedPackage = ProjectStore.packageURL(forMediaAt: mediaURL)
                }
                // After `load`, which resets the model: reading the envelope is slow enough
                // that a person sees the strip before it arrives, and it must not be wiped by
                // the reset it raced.
                await editor.timeline.loadWaveform(from: recording)
            }
            // **The preview plays the EDITED asset, not the recording with an end time set.**
            // `EditedAsset` is what the export cuts with too, so the two cannot show different
            // videos — an edit a person can make but not see is a setting, not an edit.
            // **The cleaned microphone is substituted into the cut, so preview and export
            // cannot disagree.** Export is handed the asset the preview is playing — see
            // `runExport`'s header — so wiring it here wires both, and there is no second place
            // for the two to drift apart.
            let cut = try await EditedAsset.make(
                from: recording, by: editor.timeline.edit,
                substitutingAudio: await microphoneSubstitution(for: recording))
            // The camera laid alongside the cut recording, so one composition sees both. Returns
            // the cut asset untouched when there is no camera, so the common path costs nothing.
            let combined = try await CameraComposition.combine(
                screen: cut, cameraURL: cameraURL,
                cameraStartOffset: CMTime(value: cameraStartOffsetNanos, timescale: 1_000_000_000),
                musicURL: musicFileURL)
            StageCompositor.cameraTrackID = combined.cameraTrackID
            musicTrackID = combined.musicTrackID
            StageCompositor.cameraStyle = combined.cameraTrackID == nil ? nil : editor.cameraStyle
            let asset = combined.asset
            let composition = try await Self.configuredComposition(
                for: asset, logForMediaURL: mediaURL, resolution: editor.resolution,
                recordingShortSide: editor.recordingShortSide, variant: editor.variant)
            let item = AVPlayerItem(asset: asset)
            item.videoComposition = composition
            // The mix is applied at load too, not only on change: reopening a saved project
            // with the microphone muted must sound muted before anyone touches a control.
            await AudioMixBuilder.apply(editor.audioMix, to: item, of: asset)
            playingAsset = asset
            // **The filmstrip reads the UNCUT recording**, not the edited composition: the strip
            // is laid out in source time, and a composition's own timeline has already had the
            // cuts taken out of it — so a frame asked for at 30 s would come back from a
            // different moment after every edit.
            filmstrip.load(url: mediaURL)
            // Cheap: nothing is read until the first scrub, and a recording with no audio leaves
            // it silent rather than failing.
            editor.timeline.scrubAudio.isEnabled = scrubAudioIsOn
            editor.timeline.scrubAudio.open(mediaURL)
            player = AVPlayer(playerItem: item)
        } catch {
            failure = "\(error)"
        }
    }

    /// Presents the save panel and queues what it chose. The panel comes first because a job
    /// with no destination is not a job — and because the panel's own format popup is where
    /// macOS puts the format chooser.
    /// The frame under the playhead as a PNG, at the export's size and through the export's own
    /// composition. See `docs/design/2026-09-27-one-frame-as-a-picture.md`.
    private func exportFrame() {
        guard let asset = playingAsset,
              let output = editor.timeline.edit.outputTime(atSource: editor.timeline.playhead) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = recordingName + ".png"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let size = editor.outputSize
        let time = CMTime(value: output.rawValue, timescale: 1_000_000_000)
        Task {
            do {
                try await StillFrameExporter.export(asset: asset, at: time, to: destination,
                                                    outputWidth: size.width, outputHeight: size.height)
                exportStatus = String(localized: "Saved the frame to \(destination.lastPathComponent).")
            } catch {
                exportStatus = String(localized: "Could not save the frame: \(String(describing: error))")
            }
        }
    }

    private func startExport() {
        let panel = NSSavePanel()
        // **Two types, so the panel's own format popup is the format chooser.** On macOS that
        // control already exists and lives in the save panel; a second one in the window would
        // be a second place to look for the same answer.
        // The chosen codec's container first, so the panel opens on it — ProRes is a `.mov`
        // and offering an `.mp4` for it would be offering a file other editors refuse.
        panel.allowedContentTypes = editor.codec.fileExtension == "mov" ? [.quickTimeMovie, .gif]
                                                                 : [.mpeg4Movie, .quickTimeMovie, .gif]
        panel.nameFieldStringValue = recordingName
            + "." + editor.codec.fileExtension
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
        let edit = editor.timeline.editForExport
        let mix = editor.audioMix
        // Captured with the rest of the job, for `runExport`'s reason: a queued export runs
        // later than the view that asked for it, and reading this then would read whatever had
        // been measured since.
        let loudness = measuredLoudness
        let bedTrack = musicTrackID
        let bedRamps = musicRamps
        let chosen = editor.quality
        let chosenCodec = editor.codec
        let frames = editor.frameRate.frames(recording: editor.recordingFrameRate)
        let gif = editor.gifSettings
        // Through the EXPORT's edit, so a marked section carries only the chapters inside it.
        let placedChapters = editor.exportChapters(through: edit)
        let size = editor.outputSize
        let isGIF = destination.pathExtension.lowercased() == "gif"
        let queued = ExportQueue.shared.enqueue(destination: destination) { report in
            guard let asset else { return "There is nothing loaded to export." }
            StageCompositor.apply(settings)
            return await Self.runExport(asset: asset, to: destination, isGIF: isGIF,
                                        size: size, edit: edit, audioMix: mix,
                                        measuredLoudness: loudness,
                                        musicTrackID: bedTrack, musicRamps: bedRamps,
                                        quality: chosen, codec: chosenCodec,
                                        frameRate: frames, gifSettings: gif,
                                        chapters: placedChapters, report: report)
        }
        if queued == nil {
            // Named, because the only way somebody works out which of their jobs they collided
            // with is being told the filename.
            exportStatus = String(localized: "An export to \(destination.lastPathComponent) is already waiting.")
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
                          audioMix: AudioMix, measuredLoudness: [Int: Loudness.Reading],
                          musicTrackID: CMPersistentTrackID?, musicRamps: [MusicDucking.Ramp],
                          quality: ExportQuality, codec: ExportCodec,
                          frameRate: Int, gifSettings: GIFSettings,
                          chapters: [PlacedChapter] = [],
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
                    chapters: chapters,
                    onProgress: { progress in Task { @MainActor in report(progress) } })
            }
            // **An export that finished is not the same as an export that drew every frame.**
            // `StageCompositor` answers a request it cannot serve by refusing it, and
            // AVFoundation carries on: the file is written, the export reports success, and the
            // frames it could not draw are missing from it. Reported here because a damaged
            // file that says nothing is worse than one that says what is wrong with it —
            // somebody who burnt captions in, exported, and found the result broken on playback
            // had `<<<< CustomVideoCompositor >>>> signalled err=-12784` in their console and
            // nothing in the app.
            //
            // The count is per composition: `resetDiagnostics()` runs when one is built.
            let refused = StageCompositor.diagnostics
            guard refused.framesDropped == 0 else {
                return String(localized:
                    "\(destination.lastPathComponent) was written, but \(refused.framesDropped) frame(s) could not be drawn and are missing from it. (\(refused.refusalSummary))")
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



