import AppKit
import SwiftUI

/// Reaches the editor's `NSWindow` to set what SwiftUI has no modifier for.
///
/// Sets `.fullScreenPrimary` — without it the green button offers tiling rather than full screen
/// — and `.moveToActiveSpace`, so an editor opened after switching Spaces arrives where the
/// person is. The two coexist; `collectionBehavior.rawValue` is 130.
///
/// **Applied on attach AND on every update.** `viewDidMoveToWindow` fires when the view gets a
/// window, however late; `updateNSView` re-asserts so a later reset is undone on the next SwiftUI
/// update rather than lasting for the session.
///
/// See `docs/design/full-screen-and-window-behaviour.md` for what was measured — including the
/// folklore that an accessory app's windows cannot go full screen, which is false on this system.
struct WindowConfigurator: NSViewRepresentable {
    /// Most of the screen, with enough left over that the window still reads as a window and
    /// whatever is behind it can still be grabbed. **Uncalibrated.**
    static let openingFraction: Double = 0.92
    /// Whether the editor enters full screen when it opens. See the `toggleFullScreen` call for
    /// what it costs; this is the switch, so that turning it off is one word rather than an
    /// excavation.
    static let opensFullScreen = true

    func makeNSView(context: Context) -> AttachedView { AttachedView() }

    func updateNSView(_ view: AttachedView, context: Context) { view.configure() }

    /// A view that knows when it has a window. `internal` rather than private because
    /// `NSViewRepresentable`'s associated type is this type, and Swift will not let a
    /// public-facing conformance name a private one.
    final class AttachedView: NSView {
        /// The window this view has already registered for, if any.
        ///
        /// **`configure()` runs on every SwiftUI update, and only ONE of the three registrations
        /// below used to be guarded.** The comment that guarded it said exactly why — a second
        /// registration sets the presentation options twice — and the other two were left open,
        /// so an editor accumulated one `didExitFullScreen` observer and one `didBecomeKey`
        /// observer per update. Both consequences are real:
        ///
        /// * every one of those `didBecomeKey` observers fires on the SAME notification, so
        ///   `toggleFullScreen` was called once per registration. Two calls is enter-then-exit,
        ///   which is an editor that opens windowed for no reason anybody can see;
        /// * the blocks captured `window` strongly and were never removed, so the window — with
        ///   its player, its compositor and its waveforms — could never be freed.
        ///
        /// Keyed on the window rather than a `Bool`, because a view can be moved to a different
        /// window and the old registration is then about a window this view no longer has.
        private var configuredWindow: ObjectIdentifier?
        /// What to unregister. Removed when this view goes away, which happens when the window
        /// does — and can only happen because the blocks hold the window weakly.
        private var tokens: [any NSObjectProtocol] = []



        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // **Leaving a window is where the observers go**, not `deinit`: a nonisolated
            // `deinit` may not touch a non-Sendable array, and this is the moment they stop
            // being about anything anyway. It is also the moment that runs when the editor is
            // closed, which is what the blocks holding the window weakly makes reachable.
            guard window != nil else {
                for token in tokens { NotificationCenter.default.removeObserver(token) }
                tokens = []
                configuredWindow = nil
                return
            }
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
            // Removed first: the two are mutually exclusive and `fullScreenNone`
            // wins. The scene no longer asks for a default size, which is what
            // actually fixed it; this is the second lock on the same door.
            window.collectionBehavior.remove(.fullScreenNone)
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.collectionBehavior.insert(.moveToActiveSpace)

            // Everything above is idempotent — setting a style mask bit twice is setting it
            // once. Everything below registers, and registering twice is the defect.
            guard configuredWindow != ObjectIdentifier(window) else { return }
            for token in tokens { NotificationCenter.default.removeObserver(token) }
            tokens = []
            configuredWindow = ObjectIdentifier(window)

            tokens += openFullScreen(window)
            tokens += keepUsablyLarge(window)
            tokens += watchFullScreen(window)
        }

