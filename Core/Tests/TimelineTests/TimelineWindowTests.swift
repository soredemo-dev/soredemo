import Foundation
import Testing
@testable import Timeline

private func ns(_ value: Int64) -> Nanoseconds { Nanoseconds(value) }
private let tenSeconds = ns(10_000_000_000)

/// **One copy of the conversion, tested without a window.** A strip that shows the whole
/// recording needs no state — the view can divide, which is what Soredemo's did. The moment it
/// zooms and scrolls, the same conversion appears in the drag handler, the clip rectangles,
/// the playhead, the trim handles and the waveform. Five copies of one rule is the shape this
/// project keeps finding bugs in.
@Suite struct TimelineWindowTests {
    @Test func aWholeWindowMapsTheRecordingOntoTheStrip() {
        let window = TimelineWindow.whole(tenSeconds)
        #expect(window.fraction(of: ns(0)) == 0)
        #expect(window.fraction(of: tenSeconds) == 1)
        #expect(window.position(atFraction: 0.5) == ns(5_000_000_000))
        #expect(window.magnification == 1)
        #expect(!window.canZoomOut)
        #expect(window.canZoomIn)
    }

    /// The two conversions are inverses wherever both are defined, checked across the strip
    /// rather than at chosen points.
    @Test func fractionAndTimeAreInverses() {
        let window = TimelineWindow(total: tenSeconds, start: ns(2_000_000_000),
                                    visible: ns(3_000_000_000))
        for step in 0...20 {
            let fraction = Double(step) / 20
            let time = window.position(atFraction: fraction)
            #expect(abs(window.fraction(of: time) - fraction) < 1e-9,
                    "fraction \(fraction) round-tripped to \(window.fraction(of: time))")
        }
    }

    /// **Not clamped**, so a caller can tell that a clip starts before the window and draw it
    /// running off the edge rather than piled against it.
    @Test func aTimeOutsideTheWindowHasAFractionOutsideZeroToOne() {
        let window = TimelineWindow(total: tenSeconds, start: ns(4_000_000_000),
                                    visible: ns(2_000_000_000))
        #expect(window.fraction(of: ns(3_000_000_000)) < 0)
        #expect(window.fraction(of: ns(7_000_000_000)) > 1)
    }

    // MARK: - clamping

    /// A window that could be out of bounds would have to be checked by every caller, and the
    /// one that forgot would scroll off the end of the recording.
    @Test func aWindowIsClampedIntoTheRecordingOnConstruction() {
        let past = TimelineWindow(total: tenSeconds, start: ns(9_000_000_000),
                                  visible: ns(5_000_000_000))
        #expect(past.end.rawValue <= tenSeconds.rawValue)
        #expect(past.start == ns(5_000_000_000))

        let before = TimelineWindow(total: tenSeconds, start: ns(-5_000_000_000),
                                    visible: ns(2_000_000_000))
        #expect(before.start == ns(0))

        let tooWide = TimelineWindow(total: tenSeconds, start: ns(0), visible: ns(99_000_000_000))
        #expect(tooWide.visible == tenSeconds)
    }

    /// A tenth of a second is the floor: past it a strip a few hundred points wide shows under
    /// a millisecond per point, finer than a frame at any rate this records at.
    @Test func theDeepestZoomIsBounded() {
        let window = TimelineWindow(total: tenSeconds, start: ns(0), visible: ns(1))
        #expect(window.visible == ns(TimelineWindow.minimumVisible))
        #expect(!window.canZoomIn)
    }

    // MARK: - zooming

    /// **The anchor is what makes zooming usable.** Zooming about the window's start walks the
    /// content out from under the cursor; anchoring keeps what a person is looking at where
    /// they are looking.
    @Test func zoomingHoldsTheAnchoredTimeInPlace() {
        let window = TimelineWindow.whole(tenSeconds)
        let anchor = 0.25
        let before = window.position(atFraction: anchor)
        let zoomed = window.zoomed(by: 4, anchoredAtFraction: anchor)
        let after = zoomed.position(atFraction: anchor)
        #expect(abs(after.rawValue - before.rawValue) < 2_000_000,
                "the anchored instant moved from \(before.rawValue) to \(after.rawValue)")
        #expect(abs(zoomed.magnification - 4) < 0.01)
    }

    /// Zooming out past the recording gives the whole recording, not a window with blank
    /// space either side.
    @Test func zoomingOutStopsAtTheWholeRecording() {
        let window = TimelineWindow.whole(tenSeconds).zoomed(by: 4, anchoredAtFraction: 0.5)
        let out = window.zoomed(by: 0.01, anchoredAtFraction: 0.5)
        #expect(out.visible == tenSeconds)
        #expect(out.start == ns(0))
    }

    /// Zoom in then out by the same factor returns to where it started — a person pinching
    /// back and forth must not drift.
    @Test func zoomingInAndOutByTheSameFactorReturns() {
        let window = TimelineWindow.whole(tenSeconds)
        let round = window.zoomed(by: 3, anchoredAtFraction: 0.5)
            .zoomed(by: 1.0 / 3, anchoredAtFraction: 0.5)
        #expect(abs(round.visible.rawValue - window.visible.rawValue) < 2_000_000)
        #expect(abs(round.start.rawValue - window.start.rawValue) < 2_000_000)
    }

    // MARK: - scrolling

    @Test func scrollingMovesByAFractionOfWhatIsVisible() {
        let window = TimelineWindow(total: tenSeconds, start: ns(2_000_000_000),
                                    visible: ns(2_000_000_000))
        #expect(window.scrolled(byFraction: 0.5).start == ns(3_000_000_000))
        #expect(window.scrolled(byFraction: -0.5).start == ns(1_000_000_000))
        // …and cannot leave the recording.
        #expect(window.scrolled(byFraction: -10).start == ns(0))
        #expect(window.scrolled(byFraction: 10).end == tenSeconds)
    }

    /// **Nothing happens when the time is already on screen**, which is what stops a playhead
    /// near the middle from dragging the view with it on every frame of playback.
    @Test func revealingSomethingAlreadyVisibleChangesNothing() {
        let window = TimelineWindow(total: tenSeconds, start: ns(2_000_000_000),
                                    visible: ns(4_000_000_000))
        #expect(window.revealing(ns(3_000_000_000)) == window)
        #expect(window.revealing(ns(2_000_000_000)) == window)
        #expect(window.revealing(ns(6_000_000_000)) == window)
    }

    /// Revealing something outside moves as little as possible — the time lands on the edge it
    /// was past, not in the middle.
    @Test func revealingMovesTheLeastItCan() {
        let window = TimelineWindow(total: tenSeconds, start: ns(4_000_000_000),
                                    visible: ns(2_000_000_000))
        #expect(window.revealing(ns(1_000_000_000)).start == ns(1_000_000_000))
        #expect(window.revealing(ns(9_000_000_000)).end == ns(9_000_000_000))
    }

    /// A recording of no length is a real state — the strip is laid out before the asset
    /// loads — and must not divide by zero.
    @Test func aZeroLengthRecordingDoesNotDivideByZero() {
        let window = TimelineWindow.whole(ns(0))
        #expect(window.fraction(of: ns(0)).isFinite)
        #expect(window.position(atFraction: 0.5) == ns(0))
        #expect(window.magnification == 1)
    }
}
