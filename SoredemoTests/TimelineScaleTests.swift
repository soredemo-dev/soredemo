import Testing
import Foundation
import Timeline
@testable import Soredemo

/// **Points on the strip and time in the recording, at one width and one window** — from
/// `docs/design/2026-10-23-splitting-the-timeline.md`. These conversions were private methods of
/// the timeline's view and could only be exercised by dragging.
@Suite struct TimelineScaleTests {
    private func seconds(_ value: Double) -> Nanoseconds { Nanoseconds(Int64(value * 1e9)) }

    /// **Zoomed, and not starting at zero.** A window over the whole recording from time zero is
    /// the identity of both halves of the conversion: a mapping that ignored the window's start
    /// or its zoom would pass against it. This one shows 10 s to 30 s of a 60 s recording across
    /// 400 points, so a second is 20 points and the left edge is 10 s.
    private var scale: TimelineScale {
        TimelineScale(window: TimelineWindow(total: seconds(60), start: seconds(10),
                                             visible: seconds(20)),
                      width: 400)!
    }

    @Test func aPointOnTheStripIsTheInstantUnderIt() {
        #expect(scale.position(atX: 100) == seconds(15))
    }

    @Test func anInstantIsDrawnWhereItsPointIs() {
        #expect(scale.x(of: seconds(15)) == 100)
        #expect(scale.width(from: seconds(12), to: seconds(14)) == 40)
    }

    /// The snap tolerance is the same distance on screen at every zoom: eight points here is
    /// 0.4 s, and would be a different number of seconds in a different window.
    @Test func aSpanOfPointsIsTheTimeItCoversAtThisZoom() {
        #expect(scale.span(forPoints: 8) == seconds(0.4))
        #expect(scale.snapThreshold(exact: false) == seconds(0.4))
    }

    /// **A drag to the left is earlier.** The trim handles lost this in `b7d9bbb`: the span they
    /// were converted through is a magnitude, so dragging a clip's start left — to give it back
    /// some footage — moved the start right and cut more.
    @Test func aDragToTheLeftIsAnEarlierOffset() {
        #expect(scale.offset(forPoints: -20) == -seconds(1).rawValue)
        #expect(scale.offset(forPoints: 20) == seconds(1).rawValue)
    }

    /// ⌘ held means "exactly where my hand is".
    @Test func anExactDragDoesNotSnap() {
        #expect(scale.snapThreshold(exact: true) == Nanoseconds(0))
    }

    /// **No width, no scale.** The conversions this replaces answered the recording's start and
    /// a zero span — both legal answers, so a strip measured before layout looked like a click
    /// at time zero rather than like nothing.
    @Test func aStripWithNoWidthHasNoScale() {
        let window = TimelineWindow.whole(seconds(60))
        #expect(TimelineScale(window: window, width: 0) == nil)
        #expect(TimelineScale(window: window, width: -1) == nil)
    }
}
