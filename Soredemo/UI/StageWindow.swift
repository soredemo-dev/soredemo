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
    let mediaURL: URL

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
    }

    private func load() async {
        do {
            StageCompositor.renderer = try CoreImageFrameRenderer()
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
            let composition = try await CompositionBuilder.composition(
                for: asset, outputWidth: 1920, outputHeight: 1080,
                frameDuration: CMTime(value: 1, timescale: 60))
            let item = AVPlayerItem(asset: asset)
            item.videoComposition = composition
            player = AVPlayer(playerItem: item)
        } catch {
            failure = "\(error)"
        }
    }
}
