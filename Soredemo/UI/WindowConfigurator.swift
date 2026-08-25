import AppKit
import SwiftUI

/// Reaches the editor's `NSWindow` to set what SwiftUI has no modifier for.
///
/// **Full screen is a collection behaviour, not a style mask.** A window only offers "Enter Full
/// Screen" from its green button when `.fullScreenPrimary` is set; without it the button shows a
/// "+" and a tiling menu, and the Window menu has no "Enter Full Screen" item at all.
///
/// **`.moveToActiveSpace` too.** This app is a menu bar item that opens an editor: a person who
/// finished a recording on one Space and switched to another should get the editor where they
/// are, not be thrown back to where they started. The two flags coexist — measured, because the
/// obvious suspicion when full screen does not appear is that they conflict, and they do not:
/// setting both leaves `collectionBehavior.rawValue == 130`, which is `128 | 2`.
///
/// **Applied on attach and re-applied on every update, which is the repair.** The first version
/// read `view.window` once from a `DispatchQueue.main.async` in `makeNSView` and returned
/// silently when it was `nil` — a one-shot with a `guard` and nothing to retry it. The editor's
/// scene is `.defaultLaunchBehavior(.suppressed)` and comes up through `openWindow(id:)`, so the
/// view can exist before its window does, and a miss was permanent and invisible. `NSView` has
/// the exact hook for this — `viewDidMoveToWindow` fires when the view GETS a window, however
/// late — and `updateNSView` re-asserts afterwards, so a later reset by anything else is undone
/// on the next SwiftUI update rather than lasting for the session.
///
/// Measured while repairing it: the one-shot pattern works in an isolated SwiftUI `Window`
/// scene and holds (`fullScreenPrimary=true` at 0 ms, 800 ms and 2 s), so the mechanism was
/// never wrong — only its timing, and only in this app's shape.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> AttachedView { AttachedView() }

    func updateNSView(_ view: AttachedView, context: Context) { view.configure() }

    /// A view that knows when it has a window. `internal` rather than private because
    /// `NSViewRepresentable`'s associated type is this type, and Swift will not let a
    /// public-facing conformance name a private one.
    final class AttachedView: NSView {
        private var sized = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configure()
        }

        func configure() {
            guard let window else { return }
            // **The yellow button, which this window did not have.** A `Window` scene comes up
            // without `.miniaturizable`, so the middle traffic light was drawn and dead — and an
            // editor holding a recording is exactly the window somebody wants out of the way for
            // a minute without closing it and being asked about unsaved work.
            window.styleMask.insert(.miniaturizable)
            // Full screen additionally requires a resizable window; a green button on a fixed
            // window offers nothing whatever the collection behaviour says.
            window.styleMask.insert(.resizable)
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.collectionBehavior.insert(.moveToActiveSpace)

            guard !sized else { return }
            sized = true
            Self.sizeToScreen(window)
        }

        /// **A share of whatever screen this window is on, never a fixed size.** Every display
        /// is a different size and a number chosen on one machine is wrong on all the others: a
        /// 1440×900 default is most of a 14" laptop and a postage stamp on a 6K display. The
        /// fraction is of `visibleFrame`, which already excludes the menu bar and the Dock, so
        /// "80%" means 80% of the room the person actually has.
        ///
        /// Only on the FIRST attach: a window a person has resized is theirs, and re-imposing a
        /// size every time SwiftUI updates would undo their drag. Centred afterwards from the
        /// frame the window settled at rather than the one asked for, because the content's own
        /// minimum (`ContentView`'s 640 × 460) can push a small screen's 80% back up, and
        /// centring the requested size would then sit it off-centre.
        static let screenFraction: Double = 0.8

        static func sizeToScreen(_ window: NSWindow) {
            guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame,
                  visible.width > 0, visible.height > 0 else { return }
            let wanted = NSSize(width: visible.width * screenFraction,
                                height: visible.height * screenFraction)
            window.setContentSize(wanted)
            let settled = window.frame.size
            window.setFrameOrigin(NSPoint(x: visible.midX - settled.width / 2,
                                          y: visible.midY - settled.height / 2))
        }
    }
}
