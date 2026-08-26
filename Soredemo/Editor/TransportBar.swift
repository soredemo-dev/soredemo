import AVFoundation
import Compositing
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
    /// Playback speed. **A review control, not an edit** — it changes how fast the preview
    /// plays and nothing about the file. a native editor separates the two the same way
    /// (`PreviewPlaybackRate`); a speed that silently became an export setting would be the
    /// worst kind of surprise.
    @State private var rate: Double = 1

    static let rates: [Double] = [0.25, 0.5, 1, 1.5, 2, 4]

    /// How close to the end counts as the end. One frame at 24 fps is 42 ms, so 50 ms is
    /// "the last frame or later" at every rate this app exports — and `AVPlayer` stops a hair
    /// short of the exact duration often enough that comparing for equality would leave the
    /// dead button in place for exactly the people who reported it.
    private static let endTolerance: Double = 0.05

    /// True when the preview has run out. `total` is the item's duration as the ticker last
    /// read it; before it has been read at all there is no end to be at.
    private var atEnd: Bool {
        total > 0 && position >= total - Self.endTolerance
    }

    /// 10 Hz. A timecode that updates faster than a person can read it is a timecode that
    /// flickers, and this is text rather than a bar — nothing here needs frame accuracy.
    private static let tick: Double = 0.1

    var body: some View {
        HStack(spacing: Space.regular) {
            Button {
                if isPlaying {
                    player.pause()
                } else if atEnd {
                    // **Play at the end restarts, and it used to do nothing at all.** An
                    // `AVPlayer` sitting at its item's duration ignores a rate change — there
                    // is nowhere left to advance to — so the button was dead for every person
                    // who watched their recording through and pressed play again. Seek first,
                    // then start, so the rate is not applied to a player that is still seeking.
                    //
                    // The `async` seek rather than the completion-handler one: the handler is
                    // `@Sendable`, so reading `rate` (this view's own state) inside it is a
                    // main-actor value crossing into a nonisolated closure. `StageWindow` seeks
                    // the same way for the same reason.
                    Task { @MainActor in
                        await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                        player.rate = Float(rate)
                    }
                } else {
                    // `rate =` rather than `play()`: `play()` always resumes at 1×, so a chosen
                    // speed would be silently discarded on every pause.
                    player.rate = Float(rate)
                }
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

            PlaybackMeter(waveform: model.waveform, position: position)

            Menu {
                ForEach(Self.rates, id: \.self) { value in
                    Button(Self.rateLabel(value)) {
                        rate = value
                        // Set on the player rather than remembered and applied at play: a rate
                        // changed mid-playback has to take effect mid-playback, which is when
                        // a person is comparing it against the speed before.
                        if player.timeControlStatus == .playing { player.rate = Float(value) }
                    }
                }
            } label: {
                Text(Self.rateLabel(rate))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(rate == 1 ? Theme.Ink.secondary : Theme.accent)
                    .frame(width: 38)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Preview speed \u{2014} the export is unaffected")

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
            // **The timeline's playhead is driven from here.** This is the one place that
            // already asks the player where it is, and a second poller would be a second answer
            // to the same question — drifting from this one by whatever the two timers differ
            // by. `followPlayer` moves the line without asking the player to seek.
            if isPlaying, position.isFinite {
                model.followPlayer(outputTime: Nanoseconds(Int64(position * 1_000_000_000)))
            }
            if let item = player.currentItem, item.duration.seconds.isFinite {
                total = item.duration.seconds
            }
        }
    }

    /// `m:ss.t`. Tenths because a cut is placed to a tenth and a person checking one against the
    /// timecode needs the digit that moved.
    /// `1x`, `0.5x` — trailing zeroes dropped, because a row of readouts is read at a glance.
    static func rateLabel(_ rate: Double) -> String {
        rate == rate.rounded() ? "\(Int(rate))\u{00D7}" : String(format: "%.2g\u{00D7}", rate)
    }

    static func timecode(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let whole = Int(clamped)
        return String(format: "%d:%02d.%d", whole / 60, whole % 60,
                      Int((clamped - Double(whole)) * 10))
    }
}


/// The recording's own level at the playhead.
///
/// **A real measurement, from the envelope the waveform is drawn from.** The first version of
/// this showed `player.volume` while playing, which is an is-it-playing light wearing a meter's
/// clothes — and this project's own completion rule says a row is not done while the behaviour
/// its name claims is not observable. The envelope is already read for the timeline; asking it
/// for the peak at one position costs an index.
///
/// **What it cannot do**, said rather than implied: it reads the recording, not the mixed
/// output, so muting the microphone does not lower it. Separating the two sources needs a peak
/// per track, which the envelope deliberately does not keep — it is mono because a strip has
/// room for one waveform. The label says "Level at the playhead" for that reason.
private struct PlaybackMeter: View {
    let waveform: WaveformEnvelope?
    let position: Double

    private var level: Double {
        guard let waveform, !waveform.isEmpty else { return 0 }
        // One column covering a tenth of a second around the playhead: a single slice is 5 ms
        // and flickers, and a person watching a meter is asking about "now", not about this
        // instant.
        return waveform.columnHeights(columns: 1, from: max(0, position - 0.05),
                                      spanningSeconds: 0.1).first ?? 0
    }

    var body: some View {
        let level = level
        HStack(spacing: 3) {
            ForEach(0..<8, id: \.self) { index in
                let threshold = Double(index + 1) / 8
                Capsule()
                    .fill(level >= threshold ? Signal.level : Theme.Fill.track)
                    .frame(width: 2, height: 4 + Double(index))
            }
        }
        .frame(height: 14)
        .animation(.linear(duration: 0.08), value: level)
        .help("Level at the playhead")
    }
}
