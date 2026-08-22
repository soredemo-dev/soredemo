import AppKit
import AVFoundation
import Foundation
// Both halves of the runnable tier, split in Phase 3A-4: `Compositing` for the
// compositor and the exporter, `Capture` for `ObservationWriter`'s log paths. The product
// this app target links is `SoredemoHeadless`, which vends both.
import Capture
import Compositing
import Framing
import Project
import Timeline
import Variants
import SwiftUI

/// A window hosting a preview and an Export button. Standard SwiftUI with no hand-rolled glass:
/// standard components get Liquid Glass automatically and respond to the system-level Liquid
/// Glass slider, which a custom surface does not.
struct StageWindow: View {
    @State private var player: AVPlayer?
    @State private var failure: String?
    // MARK: - export-basic
    @State private var isExporting = false
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
    // MARK: - basic-edit
    /// What survives editing. **Replaced a pair of trim sliders**, which could express one
    /// kept span and nothing else: no cut in the middle, no seeing where a cut was made, no
    /// undo. Owned here so it survives the inspector being closed.
    @State private var timeline = TimelineEditorModel()
    /// Bumped when an edit is committed, to rebuild the composition against the cut asset.
    @State private var editRevision = 0
    @State private var isReviewShown = true
    /// Bumped whenever an override changes, to rebuild the composition. **The preview has to
    /// move**: the completion rule says a row is not done while the behaviour its name claims
    /// is not observable in the product, and an override that only changed a list would not
    /// be a review surface — it would be a form.
    @State private var reviewRevision = 0
    let mediaURL: URL

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
        NavigationSplitView {
            List { Text(mediaURL.lastPathComponent) }
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            Group {
                if let player {
                    PreviewView(player: player)
                } else if let failure {
                    ContentUnavailableView("Could not build the preview", systemImage: "exclamationmark.triangle",
                                           description: Text(failure))
                } else {
                    ProgressView()
                }
            }
        }
        .task(id: mediaURL) { await load() }
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
            List {
                Section("Output") {
                    Picker("Shape", selection: $variant) {
                        ForEach(AspectVariant.all, id: \.self) { shape in
                            Text(shape.name).tag(shape)
                        }
                    }
                    let size = Self.size(for: variant)
                    LabeledContent("Size", value: "\(size.width)\u{00D7}\(size.height)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Edit") {
                    TimelineEditor(model: timeline, onChange: { editRevision += 1 })
                }
                Section("Audio") { audioControls }
                Section("Look") {
                    StageStylePicker(model: stageStyle, onChange: { reviewRevision += 1 })
                }
                FramingReviewSections(model: review, onChange: { reviewRevision += 1 })
            }
            .listStyle(.sidebar)
            .inspectorColumnWidth(min: 260, ideal: 320, max: 420)
        }
        .toolbar {
            // A plain toolbar `Button`, not a `.commands { CommandGroup }` menu item: `.commands`
            // can only attach to a `Scene`, never to a plain `View`.
            ToolbarItem {
                Button("Export…") { Task { await exportRecording() } }
                    .disabled(player == nil || isExporting)
            }
            ToolbarItem {
                Button {
                    isReviewShown.toggle()
                } label: {
                    Label("Review", systemImage: "sidebar.right")
                }
            }
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
            player = AVPlayer(playerItem: item)
        } catch {
            failure = "\(error)"
        }
    }

    /// Presents a save panel, then runs `MP4Exporter.export`. `StageCompositor`'s statics are
    /// already set by `load()` (the toolbar button is disabled while `player == nil`), so the
    /// export composes the identical framing and pointer the preview showed.
    private func exportRecording() async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = mediaURL.deletingPathExtension().lastPathComponent + ".mp4"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isExporting = true
        defer { isExporting = false }
        do {
            let asset = AVURLAsset(url: mediaURL)
            let size = Self.size(for: variant)
            let report = try await MP4Exporter.export(
                asset: asset, to: destination,
                outputWidth: size.width, outputHeight: size.height,
                edit: timeline.edit, audioMix: audioMix)
            exportStatus = "Exported \(report.framesWritten) frame(s) at "
                + "\(size.width)\u{00D7}\(size.height) to "
                + "\(report.outputURL.lastPathComponent)."
        } catch {
            exportStatus = "Export failed: \(error)"
        }
    }
}


