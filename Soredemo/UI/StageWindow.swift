import AppKit
import AVFoundation
// `FileManager` — checking whether the observation log `ObservationWriter.expectedLogURL(for
// MediaURL:)` names actually exists on disk, below.
import Foundation
import SwiftUI

/// `NavigationSplitView` + `Inspector`, 100% standard SwiftUI, zero glass code — D7. The system
/// gives these components Liquid Glass automatically and, decisively, makes them respond to the
/// system-level Liquid Glass slider, which a hand-rolled surface does not.
struct StageWindow: View {
    @State private var player: AVPlayer?
    @State private var failure: String?
    // MARK: - export-basic (Phase 2B Task 7)
    @State private var isExporting = false
    @State private var exportStatus: String?
    let mediaURL: URL

    /// The output size passed to BOTH `CompositionBuilder.composition` calls in this file — the
    /// preview's (`configuredComposition(for:)`, below) and the export's (`exportRecording()`) —
    /// so "preview and export agree" stays true of the actual arguments, not only of the shared
    /// function.
    ///
    /// **Not `private` — corrected here, code review (Task 8, fix round 1), Important finding 1.**
    /// `scripts/cross-boundary-digest-probe.swift` § 15 (`render-parity`) used to hardcode its own
    /// `320×180` rather than reading this app's real `1920×1080`, which meant a regression that
    /// changed only THIS app's own output size could not be seen by that check. It reads these two
    /// constants directly now, so the two cannot silently drift apart.
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
            // **The Export command, and why it is a plain toolbar `Button` rather than a
            // `.commands { CommandGroup }` menu item.** The brief's file list puts this command in
            // `StageWindow.swift` itself. `SoredemoApp.swift`'s own doc comment records the SAME
            // brief-vs-reality gap for Task 4's "Open Recording…": `.commands` can only attach to
            // a `Scene`, never to a plain `View`, so that command had to move to `SoredemoApp`
            // regardless of which file its brief named. A toolbar `Button` has no such
            // restriction — it is ordinary SwiftUI content a `View` hosts directly — so THIS
            // command, unlike that one, can live exactly where its own brief put it without
            // repeating Task 4's file-list correction.
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

    /// Everything the preview needs configured before a composed frame can be read — the shared
    /// compositor statics, and the `AVVideoComposition` itself — extracted out of `load()` here.
    ///
    /// **Why this is its own function — code review (Task 8, fix round 1), Important finding 1.**
    /// `scripts/cross-boundary-digest-probe.swift` § 15's preview leg used to reconstruct this
    /// logic itself: its own inline `CompositionBuilder.composition(...)` call, at its own
    /// hardcoded output size, never touching `StageWindow` at all. That meant a regression
    /// confined to what THIS function does — a wrong output size, a wrong `frameDuration`, a
    /// renderer left unconfigured, a broken `observationLogURL` lookup — left § 15 green while the
    /// app's real preview had genuinely diverged from export. Calling the SAME function the real
    /// preview calls closes that gap; only `AVPlayerItem`/`AVPlayer` construction below (UI
    /// plumbing with no bearing on what gets composed) stays outside it, which is also why
    /// `load()` below still builds its own `AVPlayerItem`'s asset rather than this function
    /// returning one — `MP4Exporter.export` already builds its own asset from the same URL
    /// independently (`Soredemo/Export/MP4Exporter.swift`), the same "each real consumer loads the
    /// file itself" shape this follows.
    static func configuredComposition(for mediaURL: URL) async throws -> AVVideoComposition {
        StageCompositor.renderer = try CoreImageFrameRenderer()
        // A fresh recording gets a fresh drop count — see `StageCompositor.diagnostics`'s own
        // header for why a stale count from a previously opened file must not be readable as
        // belonging to this one.
        StageCompositor.resetDiagnostics()
        // `ObservationWriter.expectedLogURL(forMediaURL:)` names where a log for THIS media
        // would be, following the same `media/master-NN.mov` ↔ `observations/segment-NN.jsonl`
        // pairing `beginSegment`/`ObservationWriter` already define — it does not claim one is
        // there. The filesystem check right here is what turns "where it would be" into
        // "whether it is": a recording made without Input Monitoring, or one made before
        // Task 5.5 gave `CaptureSession` an `ObservationWriter` to write to at all,
        // legitimately has none, and `nil` is what tells
        // `StageCompositor` to draw no pointer rather than fabricating an empty log or guessing
        // a default path. `PointerReading`'s four cases exist so "no log" and "a log that says
        // nothing" stay distinguishable; this is the one point that decides which of those two
        // this session is in.
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

    /// Presents a save panel, then runs `MP4Exporter.export` — see that type's own header for
    /// which writer this goes through and why. `StageCompositor`'s statics (`renderer`, `style`,
    /// `observationLogURL`) are already set by `load()` above by the time this can be invoked
    /// (the toolbar button is disabled while `player == nil`, and `player` is set only after
    /// `load()`'s composition succeeds), so the export's composition draws the identical framing
    /// and pointer the preview already showed — the same statics, not a second configuration.
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
