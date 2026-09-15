import AppKit

/// How large an editor window opens, and how large it is put back.
///
/// **One reason to change: what "big enough to work in" means.** A property rather than an
/// event, and the third design — two earlier one-shot flags were both spent by things that
/// were not a person's decision. It grows a window under the fraction and never shrinks one
/// over it, so somebody who made theirs larger keeps it, and somebody who made it deliberately
/// small does not. That trade is recorded in the design note.
@MainActor
enum WindowSizeFloor {
    /// Most of the screen, with enough left over that the window still reads as a window and
    /// whatever is behind it can still be grabbed. **Uncalibrated.**
    static let openingFraction: Double = 0.92

    /// The frame a window should be given, or `nil` when it is already large enough.
    ///
    /// **Pure, so the arithmetic can be tested without a screen.** Per axis and only upward: a
    /// window somebody widened but left short gains the height and keeps the width. Centred on
    /// what it grows into, because a window grown from a corner walks across the display.
    static func grownFrame(for current: NSRect, within visible: NSRect,
                           fraction: Double = openingFraction) -> NSRect? {
        let wantedWidth = visible.width * fraction
        let wantedHeight = visible.height * fraction
        let width = max(current.width, wantedWidth)
        let height = max(current.height, wantedHeight)
        guard width > current.width || height > current.height else { return nil }
        return NSRect(x: visible.minX + (visible.width - width) / 2,
                      y: visible.minY + (visible.height - height) / 2,
                      width: width, height: height)
    }

    /// Grows `window` if it is under the floor. `display: false` because every caller either
    /// follows this with a transition that repaints anyway or is running inside one.
    static func grow(_ window: NSWindow, within visible: NSRect) {
        guard let frame = grownFrame(for: window.frame, within: visible) else { return }
        window.setFrame(frame, display: false, animate: false)
    }
}
