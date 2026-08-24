import AppKit
import SwiftUI

/// Reaches the editor's `NSWindow` to set what SwiftUI has no modifier for.
///
/// **Full screen is a collection behaviour, not a style mask.** A window only offers "Enter Full
/// Screen" from its green button when `.fullScreenPrimary` is set; without it the button shows
/// the tiling menu and nothing else. SwiftUI's `Window` scene does not expose it, so this
/// zero-sized view finds the window it is in and sets it.
///
/// **`.moveToActiveSpace` too.** This app is a menu bar item that opens an editor: a person who
/// finished a recording on one Space and switched to another should get the editor where they
/// are, not be thrown back to where they started.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // `async` because the view is not in a window yet during `makeNSView` — the hierarchy is
        // assembled after. Reading `view.window` here returns nil, every time.
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            // **The yellow button, which this window did not have.** A `Window` scene comes up
            // without `.miniaturizable`, so the middle traffic light was drawn and dead — and an
            // editor holding a recording is exactly the window somebody wants out of the way for
            // a minute without closing it and being asked about unsaved work.
            window.styleMask.insert(.miniaturizable)
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.collectionBehavior.insert(.moveToActiveSpace)
            sizeGenerouslyOnFirstOpen(window)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// The editor's size the first time it is ever opened.
///
/// **An editor is a preview, a timeline and an inspector at once**, and SwiftUI's default for a
/// `Window` scene is neither of those three things' size — it is whatever the content asks for,
/// which here is small enough that the timeline has no length and the inspector crowds the
/// picture. Full screen is the other wrong answer: this is a window somebody moves between and
/// a recording is often of the thing beside it.
///
/// **Only when there is no remembered frame.** `NSWindow` autosaves the editor's frame under
/// `NSWindow Frame editor`, and a person who has sized this window has decided — overwriting
/// that on every launch is the producer-value rule broken in the smallest possible way, which
/// this project has already made once with the status item's position.
private func sizeGenerouslyOnFirstOpen(_ window: NSWindow) {
    // **The literal, not `SoredemoApp.editorWindowID`.** This file is compiled by
    // `scripts/run-cross-boundary-probe.sh` and `SoredemoApp.swift` deliberately is not — naming
    // the type here would drag the app's whole lifecycle into a probe that exists to compile the
    // boundary. The same argument `SoredemoAppDelegate` already carries for its closures.
    let key = "NSWindow Frame editor"
    guard UserDefaults.standard.object(forKey: key) == nil,
          let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
    // Most of the screen, with enough left over that the window still reads as a window and
    // whatever is behind it can still be grabbed.
    let width = visible.width * 0.92
    let height = visible.height * 0.92
    window.setFrame(NSRect(x: visible.minX + (visible.width - width) / 2,
                           y: visible.minY + (visible.height - height) / 2,
                           width: width, height: height),
                    display: true)
}
