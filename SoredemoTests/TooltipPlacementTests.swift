import Testing
@testable import Soredemo

/// Where a tooltip goes when the button is at the edge of the screen.
///
/// **Tested because the failure is invisible where the code is written.** A bubble centred on
/// the leftmost button runs off the screen and is clipped, not moved — and nobody sees that
/// while the window is in the middle of a large display, which is where it always is while
/// somebody is working on it.
@Test @MainActor func aTooltipInTheMiddleIsNotMoved() {
    #expect(Tooltip.shift(centreX: 800, width: 260, screenX: 0, screenWidth: 1512) == 0)
}

/// The leftmost button in the editor toolbar is Undo, and it sits about 24pt from the edge.
@Test @MainActor func aTooltipAtTheLeftEdgeSlidesRightUntilItFits() {
    let shift = Tooltip.shift(centreX: 24, width: 260, screenX: 0, screenWidth: 1512)
    // Centred it would start at 24 - 130 = -106; it must start at the 8pt margin instead.
    #expect(shift == 114)
    #expect(24 - 260 / 2 + shift == 8)
}

/// The rightmost is the timeline's collapse chevron.
@Test @MainActor func aTooltipAtTheRightEdgeSlidesLeftUntilItFits() {
    let shift = Tooltip.shift(centreX: 1500, width: 260, screenX: 0, screenWidth: 1512)
    #expect(1500 + 260 / 2 + shift == 1512 - 8)
    #expect(shift < 0)
}

/// **A second display does not start at zero.** `NSScreen.visibleFrame` is in a global space,
/// so a window on a display to the right of the main one has coordinates well past its width —
/// clamping against `0..<width` would push every tooltip on that screen to the left edge of the
/// wrong one.
@Test @MainActor func aTooltipOnASecondDisplayClampsToThatDisplay() {
    let shift = Tooltip.shift(centreX: 1520, width: 260, screenX: 1512, screenWidth: 1920)
    #expect(1520 - 260 / 2 + shift == 1512 + 8)
}

/// A bubble wider than the screen cannot fit; it is pinned to the left margin rather than
/// jumping between the two clamps.
@Test @MainActor func aBubbleWiderThanTheScreenIsPinnedToTheLeft() {
    let shift = Tooltip.shift(centreX: 200, width: 600, screenX: 0, screenWidth: 400)
    #expect(200 - 600 / 2 + shift == 8)
}

/// **The canvas bar is the top row of the window.** A bubble drawn upward from it lands on the
/// title bar, where the window clips it — and a clipped tooltip looks exactly like no tooltip,
/// which is the complaint this whole file exists to answer.
@Test @MainActor func aTooltipOnTheTopRowGoesUnderneath() {
    #expect(Tooltip.placesBelow(top: 4, windowTop: 0))
    #expect(Tooltip.placesBelow(top: 31, windowTop: 0))
}

@Test @MainActor func aTooltipWithRoomAboveStaysAbove() {
    #expect(!Tooltip.placesBelow(top: 400, windowTop: 0))
    #expect(!Tooltip.placesBelow(top: 32, windowTop: 0))
}
