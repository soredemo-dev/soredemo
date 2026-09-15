import AVKit
import SwiftUI

/// The preview surface. Deliberately opaque: D7 reserves glass for controls
/// floating above content, and a video preview is content.
struct PreviewView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        // **No inline controls.** `TransportBar` under the preview does this job, always
        // visible, with a timecode rather than a scrubber — AVKit's controls fade out, float
        // over the picture, and carry a second timeline that knows nothing about the edit.
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        // **Live Text off.** `AVPlayerView` analyses video frames for text and subjects by
        // default, which for a screen recording means running OCR over a screen full of text,
        // continuously, while it plays — and hanging VisionKit's overlay views inside this
        // hosting view, where their layout runs during ours. See
        // `docs/design/why-the-editor-felt-slow.md` for the measurement.
        view.allowsVideoFrameAnalysis = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
    }
}