        /// In full screen the toolbar gets out of the way and comes back when you
        /// reach for it.
        ///
        /// Presentation options set on the notification rather than through a window
        /// delegate — SwiftUI owns this window's delegate — and all four options
        /// together, because an incomplete set is an AppKit exception rather than a
        /// partial effect.
        private func watchFullScreen(_ window: NSWindow) -> [any NSObjectProtocol] {
            let centre = NotificationCenter.default
            return [
                // `[]` on purpose: this block mentions only `NSApp`, and an empty capture
                // list is how it says so. See `everyBlockObserverDeclaresWhatItCaptures`.
                centre.addObserver(forName: NSWindow.didEnterFullScreenNotification,
                                   object: window, queue: .main) { [] _ in
                    MainActor.assumeIsolated {
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

/// Grows `window` to at least `openingFraction` of `visible`, never shrinking it.
///
/// **Per axis, and only upward.** A window somebody widened but left short gains the height and
/// keeps the width. `display: false` because every caller either follows this with a transition
/// that repaints anyway or is running inside one.
private func growToFloor(_ window: NSWindow, within visible: NSRect) {
    let wanted = NSSize(width: visible.width * WindowConfigurator.openingFraction,
                        height: visible.height * WindowConfigurator.openingFraction)
    let width = max(window.frame.width, wanted.width)
    let height = max(window.frame.height, wanted.height)
    guard width > window.frame.width || height > window.frame.height else { return }
    window.setFrame(NSRect(x: visible.minX + (visible.width - width) / 2,
                           y: visible.minY + (visible.height - height) / 2,
                           width: width, height: height),
                    display: false, animate: false)
}

/// Applies the floor whenever the window leaves full screen — where it lives
/// now, because AppKit restores whatever was autosaved and that has already
/// once been a frame smaller than this window's own minimum.
///
/// On every exit rather than once: a flag is spent by things that are not a
/// person's decision.
private func keepUsablyLarge(_ window: NSWindow) -> [any NSObjectProtocol] {
    // **`[weak window]`, and that is what makes the removal reachable.** A block that holds the
    // window keeps it alive; the view that would remove this observer lives IN that window, so
    // its `deinit` never runs and the token is never removed. The strong capture was the whole
    // cycle.
    [NotificationCenter.default.addObserver(
        forName: NSWindow.didExitFullScreenNotification, object: window,
        queue: .main) { [weak window] _ in
            MainActor.assumeIsolated {
                guard let window,
                      let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
                growToFloor(window, within: visible)
            }
        }]
}

/// The editor goes full screen when it opens, and never OPENS smaller than
/// `openingFraction` of the screen it opens on.
///
/// A property rather than an event, and the third design: two earlier
/// one-shot flags were both spent by things that were not a person's
/// decision. It grows a window under the fraction and never shrinks one over
/// it, so somebody who made theirs larger keeps it — and somebody who made it
/// deliberately small does not, which is the trade the design doc records.
private func openFullScreen(_ window: NSWindow) -> [any NSObjectProtocol] {
    // A floor regardless, so the editor cannot be dragged into a size where the timeline has no
    // length. AppKit enforces it from here on — and note it did NOT stop a smaller frame being
    // restored from an autosave written under a different scene identity.
    window.minSize = NSSize(width: 1000, height: 680)

    // After the window has become key, not here: `makeNSView` runs while the
    // hierarchy is still being assembled, and AppKit restores an autosaved frame
    // after that — a frame set now is one the restore overwrites.
    //
    // The token lives in a reference rather than a captured `var` because a
    // `@Sendable` closure may not mutate a local, and it is the closure that has to
    // remove the observer. `@unchecked Sendable` is sound for `assumeIsolated`'s
    // reason: written on the main actor, read only from a closure delivered on
    // `.main`.
    let holder = ObserverHolder()
    holder.token = NotificationCenter.default.addObserver(
        forName: NSWindow.didBecomeKeyNotification, object: window,
        queue: .main) { [weak window] _ in
            // `queue: .main` is the guarantee this rests on: the notification centre delivers
            // this block on the main queue, so it really is main-actor work.
            MainActor.assumeIsolated {
                if let token = holder.token { NotificationCenter.default.removeObserver(token) }
                guard let window,
                      let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
                // Grows, never shrinks, each axis on its own — `growToFloor` computes the
                // wanted size; a second copy here was computed and thrown away.
                //
                // Straight to full screen with nothing painted on the way — growing
                // first and toggling after showed three visible states where a person
                // wants one. The floor is applied on EXIT instead, in `keepUsablyLarge`.
                guard WindowConfigurator.opensFullScreen,
                      !window.styleMask.contains(.fullScreen) else {
                    // Not going full screen — either it is off or the window is already there —
                    // so this is the only moment the floor gets applied on the way in.
                    growToFloor(window, within: visible)
                    return
                }
                // **Full size first, then the toggle.** AppKit paints at the autosaved size
                // before `didBecomeKey`, so the transition zooms out of a small window somebody
                // has already seen. `alphaValue = 0` was tried on 2026-09-10 to cover that and
                // BROKE full screen: a window at alpha 0 is not on screen as far as
                // `toggleFullScreen` is concerned. Growing to `openingFraction` was the attempt
                // before that, and stopping in between is what made three states.
                //
                // `chosen` is kept because AppKit restores the pre-full-screen frame on exit,
                // and that frame is now the whole screen.
                let chosen = window.frame
                // **Its own one-shot**, because it is about this entry into full screen and the
                // frame that was current when it happened. Left registered it would put an old
                // frame back on every later exit.
                let restorer = ObserverHolder()
                restorer.token = NotificationCenter.default.addObserver(
                    forName: NSWindow.didExitFullScreenNotification, object: window,
                    queue: .main) { [weak window] _ in
                        MainActor.assumeIsolated {
                            if let token = restorer.token {
                                NotificationCenter.default.removeObserver(token)
                            }
                            guard let window else { return }
                            window.setFrame(chosen, display: true, animate: false)
                            if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
                                growToFloor(window, within: visible)
                            }
                        }
                    }
                window.setFrame(visible, display: false, animate: false)
                window.toggleFullScreen(nil)
            }
        }
    // The token is returned so the view can drop it if the window goes before it ever became
    // key; the block removes it itself on the ordinary path.
    return holder.token.map { [$0] } ?? []
}

private final class ObserverHolder: @unchecked Sendable {
    var token: (any NSObjectProtocol)?
}
