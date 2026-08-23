import AppKit

/// Turns the Dock icon and the app menu on while an editor window is up, and off again after.
///
/// **An accessory app with no Dock icon is right for the recorder and wrong for the editor.**
/// The editor has ⌘S, ⌘Z and a File menu, and an accessory process has no menu bar to put them
/// in; a recorder with a Dock icon is an app you have to hide before you can record anything.
/// The policy is switched rather than chosen once, so each surface gets the one it needs.
@MainActor
enum EditorWindowPresence {
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
