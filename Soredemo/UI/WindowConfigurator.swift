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
/// **Applied on attach and re-applied on every update.** The first version read `view.window`
/// once from a `DispatchQueue.main.async` in `makeNSView` and returned silently when it was
/// `nil` — a one-shot with a `guard` and nothing to retry it. `NSView` has the exact hook for
/// this: `viewDidMoveToWindow` fires when the view GETS a window, however late, and
/// `updateNSView` re-asserts afterwards so a later reset is undone on the next SwiftUI update
/// rather than lasting for the session.
///
/// **The green button still does not offer full screen, and 2026-08-26 established why not.**
///
/// This paragraph used to say: "this app sets no activation policy and has no `LSUIElement`, so
/// it is not an accessory app, whose windows genuinely cannot go full screen." Both halves were
/// false and neither had been checked. `INFOPLIST_KEY_LSUIElement = YES` sat in both build
/// configurations of the pbxproj, and `EditorWindowPresence` has always switched the policy —
/// `.regular` when an editor opens, `.accessory` when the last one closes.
///
/// The conclusion drawn from those false premises was false too, and an isolated experiment is
/// what settled it: a bare AppKit app that calls `toggleFullScreen(_:)` on a window carrying
/// `.fullScreenPrimary` ENTERS FULL SCREEN under every policy — `.regular`, `.accessory`, and
/// accessory switched to regular — all three reporting `didEnterFullScreenNotification` and a
/// `.fullScreen` style mask. So an accessory app's windows can go full screen; the folklore is
/// wrong on this system, and the flags below are not the thing that was missing.
///
/// What remains missing is the ROW in the green button's own menu, which an app does not
/// control. `StageWindow` offers the command directly instead — a toolbar button on ⌃⌘F, which
/// is what `../opensource/…/a native editor` does with its own `MainMenu` item rather than relying
/// on the button. The flags here stay: they are what make the window full-screen-capable at
/// all, which is the half `toggleFullScreen` needs.
struct WindowConfigurator: NSViewRepresentable {
    /// Most of the screen, with enough left over that the window still reads as a window and
    /// whatever is behind it can still be grabbed. **Uncalibrated.**
    static let openingFraction: Double = 0.92

    func makeNSView(context: Context) -> AttachedView { AttachedView() }

    func updateNSView(_ view: AttachedView, context: Context) { view.configure() }

    /// A view that knows when it has a window. `internal` rather than private because
    /// `NSViewRepresentable`'s associated type is this type, and Swift will not let a
    /// public-facing conformance name a private one.
    final class AttachedView: NSView {
        /// Whether this view has already registered its full-screen observers for its window.
        /// `configure()` runs on every SwiftUI update, and a second registration would set the
        /// presentation options twice per transition.
        private var watchesFullScreen = false

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
            // **`.fullScreenNone` removed first, because the two are mutually exclusive and it
            // wins.** SwiftUI sets it on a `Window` scene that has a default size, and an
            // `insert` beside it does nothing — measured, `collectionBehavior` read back as
            // `primary | fullScreenNone | moveToActiveSpace` with the insert in place. The
            // scene no longer asks for a default size, which is what actually fixed it (see
            // `SoredemoApp`); this removal is the second lock on the same door, for a scene
            // modifier added later that sets it again.
            window.collectionBehavior.remove(.fullScreenNone)
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.collectionBehavior.insert(.moveToActiveSpace)
            sizeGenerouslyOnFirstOpen(window)
            watchFullScreen(window)
        }

        /// **In full screen the toolbar gets out of the way and comes back when you reach for
        /// it**, which is what every full-screen Mac app does and what this one did not: the
        /// title bar and its buttons stayed drawn across the top of the picture the whole time.
        ///
        /// **Presentation options on the notification, not a window delegate.** The documented
        /// route is `window(_:willUseFullScreenPresentationOptions:)`, and this window already
        /// has a delegate — SwiftUI's own, which drives the scene. Replacing it breaks the
        /// scene and proxying it means forwarding every selector SwiftUI might add. Setting
        /// `NSApp.presentationOptions` on entry is the same setting by the other supported
        /// route, and it is undone on exit rather than left applied to whatever window is
        /// frontmost next.
        ///
        /// **All four options, because AppKit requires three of them together.**
        /// `autoHideToolbar` must be accompanied by `autoHideMenuBar`, and `autoHideMenuBar` by
        /// `autoHideDock` or `hideDock` — an incomplete set is an exception, not a partial
        /// effect. `autoHideDock` rather than `hideDock`: the Dock should come back with the
        /// menu bar when a person reaches for either, not be gone for the session.
        private func watchFullScreen(_ window: NSWindow) {
            guard !watchesFullScreen else { return }
            watchesFullScreen = true
            let centre = NotificationCenter.default
            centre.addObserver(forName: NSWindow.didEnterFullScreenNotification,
                               object: window, queue: .main) { _ in
                MainActor.assumeIsolated {
                    NSApp.presentationOptions = [.autoHideToolbar, .autoHideMenuBar,
                                                 .autoHideDock, .fullScreen]
                }
            }
            centre.addObserver(forName: NSWindow.didExitFullScreenNotification,
                               object: window, queue: .main) { _ in
                // Back to the system's own, so leaving full screen does not leave the menu bar
                // hiding over an ordinary desktop.
                MainActor.assumeIsolated { NSApp.presentationOptions = [] }
            }
        }
    }
}

