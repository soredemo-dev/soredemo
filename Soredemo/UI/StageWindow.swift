import AppKit
import AVFoundation
import Foundation
// `Headless` is the module name; `SoredemoHeadless` is the product this app target links.
import Headless
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
        .toolbar {
            // A plain toolbar `Button`, not a `.commands { CommandGroup }` menu item: `.commands`
            // can only attach to a `Scene`, never to a plain `View`.
            ToolbarItem {
                Button("Export…") { Task { await exportRecording() } }
                    .disabled(player == nil || isExporting)
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
