import Foundation
import Geometry
import Testing
@testable import Capture

/// **Which display a window or a dragged region belongs to — one rule, three callers.** It was
/// written three times until 2026-09-28, with three different answers when a rectangle's centre
/// sat on no display: the picker fell back to any overlapping display, pointing at a window fell
/// back to the FIRST display (whichever that was, overlapping or not), and a dragged region gave
/// up.
///
/// The arrangement is two displays of different heights with the second at a non-zero origin,
/// so neither the translation nor the vertical offset between them can be skipped and pass.
/// Global top-left points, as `SCDisplay.frame` and `CGEvent` report them.
private let builtIn = PointRect(x: 0, y: 0, width: 1512, height: 982)
private let external = PointRect(x: 1512, y: -200, width: 2560, height: 1440)
private let arrangement = [builtIn, external]

@Suite struct DisplayHostTests {
    @Test func aWindowBelongsToTheDisplayItsCentreIsOn() {
        // Centre (2300, 400) — on the external display, which is listed second.
        let window = PointRect(x: 2000, y: 100, width: 600, height: 600)
        #expect(DisplayHost.index(for: window, among: arrangement) == 1)
    }

    /// Straddling both: the centre decides, not the order the displays are listed in and not
    /// which one it touches first.
    @Test func aStraddlingWindowBelongsToTheDisplayShowingMostOfIt() {
        // x 1300…2100: 212 points on the built-in, 588 on the external; centre 1700.
        let window = PointRect(x: 1300, y: 300, width: 800, height: 400)
        #expect(DisplayHost.index(for: window, among: arrangement) == 1)
    }

    /// Centre past every edge — here below the built-in display, where the external one does
    /// not reach because it is offset upward. The window still overlaps the built-in, so it
    /// belongs there rather than to nothing, and rather than to whichever display is first.
    @Test func aCentreOnNoDisplayFallsBackToADisplayItOverlaps() {
        let window = PointRect(x: 1600, y: 1100, width: 800, height: 300)   // centre (2000, 1250): nothing
        #expect(DisplayHost.index(for: window, among: arrangement) == 1)
        let low = PointRect(x: 200, y: 900, width: 400, height: 400)        // centre (400, 1100): nothing
        #expect(DisplayHost.index(for: low, among: arrangement) == 0)
    }

    /// Nowhere at all — a monitor unplugged between the pick and the click. `nil`, never "the
    /// first display", which is a recording of a screen the window was never on.
    @Test func aRectangleOnNoDisplayBelongsToNone() {
        let gone = PointRect(x: 5000, y: 5000, width: 300, height: 200)
        #expect(DisplayHost.index(for: gone, among: arrangement) == nil)
        #expect(DisplayHost.index(for: gone, among: []) == nil)
    }

    /// The display's right and bottom edges are not inside it — a centre exactly on the seam
    /// between two displays belongs to the one that starts there.
    @Test func aCentreOnTheSeamBelongsToTheDisplayThatStartsThere() {
        let window = PointRect(x: 1412, y: 300, width: 200, height: 200)    // centre x = 1512
        #expect(DisplayHost.index(for: window, among: arrangement) == 1)
    }
}
