import SwiftUI

/// The audio envelope as bars, mirrored about the middle — which is how a waveform is read.
///
/// **`Equatable`, and that is the performance decision.** A strip is a few hundred columns, so
/// this is a few hundred `Rectangle`s; SwiftUI would re-evaluate every one of them on each
/// playhead move without a way to know nothing changed. Conforming lets it skip the subtree
/// when the heights and the height are the same, which they are for every frame of a scrub.
///
/// `.drawingGroup()` rasterises the result once through Metal rather than compositing hundreds
/// of layers per frame.
///
/// **No CoreGraphics geometry is named here**, which rule 5 requires of this tier: the heights
/// arrive as plain numbers from `WaveformEnvelope` and become bars through `frame`/`offset`.
/// **Internal, not private: two lanes draw a waveform and there is one way to do it.**
/// The timeline draws the recording's audio under its clips; `CaptionWaveform` draws the same
/// audio under a block per cue. A second copy would be a second set of bar widths, a second
/// silence rule, and eventually two waveforms of the same recording that did not agree.
struct WaveformBars: View, Equatable {
    let heights: [Double]
    let height: Double
    /// **The frame's width, and without it nothing is drawn.** `.offset` moves a view without
    /// changing the layout, so a `ZStack` of offset bars is as wide as ONE bar — and
    /// `.drawingGroup()` rasterises to the view's bounds, which clipped every bar past the first
    /// away. The waveform had been invisible since it was written, for this and for being drawn
    /// under opaque clips; the reader was fine all along, measured at 3,816 peaks on the
    /// recording that prompted the search.
    let width: Double
    let tint: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(heights.indices, id: \.self) { column in
                let bar = heights[column] * height
                // A silent column draws nothing rather than a hairline across the silence.
                if bar > 0 {
                    Rectangle()
                        // Its own lane colour rather than ink at a low opacity: a waveform is a
                        // track, and the four tracks around it all carry a hue.
                        .fill(tint)
                        .frame(width: 1, height: bar)
                        .offset(x: Double(column), y: (height - bar) / 2)
                }
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .drawingGroup()
        .allowsHitTesting(false)
    }
}
