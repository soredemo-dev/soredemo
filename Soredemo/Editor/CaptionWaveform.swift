import Compositing
import Foundation
import Overlays
import SwiftUI
import Timeline

/// The recording's audio with a block per cue drawn over it, and the playhead through both.
///
/// **The last row of the gap table**, and the one its own note called "the largest of these by
/// far": a caption editor's waveform is where you SEE that a cue starts a beat late, which is
/// the most common thing wrong with machine timings and the one thing a list of numbers cannot
/// show you. A cue's box against the sound it covers makes an early start obvious at a glance;
/// `0:19.6 → 0:27.3` does not.
///
/// **Gaps are as informative as blocks.** Audio with no box over it is a line the recogniser
/// dropped, and it is invisible in a list — the list has nothing to show, which is exactly the
/// problem. Here it is a stretch of waveform with nothing on it.
struct CaptionWaveform: View {
    let model: CaptionsModel
    let playhead: Nanoseconds
    let duration: Nanoseconds?
    let waveform: WaveformEnvelope?
    /// How much of the recording is shown, as a fraction. Held by the host so the zoom survives
    /// the view being rebuilt on every playhead tick.
    @Binding var visibleFraction: Double
    let onSeek: (Nanoseconds) -> Void
    let onChange: () -> Void

    /// The window, centred on the playhead.
    ///
    /// **Centred rather than paged.** A window that scrolled a screen at a time would put the
    /// line being worked on at an edge half the time; centring means the sound around the
    /// playhead is always the sound you can see, which is what the zoom is for.
    private var window: (start: Double, seconds: Double)? {
        guard let duration, duration.rawValue > 0 else { return nil }
        let whole = Double(duration.rawValue) / 1_000_000_000
        let visible = max(1, whole * min(1, max(0.02, visibleFraction)))
        let centre = Double(playhead.rawValue) / 1_000_000_000
        let start = min(max(0, centre - visible / 2), max(0, whole - visible))
        return (start, visible)
    }

    var body: some View {
        VStack(spacing: 0) {
            zoomControls
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Theme.Fill.track)
                    if let window, let waveform, !waveform.isEmpty, width > 0 {
                        WaveformBars(
                            heights: waveform.columnHeights(columns: Int(width.rounded(.down)),
                                                            from: window.start,
                                                            spanningSeconds: window.seconds),
                            height: geometry.size.height, width: width, tint: Theme.Lane.audio)
                            .equatable()
                        blocks(width: width, height: geometry.size.height, window: window)
                        playhead(width: width, height: geometry.size.height, window: window)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    // **Drag, not tap.** Scrubbing a waveform is how somebody finds the moment a
                    // word starts, and a control that only accepted a click would make them
                    // guess, click, listen, and guess again.
                    guard let window, width > 0 else { return }
                    let seconds = window.start
                        + min(max(0, value.location.x / width), 1) * window.seconds
                    onSeek(Nanoseconds(Int64(max(0, seconds) * 1_000_000_000)))
                })
            }
        }
    }

    /// A block per cue, positioned in the window.
    @ViewBuilder private func blocks(width: Double, height: Double,
                                     window: (start: Double, seconds: Double)) -> some View {
        ForEach(Array(model.track.cues.enumerated()), id: \.offset) { index, cue in
            let start = Double(cue.start.rawValue) / 1_000_000_000
            let end = Double(cue.end.rawValue) / 1_000_000_000
            if end > window.start, start < window.start + window.seconds {
                let x = (start - window.start) / window.seconds * width
                let w = (end - start) / window.seconds * width
                block(index: index, cue: cue)
                    // **A floor of 2 points, and never less.** A 200 ms cue at full zoom is
                    // under a point wide, and a block nobody can see is a cue nobody can tell is
                    // there — which is the same failure as it not being drawn.
                    .frame(width: max(w, 2), height: height * 0.42)
                    .offset(x: x, y: height * 0.58)
            }
        }
    }

    /// One cue's box: filled for a cue that reads, outlined for one that breaks a rule.
    ///
    /// **The fault decides the outline, not the fill.** A red block would make a too-fast line
    /// the loudest thing on a lane whose job is to show timing; an outline says the same thing
    /// without taking the eye off where the cue sits against the sound.
    @ViewBuilder private func block(index: Int, cue: CaptionCue) -> some View {
        let faulty = cue.measurement.fault != nil
        RoundedRectangle(cornerRadius: Radius.block, style: .continuous)
            .fill(Theme.Lane.caption)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.block, style: .continuous)
                    .strokeBorder(faulty ? Signal.paused : .clear, lineWidth: 1))
            .onTapGesture { onSeek(cue.start) }
            // **A cue's own text is content, not a key** — `verbatim` for the same reason
            // `TargetCard` has a `verbatimTitle`: a sentence somebody said must not be looked
            // up in a table, where it would fall through to itself and cost a lookup per hover.
            .help(cue.text)
    }

    @ViewBuilder private func playhead(width: Double, height: Double,
                                       window: (start: Double, seconds: Double)) -> some View {
        let centre = Double(playhead.rawValue) / 1_000_000_000
        let fraction = (centre - window.start) / window.seconds
        if fraction >= 0, fraction <= 1 {
            Rectangle().fill(Theme.accent).frame(width: 1, height: height)
                .offset(x: fraction * width)
                .allowsHitTesting(false)
        }
    }

    /// **Fractions of the recording, not a magnification factor.** "58%" is what the surveyed
    /// editor shows and it answers the question somebody actually has — how much of this am I
    /// looking at — where "4.2×" answers one they did not ask.
    @ViewBuilder private var zoomControls: some View {
        HStack(spacing: Space.snug) {
            Text("\(Int((visibleFraction * 100).rounded()))%")
                .font(Type.readout).foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Slider(value: $visibleFraction, in: 0.02...1) { Text("Zoom") }
                .controlSize(.mini)
                .labelsHidden()
            Button {
                visibleFraction = 1
            } label: {
                Image(systemName: "arrow.left.and.right")
            }
            .buttonStyle(.borderless)
            .tooltip("Show the whole recording")
        }
        .padding(.horizontal, Space.regular)
        .frame(height: 22)
    }
}
