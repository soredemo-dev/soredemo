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
    @State private var player: AVPlayer?
    /// The asset the current item was built from. Held because `AVAudioMix` addresses that
    /// asset's tracks, and after a cut the item's asset is a composition rather than the file.
    @State private var playingAsset: AVAsset?
    /// The video track's thumbnails. Owned here so a cache is not discarded on every edit.
    @State private var filmstrip = Filmstrip()
    @State private var failure: String?
    // MARK: - export-basic
    @State private var isExporting = false
    @State private var exportStatus: String?
    /// Where the running export has got to, or `nil` when none is. Its PHASE matters as much
    /// as its fraction — see `ExportProgress`.
    @State private var exportProgress: ExportProgress?
    /// The running export, so Cancel has something to cancel. Swift's cooperative cancellation
    /// is the whole mechanism; the exporter checks it and deletes its partial file.
    @State private var exportTask: Task<Void, Never>?
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
        .task(id: variant) { await load() }
        // Rebuilding on a COMMITTED edit, not on every drag event: `load()` builds an
        // `AVVideoComposition` over a freshly cut asset, and doing that per pixel of a
        // selection drag would make the strip unusable.
        .task(id: editRevision) { if editRevision > 0 { await load() } }
        // **The playhead has to move the player, or it is decoration.** It is dragged in
        // SOURCE time and the player counts in OUTPUT time, so the seek goes through the
        // edit; a position inside a cut has no output time and the player stays where it is
        // rather than jumping to zero.
        .task(id: timeline.playhead) {
            guard let player,
                  let output = timeline.edit.outputTime(atSource: timeline.playhead)
            else { return }
            await player.seek(to: CMTime(value: output.rawValue, timescale: 1_000_000_000),
                              toleranceBefore: .zero, toleranceAfter: .zero)
        }
        // `reviewRevision` and not `review.overrides`: the composition is rebuilt when a
        // decision changes, and a counter says exactly that. Observing the array would also
        // fire on a load that merely restored the same decisions.
        .task(id: reviewRevision) { if reviewRevision > 0 { await load() } }
        .inspector(isPresented: $isReviewShown) {
            inspector
                .inspectorColumnWidth(min: InspectorWidth.minimum,
                                      ideal: InspectorWidth.ideal,
                                      max: InspectorWidth.maximum)
        }
        .toolbar {
            // A plain toolbar `Button`, not a `.commands { CommandGroup }` menu item: `.commands`
            // can only attach to a `Scene`, never to a plain `View`.
            ToolbarItem {
                // The title says whether there is anything to save, which is the whole
                // content of a dirty indicator and cheaper than a dot nobody explains.
                Button(hasUnsavedChanges ? "Save…" : "Saved") { saveProject() }
                    .disabled(player == nil || !hasUnsavedChanges)
                    .keyboardShortcut("s", modifiers: .command)
            }
            ToolbarItem {
                if isExporting {
                    HStack(spacing: 8) {
                        // A determinate bar while writing, an indeterminate one while
                        // finishing: `finishWriting` reports nothing, and a bar pinned at 100%
                        // reads as stopped.
                        if let fraction = exportProgress?.fraction {
                            ProgressView(value: fraction).frame(width: 90)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        Text(exportPhaseLabel).font(.caption).foregroundStyle(.secondary)
                        Button("Cancel") { exportTask?.cancel() }
                    }
                } else {
                    Button("Export…") { startExport() }
                        .disabled(player == nil)
                }
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
    @ViewBuilder private var inspector: some View {
        VStack(spacing: 0) {
            Picker("", selection: $inspectorTab) {
                ForEach(InspectorTab.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Space.regular)
            .padding(.vertical, Space.snug)

            Divider()

            switch inspectorTab {
            case .project:
                List {
                    Section("Output") { outputControls }
                    Section("Look") {
                        StageStylePicker(model: stageStyle, onChange: { reviewRevision += 1 })
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

    @ViewBuilder private var outputControls: some View {
        Picker("Shape", selection: $variant) {
            ForEach(AspectVariant.all, id: \.self) { shape in
                Text(shape.name).tag(shape)
            }
        }
        let size = Self.size(for: variant)
        LabeledContent("Size", value: "\(size.width)\u{00D7}\(size.height)")
            .font(Type.detail).foregroundStyle(.secondary)
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
                ? nil : try? EditState.encoding(redactions.track))
    }

    /// True when what is on screen differs from what is on disk. A scratch recording is always
    /// unsaved, because nothing has been written yet — not because it has been edited.
    private var hasUnsavedChanges: Bool {
        savedPackage == nil || currentEditState() != savedEdit
    }

    private func saveProject() {
        let edit = currentEditState()
        let destination = savedPackage ?? ProjectStore.chooseSaveDestination(
            defaultName: mediaURL.deletingPathExtension().lastPathComponent)
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
            let asset = try await EditedAsset.make(from: recording, by: timeline.edit)
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

    /// What the toolbar says the export is doing. Named phases rather than a percentage alone,
    /// because "Finishing" is the honest answer for a step that takes seconds and reports
    /// nothing.
    private var exportPhaseLabel: String {
        switch exportProgress {
        case .writing(let fraction, _): "\(Int(fraction * 100))%"
        case .finishing: "Finishing…"
        case .preparing, nil: "Preparing…"
        }
    }

    /// Starts an export and keeps the task, so Cancel can reach it. The panel is presented
    /// before the task begins — a cancel button for a job a person has not chosen a
    /// destination for would be a button for nothing.
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

        isExporting = true
        exportProgress = .preparing
        exportTask = Task {
            if destination.pathExtension.lowercased() == "gif" {
                await exportGIF(to: destination)
            } else {
                await exportRecording(to: destination)
            }
            isExporting = false
            exportProgress = nil
            exportTask = nil
        }
    }

    /// Presents a save panel, then runs `MP4Exporter.export`. `StageCompositor`'s statics are
    /// already set by `load()` (the toolbar button is disabled while `player == nil`), so the
    /// export composes the identical framing and pointer the preview showed.
    private func exportRecording(to destination: URL) async {
        do {
            let asset = AVURLAsset(url: mediaURL)
            let size = Self.size(for: variant)
            let report = try await MP4Exporter.export(
                asset: asset, to: destination,
                outputWidth: size.width, outputHeight: size.height,
                edit: timeline.edit, audioMix: audioMix,
                // Hops to the main actor because the export reports from its own context, and
                // `exportProgress` is view state.
                onProgress: { progress in
                    Task { @MainActor in exportProgress = progress }
                })
            exportStatus = "Exported \(report.framesWritten) frame(s) at "
                + "\(size.width)\u{00D7}\(size.height) to "
                + "\(report.outputURL.lastPathComponent)."
        } catch is CancellationError {
            // Nothing to report: a person who cancelled knows they cancelled, and an alert
            // telling them so is a second thing to dismiss. The partial file is already gone.
        } catch {
            exportStatus = "Export failed: \(error)"
        }
    }

    /// The same composition, written as a GIF. Sized from `gifSettings` rather than from the
    /// variant, because a GIF that is 1920 wide is a file nobody can attach to anything.
    private func exportGIF(to destination: URL) async {
        do {
            let asset = AVURLAsset(url: mediaURL)
            let size = Self.size(for: variant)
            let report = try await GIFExporter.export(
                asset: asset, to: destination,
                outputWidth: size.width, outputHeight: size.height,
                edit: timeline.edit, settings: gifSettings,
                onProgress: { progress in
                    Task { @MainActor in exportProgress = progress }
                })
            // The RATE is reported, not the setting, and they can differ — see `GIFSettings`.
            // A person who picked an off-list rate should learn it here rather than by timing
            // the file against the recording.
            exportStatus = "Exported \(report.framesWritten) frame(s) at "
                + "\(report.width)\u{00D7}\(report.height), "
                + "\(formatted(report.playbackRate)) fps, to \(report.outputURL.lastPathComponent)."
        } catch is CancellationError {
        } catch {
            exportStatus = "GIF export failed: \(error)"
        }
    }

    /// Whole numbers without a trailing `.0`, which is what every rate on `exactRates` is.
    private func formatted(_ rate: Double) -> String {
        rate == rate.rounded() ? String(Int(rate)) : String(format: "%.1f", rate)
    }
}


