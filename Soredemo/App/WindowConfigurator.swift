import AppKit
import SwiftUI

/// Reaches the editor's `NSWindow` to set what SwiftUI has no modifier for.
///
/// **This type coordinates; it decides nothing.** Each decision lives with the thing it is
/// about — `EditorWindowStyle` for what the window is, `WindowSizeFloor` for how large it
/// opens, `FullScreenEntry` for getting it full screen, `WindowObservers` for what has been
/// registered. They were one type until 2026-09-15, and the cost was measured: a full-screen
/// defect took four attempts to find because the decision was spread across three places and
/// none of them could state the order the others ran in.
///
/// Why `LSUIElement` is still in the Info.plist, and every measurement behind the full-screen
/// behaviour: `docs/design/full-screen-and-window-behaviour.md`.
struct WindowConfigurator: NSViewRepresentable {
    /// Whether the editor enters full screen when it opens. The switch, so that turning it off
    /// is one word rather than an excavation.
    static let opensFullScreen = true

    func makeNSView(context: Context) -> AttachedView { AttachedView() }

    func updateNSView(_ view: AttachedView, context: Context) { view.configure() }

    /// A view that knows when it has a window. `internal` rather than private because
    /// `NSViewRepresentable`'s associated type is this type, and Swift will not let a
    /// public-facing conformance name a private one.
    final class AttachedView: NSView {
        private let observers = WindowObservers()
        /// Whether this window has completed a full-screen transition, which is what decides
        /// `.moveToActiveSpace` — see `EditorWindowStyle.collectionBehavior`.
        private var hasBeenFullScreen = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // **Leaving a window is where the observers go.** It is the moment they stop being
            // about anything, it runs when the editor is closed, and it is only reachable
            // because the blocks hold the window weakly.
            guard window != nil else { return observers.removeAll() }
            configure()
        }

        func configure() {
            guard let window else { return }
            // Idempotent, so it runs on every SwiftUI update — which is what makes it survive
            // SwiftUI re-asserting what it owns.
            EditorWindowStyle.apply(to: window, hasBeenFullScreen: hasBeenFullScreen)

            // Registration is not idempotent, and registering twice is the defect.
            guard !observers.alreadyRegistered(for: window) else { return }
            observers.adopt(openFullScreen(window) + keepUsablyLarge(window)
                            + watchFullScreen(window),
                            for: window)
        }

        /// In full screen the toolbar gets out of the way and comes back when you reach for it.
        ///
        /// Presentation options set on the notification rather than through a window delegate —
        /// SwiftUI owns this window's delegate — and all four together, because an incomplete
        /// set is an AppKit exception rather than a partial effect.
        private func watchFullScreen(_ window: NSWindow) -> [any NSObjectProtocol] {
            let centre = NotificationCenter.default
            return [
                centre.addObserver(forName: NSWindow.didEnterFullScreenNotification,
                                   object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.hasBeenFullScreen = true
                        NSApp.presentationOptions = [.autoHideToolbar, .autoHideMenuBar,
                                                     .autoHideDock, .fullScreen]
                    }
                },
                centre.addObserver(forName: NSWindow.didExitFullScreenNotification,
                                   object: window, queue: .main) { [] _ in
                    // Back to the system's own, so leaving full screen does not leave the menu
                    // bar hiding over an ordinary desktop.
                    MainActor.assumeIsolated { NSApp.presentationOptions = [] }
                },
            ]
        }
    }
}

/// Applies the size floor whenever the window leaves full screen.
///
/// On every exit rather than once: a flag is spent by things that are not a person's decision,
/// and AppKit restores whatever was autosaved — which has already been a frame smaller than
/// this window's own minimum.
@MainActor private func keepUsablyLarge(_ window: NSWindow) -> [any NSObjectProtocol] {
    [NotificationCenter.default.addObserver(
        forName: NSWindow.didExitFullScreenNotification, object: window,
        queue: .main) { [weak window] _ in
            MainActor.assumeIsolated {
                guard let window,
                      let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
                WindowSizeFloor.grow(window, within: visible)
            }
        }]
}

/// Takes the editor full screen the first time its window becomes key.
///
/// **After the window has become key, not at `makeNSView`**: AppKit restores an autosaved frame
/// after the hierarchy is assembled, so a frame set earlier is one the restore overwrites.
@MainActor private func openFullScreen(_ window: NSWindow) -> [any NSObjectProtocol] {
    let token = ObserverToken()
    token.value = NotificationCenter.default.addObserver(
        forName: NSWindow.didBecomeKeyNotification, object: window,
        queue: .main) { [weak window] _ in
            // `queue: .main` is the guarantee this rests on: the notification centre delivers
            // this block on the main queue, so it really is main-actor work.
            MainActor.assumeIsolated {
                token.remove()
                guard let window,
                      let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
                guard WindowConfigurator.opensFullScreen,
                      !window.styleMask.contains(.fullScreen) else {
                    // Not going full screen — either it is off or the window is already there —
                    // so this is the only moment the floor gets applied on the way in.
                    WindowSizeFloor.grow(window, within: visible)
                    return
                }
                // **Full size first, then the toggle.** AppKit paints at the autosaved size
                // before `didBecomeKey`, so the transition would otherwise zoom out of a small
                // window somebody has already seen.
                //
                // `chosen` is kept because AppKit restores the pre-full-screen frame on exit,
                // and that frame is about to become the whole screen.
                let chosen = window.frame
                restoreFrameOnExit(chosen, of: window)
                window.setFrame(visible, display: false, animate: false)
                FullScreenEntry.enter(window)
            }
        }
    // Returned so the view can drop it if the window goes before it ever became key; the block
    // removes it itself on the ordinary path.
    return token.value.map { [$0] } ?? []
}

/// Puts back the size somebody had chosen, the first time this window leaves full screen.
///
/// **Its own one-shot**, because it is about this entry into full screen and the frame that was
/// current when it happened. Left registered it would put an old frame back on every later exit.
@MainActor private func restoreFrameOnExit(_ frame: NSRect, of window: NSWindow) {
    let token = ObserverToken()
    token.value = NotificationCenter.default.addObserver(
        forName: NSWindow.didExitFullScreenNotification, object: window,
        queue: .main) { [weak window] _ in
            MainActor.assumeIsolated {
                token.remove()
                guard let window else { return }
                window.setFrame(frame, display: true, animate: false)
                if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
                    WindowSizeFloor.grow(window, within: visible)
                }
            }
        }
}
