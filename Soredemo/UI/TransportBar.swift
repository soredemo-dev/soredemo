import AVFoundation
import Combine
import SwiftUI
import Timeline

/// Play, pause, and where you are.
///
/// **`AVPlayerView`'s inline controls were doing this and doing it as a video player.** They
/// fade out, they float over the picture, and their scrubber is a second timeline that knows
/// nothing about the edit — three properties that are right for watching a film and wrong for
/// cutting one. a Swift recorder and a native editor both put a transport row under the preview, always
/// visible, with the timecode as text rather than as a bar.
///
/// **The timecode is the output's, not the source's.** A person watching the preview is watching
/// the edit; telling them 0:41 when the cut recording is 30 seconds long would be reporting a
/// position in a file nobody is looking at.
struct TransportBar: View {
    let player: AVPlayer
    let model: TimelineEditorModel

    @State private var isPlaying = false
    @State private var position: Double = 0
    @State private var total: Double = 0

    /// 10 Hz. A timecode that updates faster than a person can read it is a timecode that
    /// flickers, and this is text rather than a bar — nothing here needs frame accuracy.
    private static let tick: Double = 0.1

    var body: some View {
        HStack(spacing: Space.regular) {
            Button {
                if isPlaying { player.pause() } else { player.play() }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Ink.primary)
                    .frame(width: 30, height: 24)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Theme.Fill.rest)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .help(isPlaying ? "Pause (Space)" : "Play (Space)")

            Button { player.seek(to: .zero) } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Ink.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to the start")

            Text(Self.timecode(position))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.Ink.primary)
            Text("/")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Ink.tertiary)
            Text(Self.timecode(total))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.Ink.secondary)

            Spacer()

            // What the export will be, stated where a person is looking at the picture rather
            // than only in the inspector three tabs away.
            Text(model.hasEdits ? "Edited" : "Unedited")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Ink.tertiary)
        }
        .padding(.horizontal, Space.regular)
        .frame(height: 34)
        .background(Theme.Surface.raised)
        .onReceive(Timer.publish(every: Self.tick, on: .main, in: .common).autoconnect()) { _ in
            // Polled rather than observed: `addPeriodicTimeObserver` needs a token held for the
            // player's lifetime, and this view is rebuilt whenever the edit changes the asset —
            // which would leak one observer per rebuild.
            isPlaying = player.timeControlStatus == .playing
            position = player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0
            if let item = player.currentItem, item.duration.seconds.isFinite {
                total = item.duration.seconds
            }
        }
    }

    /// `m:ss.t`. Tenths because a cut is placed to a tenth and a person checking one against the
    /// timecode needs the digit that moved.
    static func timecode(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let whole = Int(clamped)
        return String(format: "%d:%02d.%d", whole / 60, whole % 60,
                      Int((clamped - Double(whole)) * 10))
    }
}
