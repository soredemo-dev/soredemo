import AVFoundation
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
