/// Where a window's origin must go while somebody drags it by its own background.
///
/// **The arithmetic is here, away from AppKit, because the defect it prevents is arithmetic.**
/// Two ways of moving a window under a drag look identical in a diff and only one of them
/// works, and the difference is which number the offset is taken from.
///
/// **Not SwiftUI's translation.** A `DragGesture` reports how far the pointer has moved inside
/// a coordinate space — and every space available here belongs to the window that is being
/// moved. Move the window by the translation and the pointer's position inside it barely
/// changes, so the next translation is near zero: the window jumps once and then follows
/// nothing. Measured before this existed, against a panel that would not move at all.
///
/// So the pointer is read in SCREEN coordinates, and what is remembered is where inside the
/// window it was grabbed. That offset is taken once and held for the whole gesture: recomputing
/// it per frame would make it equal to the pointer's current position every time and the window
/// would never move at all.
struct BarDrag: Equatable {
    /// Where inside the window the pointer went down, in screen units. `nil` between gestures
    /// rather than a zeroed point, which is a legal grab — a person can grab a window's exact
    /// bottom-left corner, and treating that as "no grab yet" would re-grab on every frame.
    private var grab: (x: Double, y: Double)?

    init() {}

    static func == (lhs: BarDrag, rhs: BarDrag) -> Bool {
        switch (lhs.grab, rhs.grab) {
        case (nil, nil): return true
        case let (l?, r?): return l == r
        default: return false
        }
    }

    /// The origin the window should take, given where the pointer is now and where the window
    /// is now.
    ///
    /// **The first call of a gesture returns the window's current origin unchanged**, which is
    /// what stops the bar jumping out from under the pointer the moment it is touched.
    mutating func origin(pointerX: Double, pointerY: Double,
                         windowX: Double, windowY: Double) -> (x: Double, y: Double) {
        let held = grab ?? (x: pointerX - windowX, y: pointerY - windowY)
        grab = held
        return (x: pointerX - held.x, y: pointerY - held.y)
    }

    /// The gesture is over. The next one takes its own grab.
    mutating func end() { grab = nil }

    /// Whether a gesture is in progress. For a test that has to say the grab was released.
    var isDragging: Bool { grab != nil }
}
