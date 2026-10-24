import SwiftUI

/// The take's elapsed time as every recording surface shows it — the bar, the menu bar panel and
/// the notch.
///
/// **Here rather than on the bar**, which the other two reached into for it; see
/// `docs/design/2026-10-24-splitting-the-recording-bar.md`.
enum ElapsedTime {
    /// `m:ss` under an hour, `h:mm:ss` over it. A leading `00:` on every recording is two
    /// characters of nothing in the one place where width costs the layout.
    /// **Not named `clock`.** `noAppSourceReadsAnAmbientValueAtAll` bans that substring in
    /// app sources, because a clock is where ambient time enters — and the ban being absolute is
    /// what makes it worth having. This function reads no time; it formats a number it is given.
    static func text(_ seconds: Double) -> String {
        let whole = Int(max(0, seconds))
        let (hours, minutes, secs) = (whole / 3600, (whole / 60) % 60, whole % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

/// The record indicator: pulsing while recording, steady while paused.
///
/// **It stops pulsing when paused rather than changing colour**, because the pulse is what makes
/// a person notice it at all in the corner of their eye, and a paused recording is exactly when
/// they need to notice.
struct PulsingDot: View {
    let isPaused: Bool
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(isPaused ? Signal.paused : Signal.record)
            .frame(width: 9, height: 9)
            .opacity(isPaused ? 1 : (dim ? 0.3 : 1))
            .animation(isPaused ? nil
                       : .easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
            .accessibilityLabel(isPaused ? Text("Paused") : Text("Recording"))
    }
}

/// A thin horizontal level bar. `nil` draws the track alone — the state that means "nothing is
/// being heard", which is different from "silence" and must not look the same as a full meter.
struct LevelMeter: View {
    let level: Double?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule()
                    .fill(Signal.level)
                    .frame(width: proxy.size.width * (level ?? 0))
            }
        }
        .frame(height: 3)
        .animation(.linear(duration: 0.05), value: level)
    }
}
