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

@Suite struct WindowDragTests {

    /// **Touching the bar must not move it.** The first change of a gesture arrives with the
    /// pointer already somewhere inside the window, and an implementation that treated the
    /// pointer as the new origin would snap the window's corner to the cursor.
    @Test @MainActor func thefirstChangeLeavesTheWindowWhereItIs() {
        var drag = WindowDrag()
        let origin = drag.origin(pointerX: 640, pointerY: 300, windowX: 500, windowY: 280)
        #expect(origin.x == 500)
        #expect(origin.y == 280)
    }

    /// The window follows the pointer one for one after that.
    @Test @MainActor func theWindowMovesWithThePointer() {
        var drag = WindowDrag()
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
        var drag = WindowDrag()
        _ = drag.origin(pointerX: 640, pointerY: 300, windowX: 500, windowY: 280)
        // The window is now where the last change put it, and the pointer has moved on.
        let moved = drag.origin(pointerX: 660, pointerY: 300, windowX: 500, windowY: 280)
        #expect(moved.x == 520, "the grab offset was recomputed; the bar would not move")
    }

    /// A new gesture takes its own grab — otherwise the bar would leap by the distance between
    /// where the last drag ended and where the next one starts.
    @Test @MainActor func endingAGestureReleasesTheGrab() {
        var drag = WindowDrag()
        _ = drag.origin(pointerX: 640, pointerY: 300, windowX: 500, windowY: 280)
        #expect(drag.isDragging)
        drag.end()
        #expect(!drag.isDragging)
        let second = drag.origin(pointerX: 900, pointerY: 100, windowX: 560, windowY: 240)
        #expect(second.x == 560, "the second gesture reused the first one's grab")
        #expect(second.y == 240)
    }

    /// **The drift, as an assertion.** The camera self-view moved its window by `now - last`
    /// and then set `last = now`. Adding deltas equals following the pointer only while every
    /// delta can be honoured, and a window clamped to the screen's edge cannot honour them: the
    /// refused part is dropped while `last` advances anyway, so the pointer and the picture come
    /// apart by that much and stay apart. Reported as the camera drifting further and further
    /// from the cursor.
    ///
    /// Here the window is reported as CLAMPED — stuck at 0 — for several changes, and then the
    /// pointer comes back. An offset taken once re-aligns; a sum of deltas does not.
    @Test @MainActor func aClampedWindowRealignsWhenThereIsRoomAgain() {
        var drag = WindowDrag()
        // Grab 40 points in from the window's left edge.
        _ = drag.origin(pointerX: 140, pointerY: 300, windowX: 100, windowY: 280)
        // Pushed left, into the edge. The window reports 0 each time because it is clamped.
        for pointer in stride(from: 120.0, through: 20.0, by: -20.0) {
            _ = drag.origin(pointerX: pointer, pointerY: 300, windowX: 0, windowY: 280)
        }
        // Back to where the grab started. The window must be back where it started too.
        let back = drag.origin(pointerX: 140, pointerY: 300, windowX: 0, windowY: 280)
        #expect(back.x == 100, "the grab drifted; the window came back to \(back.x), not 100")
        #expect(back.y == 280)
    }

    /// **Grabbing the exact bottom-left corner is a grab, not the absence of one.** A zero
    /// offset stored as "nothing yet" would be re-taken on every change and the bar would sit
    /// still — the one case where a sentinel and a real value collide.
    @Test @MainActor func grabbingTheCornerIsARealGrab() {
        var drag = WindowDrag()
        _ = drag.origin(pointerX: 500, pointerY: 280, windowX: 500, windowY: 280)
        #expect(drag.isDragging)
        let moved = drag.origin(pointerX: 560, pointerY: 300, windowX: 500, windowY: 280)
        #expect(moved.x == 560)
        #expect(moved.y == 300)
    }
}
