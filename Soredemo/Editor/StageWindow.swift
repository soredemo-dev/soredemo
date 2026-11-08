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
    /// The asset being watched and how it was built — see `EditorPreview`.
    @State private var preview = EditorPreview()
    /// This recording's files, as the preview reads them.
    private var files: EditorPreview.Files {
        EditorPreview.Files(mediaURL: mediaURL, cameraURL: cameraURL,
                            cameraStartOffsetNanos: cameraStartOffsetNanos)
    }
    /// When the recording's file was made — for its name, read off the file (see `RecordingName`).
    @State private var recordedAt: Date?
    /// What this recording is called wherever a person sees a name. Never `master-00`.
    private var recordingName: String {
        RecordingName.display(for: mediaURL, savedPackage: editor.savedPackage, recordedAt: recordedAt)
    }
    /// One-shot, because `initialCameraStyle` seeds `cameraStyle` and a saved project's own
    /// value must win over it — the load runs after this and would otherwise be overwritten.
    @State private var hasSeededCameraStyle = false
    @State private var isCropping = false
    /// Whether the safe-frame guides are drawn. **Off by default and not saved**: it is a thing
    /// to look at while deciding where something sits, not a property of the recording, and a
    /// guide left on from last week is furniture rather than information.
    @State private var showsSafeFrame = false
    // MARK: - export-basic
    @State private var exportStatus: String?
    // MARK: - review-ui
    // MARK: - project
    // MARK: - basic-edit
    /// Bumped when an edit is committed, to rebuild the composition against the cut asset.
    @State private var editRevision = 0
    @State private var isReviewShown = true
    @State private var inspectorTab = InspectorTab.project
    /// The export's settings, shown by the Export button before the save panel.
    @State private var isExportSheetShown = false
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
        case project, selection, cuts, agent, captions, chapters, text, hide, mark

        var title: String {
            switch self {
            // "Look": the tab holds what changes the picture; the file's settings moved to the
            // export sheet (2026-10-25).
            case .project: "Look"
            case .selection: "Zooms"
            case .cuts: "Cuts"
            case .agent: "Agent"
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
            case .cuts: "scissors"
            case .agent: "sparkles"
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
            case .cuts: Theme.accent
            case .agent: Theme.accent
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
            .onDisappear {
                preview.player?.pause()
                // The agent's session ends with the window: its process, socket and directory.
                editor.agent.close()
            }
            .onChange(of: undoManager) { editor.captions.undoRecorder = undoManager }
            // **The caption editor REPLACES the stage rather than floating over it.** A sheet
            // would have kept the timeline and the inspector behind it, which is exactly the
            // arrangement this mode exists to get out of the way — and there is one `AVPlayer`,
            // so two pictures of it on screen at once would be two views fighting over one
            // position. Swapping means the transport a person was using is the transport they
            // keep.
            .opacity(isCaptionEditorShown ? 0 : 1)
            .overlay {
                if isCaptionEditorShown, let player = preview.player {
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
                    if let player = preview.player {
                        PreviewView(player: player)
                    } else if let failure = preview.failure {
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
                // The panel's agent, seen where the person is looking: who is editing, what it is
                // doing now, and a sweep of light as each cut lands.
                .overlay { AgentPresence(model: editor.agent) }
                // **The picture's area is dark in both themes**, backdrop and everything drawn
                // over it: its ground is black whatever the window is, so a handle or a label in
                // the light theme's dark lane colours would vanish into it.
                .environment(\.colorScheme, .dark)
                if let player = preview.player {
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
                                   filmstrip: preview.filmstrip,
                                   texts: editor.texts.track, captions: editor.captions.track,
                                   redactions: editor.redactions.track, chapters: editor.chapters.track,
                                   steps: editor.steps.marks)
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
                .disabled(preview.player == nil)
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
        .task(id: editor.audioMix) { await preview.applyMix(files, editor: editor) }
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
        .task(id: editor.noiseReduction) { if editor.noiseReduction != nil || preview.hasCleanedMicrophone { await load() } }
        // **The file, not the whole bed.** Changing the piece means a different track in the
        // composition and a rebuild; changing its level or its ducking is a volume automation,
        // which the sibling below re-applies without touching the asset.
        .task(id: editor.music.filename) { if editor.music.filename != nil || preview.musicTrackID != nil { await load() } }
        .task(id: editor.music) { await preview.applyMix(files, editor: editor) }
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
            guard let player = preview.player,
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
            guard reviewRevision > 0, let player = preview.player else { return }
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
            editor.refreshDerivedZooms()
        }
        // The lane's curve is baked at the same pace as the picture — see `ZoomCurve`.
        .task(id: editor.cameraPace) {
            StageCompositor.cameraPace = editor.cameraPace
            editor.timeline.cameraPace = editor.cameraPace
        }
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
            // of to spare. A rail costs 56 points of width once and nothing per section.
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
                    // **A copy, not a move**: this project keeps its home and its evidence.
                    Button("Save a Copy for Sharing…") { saveCopyForSharing() }
                        .help("A copy without the window names and button labels the recording noted under each click. It still zooms and draws its cursor.")
                } label: {
                    editor.savedPackage == nil ? Text("Save\u{2026}") : Text("Save")
                } primaryAction: {
                    saveProject()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(preview.player == nil)
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
                    // A picture and a sentence per step, from what the log says was pressed —
                    // see `GuideExport`. Offered only when there are steps to write.
                    Button("Export Guide…") { exportGuide() }
                        .disabled(editor.steps.steps.isEmpty)
                    // The same steps as one page a viewer clicks through.
                    Button("Export Walkthrough…") { exportGuide(asWalkthrough: true) }
                        .disabled(editor.steps.steps.isEmpty)
                } label: {
                    Text("Export…")
                } primaryAction: {
                    isExportSheetShown = true
                }
                .disabled(preview.player == nil)
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
        .sheet(isPresented: $isExportSheetShown) {
            ExportSheet(editor: editor, onExportFinalCutXML: { exportFinalCutXML() },
                        onExport: { startExport() })
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
    /// The inspector's section rail — a column of named icons on the panel's edge.
    ///
    /// **A rail, not a row of tabs across the top.** The reason shows as soon as there are more
    /// than three sections: a horizontal strip competes with the panel's own width, which is the
    /// dimension a
    /// 300-point inspector has none of to spare. A rail costs 56 points once and nothing per
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
        .frame(width: 56)
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
                    // **The picture first.** The file's settings stood above it until 2026-10-25
                    // and now open from the Export button (`ExportSheet`).
                    Section {
                        StageStylePicker(model: editor.stageStyle, onChange: { reviewRevision += 1 },
                                         packageURL: ProjectStore.packageURL(forMediaAt: mediaURL))
                    }
                    if cameraURL != nil {
                        Section("Camera") {
                            CameraOverlayControls(editor: editor, onChange: { reviewRevision += 1 })
                        }
                    }
                    Section("Cursor") {
                        StageStylePicker(model: editor.stageStyle,
                                         onChange: { reviewRevision += 1 }).cursorControls
                    }
                    Section("Audio") { AudioControls(editor: editor, preview: preview, files: files) }
                }
                .inspectorList()
            case .selection:
                List {
                    Section("Zoom amount") {
                        ZoomAmountControls(editor: editor, onChange: { reviewRevision += 1 })
                    }
                    AtPlayhead(model: editor.timeline) { playhead in
                        FramingReviewSections(model: editor.review, onChange: { reviewRevision += 1 },
                                              playhead: playhead)
                    }
                }
                .inspectorList()
            case .cuts:
                // What was heard arrives after the recording opens — the waveform a moment
                // later, the transcript whenever someone transcribes — so the proposals are
                // re-derived when either changes rather than once on open.
                CutProposalsPanel(model: editor.cuts, timeline: editor.timeline,
                                  onChange: { editRevision += 1 })
                    .task(id: HeardKey(segments: editor.captions.transcript?.segments.count,
                                       peaks: editor.timeline.waveform?.peaks.count)) {
                        let timeline = editor.timeline
                        editor.cuts.hear(
                            transcript: editor.captions.transcript,
                            sounding: timeline.waveform.flatMap { waveform in
                                timeline.duration.flatMap {
                                    SilenceFinder.sounding(peaks: waveform.peaks,
                                                           sliceSeconds: waveform.sliceDuration,
                                                           settings: timeline.silenceSettings,
                                                           duration: $0)
                                }
                            })
                    }
            case .agent:
                AgentPanel(model: editor.agent, editor: editor)
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
            let source = await FinalCutXMLExport.source(for: media, frameRate: rate).source
            // The camera's own shape, read from its own file: a webcam is almost never the
            // screen's aspect, and describing it by the screen's would letterbox it.
            var cameraSource: FinalCutXML.Source?
            if let cameraMedia {
                let camera = await FinalCutXMLExport.source(for: cameraMedia, frameRate: rate)
                cameraSource = camera.hasVideo ? camera.source : nil
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
                exportStatus = FinalCutXMLExport.message(for: refusal)
            }
        }
    }

    /// A byte count as a person reads it. `ByteCountFormatStyle` rather than a hand-rolled
    /// divide: it is localised, and 1,2 GB in a comma-decimal locale is not something to
    /// reimplement.
    static func fileSize(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .file))
    }

    // MARK: - saving and opening


    /// True when what is on screen differs from what is on disk. A scratch recording is always
    /// unsaved, because nothing has been written yet — not because it has been edited.
    private var hasUnsavedChanges: Bool {
        editor.savedPackage == nil || editor.currentEditState(hasCamera: cameraURL != nil) != editor.savedEdit
    }

    /// *Save a Copy for Sharing*: always asks where, never becomes this project's home, and the
    /// copy's evidence loses the words on the screen (audit R5).
    private func saveCopyForSharing() {
        let edit = editor.currentEditState(hasCamera: cameraURL != nil)
        let name = editor.savedPackage?.deletingPathExtension().lastPathComponent ?? recordingName
        guard let destination = ProjectStore.chooseSaveDestination(
            defaultName: String(localized: "\(name) (shared)"))
        else { return }
        do {
            try ProjectStore.save(recordingAt: mediaURL, edit: edit, to: destination,
                                  withoutScreenText: true)
            editor.projectStatus = String(localized: "Saved a copy without screen text to \(destination.lastPathComponent).")
        } catch {
            editor.projectStatus = String(localized: "Could not save the copy: \(String(describing: error))")
        }
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


    private func load() async {
        await preview.load(files, into: editor, pendingEdit: pendingEdit, scrubAudio: scrubAudioIsOn)
    }

    /// Presents the save panel and queues what it chose. The panel comes first because a job
    /// with no destination is not a job — and because the panel's own format popup is where
    /// macOS puts the format chooser.
    /// The frame under the playhead as a PNG, at the export's size and through the export's own
    /// composition. See `docs/design/2026-09-27-one-frame-as-a-picture.md`.
    private func exportFrame() {
        guard let asset = preview.playingAsset,
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

    /// The take as a step-by-step guide, into a folder a person names — or, as a walkthrough, one
    /// page a viewer clicks through. See `GuideExport`.
    private func exportGuide(asWalkthrough: Bool = false) {
        guard let asset = preview.playingAsset else { return }
        let size = editor.outputSize
        let pictures = GuideExport.pictures(
            for: editor.steps.steps, anchor: editor.steps.anchor, edit: editor.timeline.edit,
            highlight: GuideExport.highlighter(outputWidth: size.width, outputHeight: size.height,
                                               sourceWidth: editor.recordingSize.width,
                                               sourceHeight: editor.recordingSize.height))
        guard !pictures.isEmpty else {
            exportStatus = String(localized: "No step of this recording is left in the video, so there is no guide to write.")
            return
        }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        if asWalkthrough {
            panel.allowedContentTypes = [.html]
            panel.nameFieldStringValue = recordingName + ".html"
        } else {
            panel.nameFieldStringValue = String(localized: "\(recordingName) Guide")
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            do {
                if asWalkthrough {
                    try await GuideExport.writeWalkthrough(pictures, title: recordingName, asset: asset,
                                                           outputWidth: size.width, outputHeight: size.height,
                                                           to: destination)
                    exportStatus = String(localized: "Saved the walkthrough to \(destination.lastPathComponent).")
                } else {
                    try await GuideExport.write(pictures, title: recordingName, asset: asset,
                                                outputWidth: size.width, outputHeight: size.height, to: destination)
                    exportStatus = String(localized: "Saved the guide to \(destination.lastPathComponent).")
                }
            } catch {
                exportStatus = asWalkthrough
                    ? String(localized: "Could not save the walkthrough: \(String(describing: error))")
                    : String(localized: "Could not save the guide: \(String(describing: error))")
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
        let asset = preview.playingAsset
        // **The range is applied here, at the export, and nowhere else.** `timeline.edit` is
        // still what the preview plays: a marked section is a choice about one export, not an
        // edit to the project, and hiding the rest of the recording the moment somebody marks a
        // section would make it impossible to check the section against what surrounds it.
        let edit = editor.timeline.editForExport
        let mix = editor.audioMix
        // Captured with the rest of the job, for `runExport`'s reason: a queued export runs
        // later than the view that asked for it, and reading this then would read whatever had
        // been measured since.
        let loudness = preview.measuredLoudness
        let bedTrack = preview.musicTrackID
        let bedRamps = preview.musicRamps(editor: editor)
        let chosen = editor.quality
        let chosenCodec = editor.codec
        let frames = editor.frameRate.frames(recording: editor.recordingFrameRate)
        let gif = editor.gifSettings
        // Through the EXPORT's edit, so a marked section carries only the chapters inside it.
        let placedChapters = editor.exportChapters(through: edit)
        let size = editor.outputSize
        let isGIF = destination.pathExtension.lowercased() == "gif"
        // What the job renders, so a finished one teaches this Mac's rate (`ExportSpeedMemory`).
        // Not for a GIF: it scales to its own edge, so `size` is not what it draws.
        let seconds = Double((edit.outputDuration.rawValue)) / 1_000_000_000
        let measure = isGIF ? nil : (frames: Int((seconds * Double(frames)).rounded()),
                                     width: size.width, height: size.height, codec: chosenCodec.rawValue)
        let queued = ExportQueue.shared.enqueue(destination: destination, measure: measure) { report in
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


}

/// What the cut proposals were last derived from hearing: how many transcript segments, how many
/// waveform slices. A change in either re-derives them.
private struct HeardKey: Hashable {
    let segments: Int?
    let peaks: Int?
}
