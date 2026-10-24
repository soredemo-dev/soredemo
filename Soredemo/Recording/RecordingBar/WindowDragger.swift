import AppKit

/// Moves the bar's window while somebody drags it.
///
/// **The bar was never draggable and nothing said so.** `isMovableByWindowBackground` is set on
/// the panel and does not survive an `NSHostingView`: measured with synthesised events, the
/// same panel moved 88 points with a plain `NSView` in it and did not move at all with SwiftUI
/// in it. Two earlier repairs were measured and rejected — an `NSView` behind the content
/// answering `mouseDownCanMoveWindow`, and the same view inside a `ZStack`; neither moved the
/// window either. What works is doing the move ourselves, and the button beside it still fires.
@MainActor
final class WindowDragger {
    /// Weak: the panel owns this, and this must not own the panel back.
    weak var window: NSWindow?
    private var drag = WindowDrag()
    /// How many changes the gesture has delivered. **`--show-recording-bar` prints it**, because
    /// "the bar did not move" has two causes that look identical from outside: the gesture never
    /// fired, or it fired and the move did not take. One number separates them.
    private(set) var moves = 0

    /// One change of the gesture.
    ///
    /// **The pointer is read from the system, not from the gesture.** `DragGesture` reports a
    /// translation inside a coordinate space that belongs to the window being moved, so a
    /// window moved by it stops after one frame. See `WindowDrag`.
    func moved() {
        moves += 1
        guard let window else { return }
        let pointer = NSEvent.mouseLocation
        let origin = drag.origin(pointerX: Double(pointer.x), pointerY: Double(pointer.y),
                                 windowX: Double(window.frame.minX),
                                 windowY: Double(window.frame.minY))
        window.setFrameOrigin(NSPoint(x: origin.x, y: origin.y))
    }

    func ended() { drag.end() }
}
