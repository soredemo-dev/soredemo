import AppKit
import Testing
@testable import Soredemo

/// How large the editor opens, decided without a screen.
@Suite struct WindowSizeFloorTests {
    private let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)

    /// **Points, compared with a tolerance, because these are derived floating-point values.**
    /// `982 * 0.92` computed by the compiler and `982 * 0.92` computed at runtime differ in the
    /// last bit, and an exact comparison failed while printing "903.44 == 903.44" — a failure
    /// message that says nothing, about a difference nobody could act on. A thousandth of a
    /// point is finer than any screen, so this is the same claim stated in a unit that exists.
    private func isSame(_ lhs: CGFloat?, _ rhs: CGFloat) -> Bool {
        guard let lhs else { return false }
        return abs(lhs - rhs) < 0.001
    }

    /// **Grows, never shrinks.** Somebody who made their window larger keeps it; that is the
    /// trade the design note records, and a floor that also lowered would take it back.
    @Test @MainActor func aWindowLargerThanTheFloorIsLeftAlone() {
        let large = NSRect(x: 0, y: 0, width: 1500, height: 970)
        #expect(WindowSizeFloor.grownFrame(for: large, within: screen) == nil)
    }

    /// **Per axis.** A window somebody widened but left short gains the height and keeps the
    /// width — one rectangle for both axes would undo half of what they did.
    @Test @MainActor func awideButShortWindowKeepsItsWidth() {
        let wide = NSRect(x: 0, y: 0, width: 1500, height: 300)
        let grown = WindowSizeFloor.grownFrame(for: wide, within: screen)
        #expect(isSame(grown?.width, 1500), "width \(String(describing: grown?.width))")
        #expect(isSame(grown?.height, screen.height * WindowSizeFloor.openingFraction),
                "height \(String(describing: grown?.height)), wanted \(screen.height * 0.92)")
    }

    /// Centred on what it grows into. A window grown from its corner walks across the display
    /// every time the floor is applied, which on exit from full screen is every time.
    @Test @MainActor func aGrownWindowIsCentred() {
        let small = NSRect(x: 0, y: 0, width: 400, height: 300)
        let grown = try! #require(WindowSizeFloor.grownFrame(for: small, within: screen))
        #expect(abs(grown.midX - screen.midX) < 0.001)
        #expect(abs(grown.midY - screen.midY) < 0.001)
    }

    /// A screen that does not start at the origin — a second display — is grown within ITS
    /// bounds, not the main one's.
    @Test @MainActor func aWindowOnASecondDisplayGrowsWithinThatDisplay() {
        let second = NSRect(x: 1512, y: 0, width: 1920, height: 1080)
        let small = NSRect(x: 1600, y: 100, width: 400, height: 300)
        let grown = try! #require(WindowSizeFloor.grownFrame(for: small, within: second))
        #expect(grown.minX >= second.minX)
        #expect(grown.maxX <= second.maxX + 0.001)
    }

    /// Applying the floor to its own output changes nothing — it runs on every exit from full
    /// screen, so a floor that crept would grow the window a little each time.
    @Test @MainActor func applyingTheFloorTwiceChangesNothing() {
        let small = NSRect(x: 0, y: 0, width: 400, height: 300)
        let once = try! #require(WindowSizeFloor.grownFrame(for: small, within: screen))
        #expect(WindowSizeFloor.grownFrame(for: once, within: screen) == nil)
    }
}
