import Foundation
import Timeline
import SwiftUI

/// The time ruler.
///
/// **The tick interval is chosen from the visible span, not fixed.** A ruler with a tick
/// every second is unreadable at a twenty-minute zoom and useless at a half-second one; the
/// interval is the smallest step from a human list — 0.1s up to 10 minutes — that leaves at
/// least 64 points between labels. A fixed interval is what makes a timeline look like a
/// progress bar.
struct TimelineRuler: View {
    let model: TimelineEditorModel

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let visible = Double(model.window.visible.rawValue) / 1_000_000_000
            let step = Self.tickStep(visibleSeconds: visible, width: width)
            let start = Double(model.window.start.rawValue) / 1_000_000_000
            let first = (start / step).rounded(.down) * step
            ZStack(alignment: .topLeading) {
                ForEach(0..<Self.maximumTicks, id: \.self) { index in
                    let seconds = first + Double(index) * step
                    let fraction = (seconds - start) / max(visible, 0.000_001)
                    if fraction >= 0, fraction <= 1, seconds >= 0 {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: Self.tickLabel(seconds, step: step))
                                .font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(Theme.Ink.tertiary)
                                .fixedSize()
                            Rectangle().fill(Theme.Line.divider).frame(width: 1, height: 4)
                        }
                        .offset(x: fraction * width)
                    }
                }
            }
        }
    }

    /// A bounded loop rather than a computed count: `ForEach` over a range SwiftUI cannot see the
    /// bounds of re-evaluates on every zoom frame, and a ruler is redrawn while dragging.
    private static let maximumTicks = 40

    static func tickStep(visibleSeconds: Double, width: Double) -> Double {
        let candidates: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        let minimumSpacing: Double = 64
        for step in candidates where width * step / max(visibleSeconds, 0.000_001) >= minimumSpacing {
            return step
        }
        return candidates[candidates.count - 1]
    }

    /// `m:ss` above a second, `m:ss.t` below it — a ruler stepping in tenths that prints whole
    /// seconds prints the same label several times in a row.
    static func tickLabel(_ seconds: Double, step: Double) -> String {
        let whole = Int(seconds)
        if step < 1 {
            return String(format: "%d:%02d.%d", whole / 60, whole % 60,
                          Int((seconds - Double(whole)) * 10))
        }
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
