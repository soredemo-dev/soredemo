import AppKit

/// Turns the Dock icon and the app menu on while an editor window is up, and off again after.
///
/// **An accessory app with no Dock icon is right for the recorder and wrong for the editor.**
/// The editor has ⌘S, ⌘Z and a File menu, and an accessory process has no menu bar to put them
/// in; a recorder with a Dock icon is an app you have to hide before you can record anything.
/// The policy is switched rather than chosen once, so each surface gets the one it needs.
@MainActor
enum EditorWindowPresence {
    /// Opens the editor, or brings the one that exists forward, filling the screen either way —
    /// as a window since 2026-10-25 (`EditorOpening`), or full screen if that switch is back on.
    ///
    /// **`WindowGroup` permits a second window and this is what refuses one** — a group's
    /// `openWindow(id:)` makes a NEW window every call, and two editors would be two sets of
    /// models over one set of process-global `StageCompositor` statics. Matched on the window's
    /// `identifier` rather than its title, which is the recording's name and changes with it.
    ///
    /// **Filling the screen is a property of being shown, not an event on the first key**: a
    /// one-shot `didBecomeKey` observer fires when SwiftUI creates the window and never again.
    /// The cost: an editor left smaller is filled again by the next recording — acceptable
    /// because this has one caller, a new recording or a newly opened project.
    /// Why `LSUIElement` is still in the Info.plist: `docs/design/full-screen-and-window-behaviour.md`.
    static func openEditor(_ open: (String) -> Void) {
        willOpen()
        if let existing = NSApp.windows.first(where: {
            $0.identifier?.rawValue.contains(WindowID.editor) == true && $0.isVisible
        }) {
            existing.makeKeyAndOrderFront(nil)
            showFullScreen(existing)
            // An editor left smaller is grown to fill the screen again, the way a new one opens.
            if !WindowConfigurator.opensFullScreen, !existing.styleMask.contains(.fullScreen),
               let visible = (existing.screen ?? NSScreen.main)?.visibleFrame {
                EditorOpening.present(existing, within: visible)
            }
        } else {
            // A window SwiftUI has not built yet has no `NSWindow` to toggle;
            // `WindowConfigurator` takes that path when the window becomes key.
            open(WindowID.editor)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Puts an already-open editor into full screen, if it is not there.
    ///
    /// Reads `WindowConfigurator.opensFullScreen` rather than a switch of its own: two switches
    /// for one behaviour is two switches that disagree, and the one over there is the one the
    /// creation path already obeys.
    private static func showFullScreen(_ window: NSWindow) {
        guard WindowConfigurator.opensFullScreen,
              !window.styleMask.contains(.fullScreen) else { return }
        // After the window is key, for `WindowConfigurator`'s reason: AppKit is still settling
        // the frame, and a toggle issued into that produces the transition from the old size.
        DispatchQueue.main.async { window.toggleFullScreen(nil) }
    }

    static func willOpen() {
        NSApp.setActivationPolicy(.regular)
    }

    /// Called after a window closes. Counts what is LEFT rather than trusting the notification's
    /// window, because the menu bar item's own popover is an `NSWindow` too and closing it must
    /// not take the Dock icon away from an editor that is still open.
    static func windowClosed() {
        let editors = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }
        guard editors.isEmpty else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}
