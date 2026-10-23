import SwiftUI
import Timeline

/// The playhead, drawn over every lane at once.
///
/// **One line down the whole stack, not a mark inside the picture track.** The strip drew its
/// own and no other lane did, so a zoom block, a caption and the waveform could not be read
/// against the position the preview was at — which is the entire reason those lanes are stacked
/// and aligned in the first place, and why the line runs from the ruler to the bottom rather
/// than sitting inside one lane.
///
/// Offset by `TimelineLayout.contentOrigin`, the same one number every lane uses, so this cannot
/// drift away from the strips it is measuring.
struct TimelinePlayheadLine: View {
    let model: TimelineEditorModel

    var body: some View {
        // **`AtPlayhead` OUTSIDE the `GeometryReader`, and the order was measured.** The first
        // version of this fix left the read inside it, on the assumption that a
        // `GeometryReader`'s closure runs in its own update and so registers the dependency
        // there. `Self._printChanges()` said otherwise: `\TimelineEditorModel.playhead changed`
        // against `TimelineEditor`, 68 times in eight seconds of playback, with every other read
        // in the timeline already moved out. The closure is built during the body that builds
        // it, and that is where `@Observable` attributes what it touches.
        AtPlayhead(model: model) { playhead in
            GeometryReader { proxy in
                let track = max(proxy.size.width - TimelineLayout.contentOrigin, 1)
                Rectangle()
                    .fill(Theme.Ink.primary)
                    .frame(width: 1)
                    .offset(x: TimelineLayout.contentOrigin
                               + model.window.fraction(of: playhead) * track)
            }
            .allowsHitTesting(false)
        }
    }
}

/// The marked export range: the parts that will NOT be written, dimmed.
///
/// **Dimming what is excluded rather than tinting what is included.** A tint over the
/// selection competes with the clips, the zoom blocks and the waveform, all of which are
/// already colour; taking light away from the rest says the same thing and reads instantly
/// even on a dense timeline. Screen recorders and NLEs alike settle on this.
struct TimelineExportRangeShade: View {
    let model: TimelineEditorModel

    var body: some View {
        // The span in SOURCE time, because the strip is: `exportRange` is output time and
        // drawn here directly sat late by everything cut before it.
        if let range = model.exportRangeInSource {
            GeometryReader { proxy in
                // The same origin the playhead uses, and for the same reason.
                let contentOrigin = TimelineLayout.contentOrigin
                let track = max(proxy.size.width - contentOrigin, 1)
                let start = model.window.fraction(of: Nanoseconds(range.lowerBound)) * track
                let end = model.window.fraction(of: Nanoseconds(range.upperBound)) * track
                ZStack(alignment: .topLeading) {
                    // **Every offset starts at `contentOrigin`.** The lead-in shade had none in
                    // its first version and covered the lane headers, which are outside the
                    // strip and are not part of any range.
                    Rectangle().fill(Theme.Ink.primary.opacity(0.45))
                        .frame(width: max(start, 0))
                        .offset(x: contentOrigin)
                    Rectangle().fill(Theme.Ink.primary.opacity(0.45))
                        .frame(width: max(track - end, 0))
                        .offset(x: contentOrigin + end)
                    // The edges themselves, so a range whose ends are near the strip's own is
                    // still findable.
                    Rectangle().fill(Theme.accent).frame(width: 2)
                        .offset(x: contentOrigin + start)
                    Rectangle().fill(Theme.accent).frame(width: 2)
                        .offset(x: contentOrigin + end - 2)
                }
            }
            .allowsHitTesting(false)
        }
    }
}
