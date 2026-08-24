import Testing
@testable import Geometry

/// Adjusting the region after it has been drawn.
@Suite struct RegionGestureTests {
    private static let screen = PointRect(x: 0, y: 0, width: 1512, height: 982)

    /// **Corners before edges**, because a corner is on two edges and somebody aiming at one
    /// means the corner. The bug this stops is the one every crop tool has had at least once:
    /// a corner that resizes in one direction only.
    @Test func acornerWinsOverTheTwoEdgesItSitsOn() {
        let edge = RegionEdge.grabbed(atX: 100, y: 100, boxX: 100, boxY: 100,
                                      width: 300, height: 200, reach: 14)
        #expect(edge == .topLeading)
        let side = RegionEdge.grabbed(atX: 100, y: 200, boxX: 100, boxY: 100,
                                      width: 300, height: 200, reach: 14)
        #expect(side == .leading)
    }

    /// A point well inside the rectangle grabs nothing — that is what makes it a move rather
    /// than a resize.
    @Test func theMiddleOfTheRectangleGrabsNoEdge() {
        #expect(RegionEdge.grabbed(atX: 250, y: 200, boxX: 100, boxY: 100,
                                   width: 300, height: 200, reach: 14) == nil)
        // And so does a point outside its reach entirely.
        #expect(RegionEdge.grabbed(atX: 20, y: 20, boxX: 100, boxY: 100,
                                   width: 300, height: 200, reach: 14) == nil)
    }

    /// **Dragging an edge past its opposite flips rather than producing a negative size.** A
    /// `PointRect` with a negative width traps on construction, so this is not a tidiness rule —
    /// it is the difference between a rectangle and a crash.
    @Test func pullingAnEdgePastItsOppositeFlipsTheRectangle() {
        let rect = PointRect(x: 100, y: 100, width: 300, height: 200)
        let flipped = RegionEdge.leading.resized(rect, toX: 600, y: 150)
        #expect(flipped.x == 400 && flipped.width == 200)
        #expect(flipped.width > 0 && flipped.height > 0)
    }

    /// **Moved by the difference, not to the pointer.** Snapping the rectangle's origin to the
    /// cursor would jump it the moment a drag began anywhere but its top-left corner.
    @Test func movingKeepsTheGrabPointUnderTheCursor() {
        let from = PointRect(x: 100, y: 100, width: 300, height: 200)
        let gesture = RegionGesture.moving(from: from, grabX: 250, grabY: 200)
        let moved = gesture.applied(toX: 300, y: 260, screenFrame: Self.screen)
        // Grabbed 150 in and 100 down; the rectangle follows the delta, keeping that offset.
        #expect(abs(moved.x - 150) < 0.001)
        #expect(abs(moved.y - 160) < 0.001)
        #expect(moved.width == 300 && moved.height == 200)
    }

    /// Drawing normalises, so a drag up and to the left is the same rectangle as one down and to
    /// the right.
    @Test func drawingInAnyDirectionGivesAPositiveRectangle() {
        let gesture = RegionGesture.drawing(originX: 400, originY: 300)
        let backwards = gesture.applied(toX: 100, y: 100, screenFrame: Self.screen)
        #expect(backwards.x == 100 && backwards.y == 100)
        #expect(backwards.width == 300 && backwards.height == 200)
    }
}
