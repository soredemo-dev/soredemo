import Testing
@testable import Soredemo

// Moving the recording bar by dragging it.
//
// **The bar could not be dragged at all, and the measurement that found it had to be built
// twice.** `isMovableByWindowBackground` does not survive an `NSHostingView`: driven with
// synthesised events, a panel with a plain `NSView` in it moved 88 points and the identical
// panel with SwiftUI in it did not move at all. The first version of that probe reported "did
// not move" for BOTH — it pumped the run loop directly, which never calls
// `NSApplication.sendEvent`, so no event ever reached either window. A negative reading with no
// positive control beside it is not a reading.
//
// What is left to get wrong is the arithmetic, which is what these cover.

@Suite struct BarDragTests {

    /// **Touching the bar must not move it.** The first change of a gesture arrives with the
    /// pointer already somewhere inside the window, and an implementation that treated the
    /// pointer as the new origin would snap the window's corner to the cursor.
    @Test @MainActor func thefirstChangeLeavesTheWindowWhereItIs() {
        var drag = BarDrag()
        let origin = drag.origin(pointerX: 640, pointerY: 300, windowX: 500, windowY: 280)
        #expect(origin.x == 500)
        #expect(origin.y == 280)
    }

    /// The window follows the pointer one for one after that.
    @Test @MainActor func theWindowMovesWithThePointer() {
        var drag = BarDrag()
        _ = drag.origin(pointerX: 640, pointerY: 300, windowX: 500, windowY: 280)
        let moved = drag.origin(pointerX: 700, pointerY: 260, windowX: 500, windowY: 280)
        #expect(moved.x == 560)
        #expect(moved.y == 240)
    }

    /// **The grab is taken ONCE, and this is the assertion that says so.** Recomputing it from
    /// the window's current position on every change makes the offset equal to the pointer's
    /// current position every time, and the window never moves — which is indistinguishable in
    /// a diff from the correct version. Here the window is reported as having already followed,
    /// which is what really happens between two frames of a drag.
    @Test @MainActor func theGrabSurvivesTheWindowHavingAlreadyMoved() {
        var drag = BarDrag()
        _ = drag.origin(pointerX: 640, pointerY: 300, windowX: 500, windowY: 280)
        // The window is now where the last change put it, and the pointer has moved on.
        let moved = drag.origin(pointerX: 660, pointerY: 300, windowX: 500, windowY: 280)
        #expect(moved.x == 520, "the grab offset was recomputed; the bar would not move")
    }

    /// A new gesture takes its own grab — otherwise the bar would leap by the distance between
    /// where the last drag ended and where the next one starts.
    @Test @MainActor func endingAGestureReleasesTheGrab() {
        var drag = BarDrag()
        _ = drag.origin(pointerX: 640, pointerY: 300, windowX: 500, windowY: 280)
        #expect(drag.isDragging)
        drag.end()
        #expect(!drag.isDragging)
        let second = drag.origin(pointerX: 900, pointerY: 100, windowX: 560, windowY: 240)
        #expect(second.x == 560, "the second gesture reused the first one's grab")
        #expect(second.y == 240)
    }

    /// **Grabbing the exact bottom-left corner is a grab, not the absence of one.** A zero
    /// offset stored as "nothing yet" would be re-taken on every change and the bar would sit
    /// still — the one case where a sentinel and a real value collide.
    @Test @MainActor func grabbingTheCornerIsARealGrab() {
        var drag = BarDrag()
        _ = drag.origin(pointerX: 500, pointerY: 280, windowX: 500, windowY: 280)
        #expect(drag.isDragging)
        let moved = drag.origin(pointerX: 560, pointerY: 300, windowX: 500, windowY: 280)
        #expect(moved.x == 560)
        #expect(moved.y == 300)
    }
}
