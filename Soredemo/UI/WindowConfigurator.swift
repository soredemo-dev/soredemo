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
/// `Window` scene is none of those three things' size — it is whatever the content asks for,
/// which here is small enough that the timeline has no length and the inspector crowds the
/// picture. Full screen is the other wrong answer: this is a window somebody moves between, and
/// a recording is often of the thing beside it.
///
/// **Tracked by a key this app owns, because SwiftUI's is not guessable.** The first version
/// guarded on `NSWindow Frame editor` — the scene's own identifier — and measured on a real
/// install there are TWO keys: that one, and
/// `NSWindow Frame SwiftUI.ModifiedContent<Soredemo.ContentView, SwiftUI._TaskModifier2>-1-AppWindow-1`,
/// which is generated from the view's TYPE and is the one the window actually restores from. A
/// guard on the wrong key is a guard that never fires, which is what happened. A name generated
/// from a type is also one that changes when the view's modifiers change, so it is not something
/// to hard-code either — this asks a question about our own state instead.
///
/// **Once ever, not once per launch.** Someone who sizes this window has decided, and
/// overwriting that on every launch is the producer-value rule broken in the smallest possible
/// way — which this project has already done once, with the status item's position.
private func sizeGenerouslyOnFirstOpen(_ window: NSWindow) {
    // A floor regardless, so the editor cannot be restored or dragged into a size where the
    // timeline has no length. AppKit enforces it from here on.
    window.minSize = NSSize(width: 1000, height: 680)

    let key = "editorHasBeenSizedGenerously"
    guard !UserDefaults.standard.bool(forKey: key) else { return }
    UserDefaults.standard.set(true, forKey: key)

    // **After the window has become key, not here.** `makeNSView` runs while the hierarchy is
    // still being assembled, and AppKit restores an autosaved frame somewhere after that — a
    // frame set now is a frame the restore overwrites, silently, which looks exactly like the
    // code never ran. A window is fully placed by the time it is key.
    var token: (any NSObjectProtocol)?
    token = NotificationCenter.default.addObserver(
        forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { _ in
            if let token { NotificationCenter.default.removeObserver(token) }
            guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
            // Most of the screen, with enough left over that the window still reads as a window
            // and whatever is behind it can still be grabbed.
            let width = visible.width * 0.92
            let height = visible.height * 0.92
            window.setFrame(NSRect(x: visible.minX + (visible.width - width) / 2,
                                   y: visible.minY + (visible.height - height) / 2,
                                   width: width, height: height),
                            display: true, animate: true)
        }
}
