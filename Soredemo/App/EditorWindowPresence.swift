import AppKit

/// Turns the Dock icon and the app menu on while an editor window is up, and off again after.
///
/// **An accessory app with no Dock icon is right for the recorder and wrong for the editor.**
/// The editor has ⌘S, ⌘Z and a File menu, and an accessory process has no menu bar to put them
/// in; a recorder with a Dock icon is an app you have to hide before you can record anything.
/// The policy is switched rather than chosen once, so each surface gets the one it needs.
@MainActor
enum EditorWindowPresence {
    /// **`LSUIElement` stays, and an experiment is why.**
    ///
    /// It was removed on 2026-08-26 on the reasoning that a UIElement app's windows cannot go
    /// full screen, which is what `WindowConfigurator`'s header claimed and what the folklore
    /// says. Two measurements killed that. First, the app still reported
    /// `type="UIElement"` to LaunchServices with the flag gone, because this very function
    /// makes it one a moment later — the flag was not what decided the process's type. Second,
    /// an isolated AppKit app entered full screen under EVERY policy, `.accessory` included.
    /// So the flag was neither the cause nor a cost worth paying to remove, and putting it back
    /// is cheaper than a launch that shows a Dock tile for a frame.
    ///
    /// What was actually missing is the row in the green button's menu, which no app controls.
    /// `StageWindow` offers the command on ⌃⌘F instead.
    /// Opens the editor, or brings the one that exists forward.
    ///
    /// **`WindowGroup` permits a second window and this is what refuses one.** The scene had to
    /// become a group so its window would be full-screen capable — see `SoredemoApp` for the
    /// measurement — and a group's `openWindow(id:)` makes a NEW window every call. Two editors
    /// would be two sets of models over one set of process-global `StageCompositor` statics,
    /// which is the arrangement the scene was a `Window` to avoid.
    ///
    /// Matched on the window's `identifier`, which SwiftUI stamps from the scene's id, rather
    /// than on the title: the title is the recording's name and changes with it.
    static func openEditor(_ open: (String) -> Void) {
        willOpen()
        if let existing = NSApp.windows.first(where: {
            $0.identifier?.rawValue.contains(WindowID.editor) == true && $0.isVisible
        }) {
            existing.makeKeyAndOrderFront(nil)
        } else {
            open(WindowID.editor)
        }
        NSApp.activate(ignoringOtherApps: true)
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