/// The editor's size when it opens.
///
/// **A floor on every open, not a courtesy once ever** — and the change is the user's call,
/// made after three separate attempts to keep it as a one-shot each left the editor opening
/// too small to use.
///
/// The one-shot was right in principle: somebody who sizes this window has decided, and
/// overwriting that on every launch is the producer-value rule broken. What it was wrong about
/// is that "once ever" is one flag, and a flag is spent by things that are not a decision.
/// Measured on a real install, in order:
///
///   * `editorHasBeenSizedGenerously` read `1` while the editor still opened at its content's
///     size, because the flag was written BEFORE the frame was applied and anything in between
///     burnt it.
///   * `editorFirstOpenSizeApplied`, the key that replaced it, was spent correctly — and then
///     the scene changed from `Window` to `WindowGroup` so that its window could go full
///     screen, which gave AppKit a NEW autosave key (`…editor-AppWindow-1`) holding
///     `900 × 512`. A frame smaller than this window's own minimum, restored on every open,
///     with the flag already spent and no second chance in it.
///
/// So the rule is now a property rather than an event: the editor never OPENS smaller than
/// `openingFraction` of the screen it opens on. It grows a window that is under that and never
/// shrinks one that is over, so a person who has made theirs larger keeps it.
///
/// **What this costs, stated rather than discovered:** a person who deliberately makes the
/// editor small and closes it gets it back at full size next time. That is a real loss of a
/// real preference, and it is the trade that was chosen — an editor that opens unusably small
/// is the failure people actually reported, twice.
///
/// **A share of whatever screen it opens on, never a fixed size.** Every display is a different
/// size and a number chosen on one machine is wrong on all the others. The fraction is of
/// `visibleFrame`, which already excludes the menu bar and the Dock.
private func sizeGenerouslyOnFirstOpen(_ window: NSWindow) {
    // A floor regardless, so the editor cannot be dragged into a size where the timeline has no
    // length. AppKit enforces it from here on — and note it did NOT stop a smaller frame being
    // restored from an autosave written under a different scene identity.
    window.minSize = NSSize(width: 1000, height: 680)

    // **After the window has become key, not here.** `makeNSView` runs while the hierarchy is
    // still being assembled, and AppKit restores an autosaved frame somewhere after that — a
    // frame set now is a frame the restore overwrites, silently, which looks exactly like the
    // code never ran. A window is fully placed by the time it is key.
    //
    // **The token lives in a reference, not a `var` the closure captures.** A `@Sendable`
    // closure may not mutate a local it has captured, and it is the closure that has to remove
    // the observer — this is the smallest shape that lets a one-shot observer unregister
    // itself. `@unchecked Sendable` is sound for the same reason `assumeIsolated` below is:
    // written here on the main actor, read only from a closure the notification centre is told
    // to deliver on `.main`, and never touched from anywhere else.
    let holder = ObserverHolder()
    holder.token = NotificationCenter.default.addObserver(
        forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { _ in
            // `queue: .main` is the guarantee this rests on: the notification centre delivers
            // this block on the main queue, so it really is main-actor work.
            MainActor.assumeIsolated {
                if let token = holder.token { NotificationCenter.default.removeObserver(token) }
                guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
                let wanted = NSSize(width: visible.width * WindowConfigurator.openingFraction,
                                    height: visible.height * WindowConfigurator.openingFraction)
                // **Grows, never shrinks.** Each axis on its own: a window someone widened but
                // left short should gain the height and keep the width.
                let width = max(window.frame.width, wanted.width)
                let height = max(window.frame.height, wanted.height)
                guard width > window.frame.width || height > window.frame.height else { return }
                window.setFrame(NSRect(x: visible.minX + (visible.width - width) / 2,
                                       y: visible.minY + (visible.height - height) / 2,
                                       width: width, height: height),
                                display: true, animate: true)
            }
        }
}

private final class ObserverHolder: @unchecked Sendable {
    var token: (any NSObjectProtocol)?
}
