import AVKit
import SwiftUI

/// The preview surface. Deliberately opaque: D7 reserves glass for controls
/// floating above content, and a video preview is content.
struct PreviewView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        // **Live Text off, and set BEFORE the player.** `AVPlayerView` analyses video frames
        // for text and subjects by default, which for a screen recording means running OCR
        // over a screen full of text, continuously, while it plays — and hanging VisionKit's
        // overlay views inside this hosting view, where their layout runs during ours. See
        // `docs/design/why-the-editor-felt-slow.md` for the measurement.
        //
        // **The order was wrong and the console said so.** Assigning `player` is what starts
        // the analysis machinery, and this was one line below it: VisionKit had already been
        // asked by the time it was turned off. `checkRichAnalysisAvailability XPC failed:
        // Underlying connection interrupted` is that question being asked and abandoned, and
        // it appeared twice in a build where this was supposed to be off.
        view.allowsVideoFrameAnalysis = false
        view.player = player
        // **No inline controls.** `TransportBar` under the preview does this job, always
        // visible, with a timecode rather than a scrubber — AVKit's controls fade out, float
        // over the picture, and carry a second timeline that knows nothing about the edit.
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        // Re-asserted, and again before the player. A view handed a new `AVPlayer` is a view
        // being re-derived, and an authored value that does not survive re-derivation is a
        // setting somebody chose and the app quietly dropped.
        view.allowsVideoFrameAnalysis = false
        view.player = player
    }
}
