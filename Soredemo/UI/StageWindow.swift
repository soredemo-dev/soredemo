import AppKit
import AVFoundation
import Foundation
// Both halves of the runnable tier, split in Phase 3A-4: `Compositing` for the
// compositor and the exporter, `Capture` for `ObservationWriter`'s log paths. The product
// this app target links is `SoredemoHeadless`, which vends both.
import Capture
import Compositing
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
    @State private var isReviewShown = true
    /// Bumped whenever an override changes, to rebuild the composition. **The preview has to
    /// move**: the completion rule says a row is not done while the behaviour its name claims
    /// is not observable in the product, and an override that only changed a list would not
    /// be a review surface — it would be a form.
    @State private var reviewRevision = 0
    let mediaURL: URL

    /// The output size passed to both `CompositionBuilder.composition` calls in this file, so the
    /// preview and the export agree on the actual arguments. Not `private`: the render-parity
    /// check in `scripts/cross-boundary-digest-probe.swift` reads these two constants directly.
    static let outputWidth = 1920
    static let outputHeight = 1080

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
        // `reviewRevision` and not `review.overrides`: the composition is rebuilt when a
        // decision changes, and a counter says exactly that. Observing the array would also
        // fire on a load that merely restored the same decisions.
        .task(id: reviewRevision) { if reviewRevision > 0 { await load() } }
        .inspector(isPresented: $isReviewShown) {
            List {
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
    static func configuredComposition(for mediaURL: URL) async throws -> AVVideoComposition {
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
        return try await CompositionBuilder.composition(
            for: asset, outputWidth: Self.outputWidth, outputHeight: Self.outputHeight,
            frameDuration: CMTime(value: 1, timescale: 60))
    }

    private func load() async {
        do {
            // Before the composition: `configuredComposition` reads
            // `StageCompositor.framingOverrides`, which `FramingReviewModel.load` publishes.
            review.load(observationLogAt: ObservationWriter.expectedLogURL(forMediaURL: mediaURL)
                .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
            let composition = try await Self.configuredComposition(for: mediaURL)
            let asset = AVURLAsset(url: mediaURL)
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
            let report = try await MP4Exporter.export(
                asset: asset, to: destination,
                outputWidth: Self.outputWidth, outputHeight: Self.outputHeight)
            exportStatus = "Exported \(report.framesWritten) frame(s) to "
                + "\(report.outputURL.lastPathComponent)."
        } catch {
            exportStatus = "Export failed: \(error)"
        }
    }
}
