import AppKit
import AVFoundation
import Foundation
// Both halves of the runnable tier, split in Phase 3A-4: `Compositing` for the
// compositor and the exporter, `Capture` for `ObservationWriter`'s log paths. The product
// this app target links is `SoredemoHeadless`, which vends both.
import Capture
import Compositing
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
    // MARK: - trim
    /// The recording's full length, read once the asset loads. `nil` until then, which is why
    /// the trim controls are absent rather than showing a range of 0…0.
    @State private var duration: Double?
    /// The span to keep, in seconds from the start of the recording. `trimEnd == nil` means
    /// "to the end" — distinct from "to the current duration", which would silently stop
    /// following the recording if it were ever re-read.
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double?
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
        // Rebuilding on a committed trim change, not on every intermediate slider value:
        // `load()` builds an `AVVideoComposition`, and doing that per pixel of slider travel
        // would make the control unusable.
        .task(id: trimStart) { if duration != nil { await load() } }
        .task(id: trimEnd) { if duration != nil { await load() } }
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
                if let duration, duration > 0 {
                    Section("Trim") { trimControls(duration: duration) }
                }
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
    static func configuredComposition(for mediaURL: URL,
                                      variant: AspectVariant = .landscape) async throws
        -> AVVideoComposition {
        StageCompositor.renderer = try CoreImageFrameRenderer()
        // A fresh recording gets a fresh drop count; a stale one must not read as this file's.
        StageCompositor.resetDiagnostics()
        // `expectedLogURL(forMediaURL:)` names where a log for this media would be; it does not
        // claim one exists. The filesystem check decides between "no log" and "a log", which
        // `PointerReading`'s cases keep distinguishable — `nil` means draw no pointer.
        let candidateLogURL = ObservationWriter.expectedLogURL(forMediaURL: mediaURL)
        StageCompositor.observationLogURL = candidateLogURL.flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
        }
        let asset = AVURLAsset(url: mediaURL)
        let size = Self.size(for: variant)
        return try await CompositionBuilder.composition(
            for: asset, outputWidth: size.width, outputHeight: size.height,
            frameDuration: CMTime(value: 1, timescale: 60))
    }

    /// The span to export, or `nil` for all of it. Built here rather than stored so the two
    /// sliders cannot drift out of order: a start past the end is clamped into a valid range
    /// at the one place a range is made.
    private func trimRange() -> CMTimeRange? {
        guard let duration, duration > 0 else { return nil }
        let start = min(max(trimStart, 0), duration)
        let end = min(trimEnd ?? duration, duration)
        guard end > start, start > 0 || end < duration else { return nil }
        return CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                           duration: CMTime(seconds: end - start, preferredTimescale: 600))
    }

    @ViewBuilder private func trimControls(duration: Double) -> some View {
        LabeledContent("Keep", value: Self.timeSpan(from: trimStart,
                                                    to: trimEnd ?? duration))
            .font(.caption).monospacedDigit()
        TrimSlider(title: "Start", value: trimStart, range: 0...duration) { settled in
            trimStart = min(settled, (trimEnd ?? duration) - 0.1)
        }
        TrimSlider(title: "End", value: trimEnd ?? duration, range: 0...duration) { settled in
            // Snapping the far end back to `nil` keeps "to the end" expressible: a stored
            // number equal to the current duration would silently become a real cut if the
            // recording were ever re-read at a different length.
            trimEnd = settled >= duration - 0.05 ? nil : max(settled, trimStart + 0.1)
        }
        if trimStart > 0 || trimEnd != nil {
            Button("Use the whole recording") {
                trimStart = 0
                trimEnd = nil
            }
            .buttonStyle(.link).font(.caption)
        }
    }

    static func timeSpan(from start: Double, to end: Double) -> String {
        func stamp(_ seconds: Double) -> String {
            String(format: "%d:%05.2f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
        }
        return "\(stamp(start)) – \(stamp(end))  (\(stamp(max(0, end - start))))"
    }

    private func load() async {
        do {
            // Before the composition: `configuredComposition` reads
            // `StageCompositor.framingOverrides`, which `FramingReviewModel.load` publishes.
            review.load(observationLogAt: ObservationWriter.expectedLogURL(forMediaURL: mediaURL)
                .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
            let composition = try await Self.configuredComposition(for: mediaURL, variant: variant)
            let asset = AVURLAsset(url: mediaURL)
            let loaded = try await asset.load(.duration)
            if duration == nil { duration = loaded.seconds }
            let item = AVPlayerItem(asset: asset)
            item.videoComposition = composition
            // **The preview obeys the trim.** A trim a person can set but not see is a
            // setting, not an edit: they would only find out what they chose after exporting.
            if let end = trimEnd {
                item.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 600)
            }
            let created = AVPlayer(playerItem: item)
            if trimStart > 0 {
                await created.seek(to: CMTime(seconds: trimStart, preferredTimescale: 600))
            }
            player = created
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
                trim: trimRange())
            exportStatus = "Exported \(report.framesWritten) frame(s) at "
                + "\(size.width)\u{00D7}\(size.height) to "
                + "\(report.outputURL.lastPathComponent)."
        } catch {
            exportStatus = "Export failed: \(error)"
        }
    }
}


/// A labelled slider that reports on release. Same reason as `StageStylePicker`'s: the host
/// rebuilds an `AVVideoComposition` on each committed value, and doing that per intermediate
/// value of a drag would make the control unusable.
private struct TrimSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let commit: (Double) -> Void
    @State private var live: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2fs", live ?? value))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.caption)
            Slider(value: Binding(get: { live ?? value }, set: { live = $0 }), in: range) { editing in
                if !editing, let settled = live {
                    commit(settled)
                    live = nil
                }
            }
        }
    }
}
