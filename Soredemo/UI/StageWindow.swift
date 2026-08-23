import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers
// Both halves of the runnable tier, split in Phase 3A-4: `Compositing` for the
// compositor and the exporter, `Capture` for `ObservationWriter`'s log paths. The product
// this app target links is `SoredemoHeadless`, which vends both.
import Capture
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
    /// How loud each recorded source is in the export. Two sources, because the master keeps
    /// system audio and the microphone apart — see `AudioMix`.
    @State private var audioMix = AudioMix.unchanged
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
    /// The captions. Owned here beside `stageStyle` so a change survives the inspector being
    /// closed, and so the preview and the export read the same track.
    @State private var captions = CaptionsModel()
    /// Titles and notes drawn over the picture. Owned here beside `captions` for the same reason.
    @State private var texts = TextOverlaysModel()
    /// Parts of the recording a person has hidden.
    @State private var redactions = RedactionsModel()

    /// What the inspector is showing. See `inspector` for why there are two.
    enum InspectorTab: String, CaseIterable, Hashable {
        case project, selection, captions, text, hide

        var title: String {
            switch self {
            case .project: "Project"
            case .selection: "Zooms"
            case .captions: "Overlays"
            case .text: "Text"
            case .hide: "Hide"
            }
        }

        /// The tab's icon, and its lane's colour when selected — so the Text tab and the Text
        /// track on the timeline are visibly the same thing.
        var icon: String {
            switch self {
            case .project: "slider.horizontal.3"
            case .selection: "plus.magnifyingglass"
            case .captions: "captions.bubble"
            case .text: "textformat"
            case .hide: "eye.slash"
            }
        }

        var tint: Color {
            switch self {
            case .project: Theme.accent
            case .selection: Theme.Lane.zoom
            case .captions: Theme.Lane.caption
            case .text: Theme.Lane.text
            case .hide: Theme.Lane.hide
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
    static func size(for variant: AspectVariant) -> (width: Int, height: Int) {
        variant.dimensions(longestEdge: 1920)
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
                          outputWidth: Self.size(for: variant).width,
                          outputHeight: Self.size(for: variant).height,
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
                        ProgressView()
                    }
                }
                .frame(maxHeight: .infinity)
                .background(Theme.Surface.preview)
                // Handles for whatever the inspector is editing — see `PreviewOverlay`.
                .overlay {
                    let size = Self.size(for: variant)
                    PreviewOverlay(outputWidth: size.width, outputHeight: size.height,
                                   texts: texts, redactions: redactions, tab: inspectorTab,
                                   onChange: { reviewRevision += 1 })
                }
                .overlay {
                    if isCropping {
                        let size = Self.size(for: variant)
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
        // **Full screen, which the green button was not offering.** An `NSWindow` only shows
        // "Enter Full Screen" when its collection behaviour says it can be a full-screen
        // primary; without it the button offers tiling and nothing else, which is the menu you
        // saw. Applied from a view because the scene has no hook for it.
        .background(WindowConfigurator())
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
            await AudioMixBuilder.apply(audioMix, to: item, of: asset)
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
        .task {
            guard !hasSeededCameraStyle else { return }
            hasSeededCameraStyle = true
            cameraStyle = initialCameraStyle
        }
        .task(id: variant) { await load() }
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
        .task(id: reviewRevision) {
            guard reviewRevision > 0, let player else { return }
            await player.seek(to: player.currentTime(),
                              toleranceBefore: .zero, toleranceAfter: .zero)
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
                Menu {
                    Button(savedPackage == nil ? "Save…" : "Save") { saveProject() }
                        .keyboardShortcut("s", modifiers: .command)
                    Button("Save As…") { saveProject(askingForDestination: true) }
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                } label: {
                    Text(hasUnsavedChanges ? "Save\u{2026}" : "Saved")
                } primaryAction: {
                    saveProject()
                }
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
                                      variant: AspectVariant = .landscape) async throws
        -> AVVideoComposition {
        try await configuredComposition(for: AVURLAsset(url: mediaURL),
                                        logForMediaURL: mediaURL, variant: variant)
    }

    static func configuredComposition(for asset: AVAsset,
                                      logForMediaURL mediaURL: URL? = nil,
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
        let size = Self.size(for: variant)
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
                List { FramingReviewSections(model: review, onChange: { reviewRevision += 1 }) }
                    .listStyle(.sidebar)
            case .captions:
                let size = Self.size(for: variant)
                CaptionsPanel(model: captions, mediaURL: mediaURL, edit: timeline.edit,
                              outputWidth: size.width, outputHeight: size.height,
                              onChange: { reviewRevision += 1 })
            case .text:
                TextPanel(model: texts, playhead: timeline.playhead,
                          onChange: { reviewRevision += 1 })
            case .hide:
                RedactionPanel(model: redactions, playhead: timeline.playhead,
                               onChange: { reviewRevision += 1 })
            }
        }
    }

    static let positionRows: [[CameraOverlayStyle.Position]] = [
        [.topLeft, .topCenter, .topRight],
        [.centerLeft, .center, .centerRight],
        [.bottomLeft, .bottomCenter, .bottomRight],
    ]

    /// Whether the style is sitting exactly on a preset. Compared with a tolerance because a
    /// drag writes a continuous position and would otherwise never light a cell again.
    static func matches(_ style: CameraOverlayStyle, _ position: CameraOverlayStyle.Position)
    -> Bool {
        // **Identity, not proximity, now that the preset is stored.** It used to compare
        // coordinates with a tolerance because a preset was baked into numbers and a drag wrote
        // numbers that happened to be near them; `position` says which cell was pressed, so the
        // highlight is exact and a hand-placed camera lights none of them — which is true.
        style.position == position
    }

    /// Where the camera sits. **Shown only when the recording HAS one** — controls for a track
    /// that does not exist are controls a person changes and sees nothing happen.
    @ViewBuilder private var cameraControls: some View {
        // **Nine places, as a grid of the frame.** Two sliders can express any position and are
        // the wrong instrument for the position people actually want: almost every camera goes
        // in a corner, and finding a corner by aiming two sliders is a job. an Electron recorder and
        // an Electron recorder both ship the same nine presets beside the free position.
        //
        // A 3×3 grid rather than a menu, because the control's SHAPE is the frame — pressing the
        // bottom-right cell is pointing at where the camera will be.
        Toggle("Show camera", isOn: Binding(
            get: { !cameraStyle.isHidden },
            set: { cameraStyle = cameraStyle.changing(isHidden: !$0); reviewRevision += 1 }))
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            ForEach(Self.positionRows, id: \.first) { row in
                GridRow {
                    ForEach(row, id: \.self) { position in
                        CameraPositionCell(
                            position: position,
                            isChosen: Self.matches(cameraStyle, position),
                            choose: {
                                cameraStyle = cameraStyle.placed(at: position)
                                reviewRevision += 1
                            })
                    }
                }
            }
        }
        Picker("Shape", selection: Binding(
            get: { cameraStyle.shape },
            set: { cameraStyle = cameraStyle.changing(shape: $0); reviewRevision += 1 })) {
            ForEach(CameraOverlayStyle.Shape.allCases, id: \.self) {
                Text($0.displayName).tag($0)
            }
        }
        Slider(value: Binding(get: { cameraStyle.widthFraction },
                              set: { cameraStyle = cameraStyle.changing(widthFraction: $0) }),
               in: 0.05...0.5,
               onEditingChanged: { if !$0 { reviewRevision += 1 } }) { Text("Size") }
        // **How much the camera shrinks while the stage is zoomed in.** A zoom makes the picture
        // bigger, and a camera that holds its width is covering a larger share of a smaller area
        // — which is exactly when it is most in the way. a Rust recorder models this as `scale_during_zoom`;
        // 1 holds the size, which is what this did before the control existed.
        Slider(value: Binding(get: { cameraStyle.scaleDuringZoom },
                              set: { cameraStyle = cameraStyle.changing(scaleDuringZoom: $0) }),
               in: 0.3...1,
               onEditingChanged: { if !$0 { reviewRevision += 1 } }) { Text("Shrink on zoom") }
        Slider(value: Binding(get: { cameraStyle.x },
                              set: { cameraStyle = cameraStyle.changing(x: $0) }),
               in: 0...1,
               onEditingChanged: { if !$0 { reviewRevision += 1 } }) { Text("Across") }
        Slider(value: Binding(get: { cameraStyle.y },
                              set: { cameraStyle = cameraStyle.changing(y: $0) }),
               in: 0...1,
               onEditingChanged: { if !$0 { reviewRevision += 1 } }) { Text("Up from the bottom") }
        Toggle("Mirror", isOn: Binding(
            get: { cameraStyle.isMirrored },
            set: { cameraStyle = cameraStyle.changing(isMirrored: $0); reviewRevision += 1 }))
    }

    @ViewBuilder private var outputControls: some View {
        Picker("Shape", selection: $variant) {
            ForEach(AspectVariant.all, id: \.self) { shape in
                Text(shape.name).tag(shape)
            }
        }
        let size = Self.size(for: variant)
        LabeledContent("Size", value: "\(size.width)\u{00D7}\(size.height)")
            .font(Type.detail).foregroundStyle(.secondary)

        // **How many bits the picture gets.** Nothing was choosing before, so AVFoundation did —
        // at a rate tuned for camera footage, which is the wrong content. See `ExportQuality`.
        Picker("Quality", selection: Binding(
            get: { quality }, set: { quality = $0 })) {
            ForEach(ExportQuality.choices, id: \.self) { choice in
                Text(LocalizedStringKey(choice.displayName)).tag(choice)
            }
        }
        // **The estimate is why the picker is usable.** a Rust recorder shows one and calibrated it to
        // within 3% against real recordings; a quality control with no consequence attached is
        // three words to guess between.
        LabeledContent("About", value: Self.fileSize(quality.estimatedBytes(
            outputWidth: size.width, outputHeight: size.height,
            frameRate: 60,
            seconds: Double(timeline.edit.outputDuration.rawValue) / 1_000_000_000)))
            .font(Type.detail).foregroundStyle(.secondary)
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

        let size = Self.size(for: variant)
        let gif = gifSettings.size(fitting: size.width, height: size.height)
        // The size is worth stating because it is not the export size beside it, and the
        // "no sound" is worth stating because a person who recorded themselves talking would
        // otherwise find that out from the file.
        LabeledContent("GIF", value: "\(gif.width)\u{00D7}\(gif.height), no sound")
            .font(Type.detail).foregroundStyle(.secondary)
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
        if audioMix.changesAnything {
            Button("Reset audio") { audioMix = .unchanged }
                .buttonStyle(.link).font(.caption)
        }
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
            cursorStyleData: try? EditState.encoding(stageStyle.cursor),
            cameraStyleData: cameraURL == nil
                ? nil : try? EditState.encoding(cameraStyle),
            cropData: crop.isWhole ? nil : try? EditState.encoding(crop))
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
        if let name = edit.outputShapeName,
           let shape = AspectVariant.all.first(where: { $0.name == name }) {
            variant = shape
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
        savedEdit = edit
        if !failures.isEmpty {
            projectStatus = "Opened, but could not read \(failures.joined(separator: ", "))."
        }
    }

    private func load() async {
        do {
            // Before the composition: `configuredComposition` reads
            // `StageCompositor.framingOverrides`, which `FramingReviewModel.load` publishes.
            review.load(observationLogAt: ObservationWriter.expectedLogURL(forMediaURL: mediaURL)
                .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
            // The lane draws the same blocks the camera integrates, derived from the same
            // plan — a second derivation would be a second answer.
            // The anchor first: the lane converts every block's absolute instant through it, and
            // blocks set before it would be drawn off the edge for one frame.
            // The crop before the composition: `StagePlanner` fits the card to the CROPPED
            // aspect, so a composition built while the static still said "whole" would size the
            // card for a recording that is no longer what is being drawn.
            StageCompositor.crop = crop
            timeline.setZoomAnchor(review.anchor)
            timeline.setDerivedZooms(ZoomBlock.blocks(
                for: review.plan.framedClicks(with: review.overrides,
                                              pointerFallbackRevision: review.fallbackRevision)))
            let recording = AVURLAsset(url: mediaURL)
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
            let cut = try await EditedAsset.make(from: recording, by: timeline.edit)
            // The camera laid alongside the cut recording, so one composition sees both. Returns
            // the cut asset untouched when there is no camera, so the common path costs nothing.
            let combined = try await CameraComposition.combine(
                screen: cut, cameraURL: cameraURL,
                cameraStartOffset: CMTime(value: cameraStartOffsetNanos, timescale: 1_000_000_000))
            StageCompositor.cameraTrackID = combined.cameraTrackID
            StageCompositor.cameraStyle = combined.cameraTrackID == nil ? nil : cameraStyle
            let asset = combined.asset
            let composition = try await Self.configuredComposition(
                for: asset, logForMediaURL: mediaURL, variant: variant)
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
        panel.allowedContentTypes = [.mpeg4Movie, .gif]
        panel.nameFieldStringValue = mediaURL.deletingPathExtension().lastPathComponent + ".mp4"
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
        let edit = timeline.edit
        let mix = audioMix
        let chosen = quality
        let gif = gifSettings
        let size = Self.size(for: variant)
        let isGIF = destination.pathExtension.lowercased() == "gif"
        let queued = ExportQueue.shared.enqueue(destination: destination) { report in
            guard let asset else { return "There is nothing loaded to export." }
            StageCompositor.apply(settings)
            return await Self.runExport(asset: asset, to: destination, isGIF: isGIF,
                                        size: size, edit: edit, audioMix: mix,
                                        quality: chosen, gifSettings: gif, report: report)
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
                          audioMix: AudioMix, quality: ExportQuality, gifSettings: GIFSettings,
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
                    quality: quality,
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



/// One cell of the camera's position grid.
///
/// **The control is a picture of the frame.** A dot in the corner of a small rectangle says
/// where the camera goes without a word, and stays true in a language this app has not been
/// translated into.
private struct CameraPositionCell: View {
    let position: CameraOverlayStyle.Position
    let isChosen: Bool
    let choose: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: choose) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(isChosen ? Theme.accent.opacity(0.28)
                               : Theme.Fill.rest.opacity(isHovering ? 1 : 0.6))
                .overlay {
                    Circle()
                        .fill(isChosen ? Theme.accent : Theme.Ink.tertiary)
                        .frame(width: 5, height: 5)
                }
                .frame(width: 22, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(LocalizedStringKey(position.displayName))
    }
}
