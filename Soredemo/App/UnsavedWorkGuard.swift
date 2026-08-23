import AppKit
import SwiftUI

/// Stops the app closing over an edit nobody has saved.
///
/// **A recording is not reproducible, and that is the whole argument.** Nobody can perform the
/// same demo twice: an edit lost is a demo re-recorded, not a file re-generated. Every editor in
/// `../opensource/Screen Record Opensource/` asks before discarding one, and this app did not —
/// it had a Save button and a window that closed without mentioning it.
///
/// **A shared object rather than a document architecture.** `ProjectDocument` exists and nothing
/// writes it: a saved project is a package the recorder's own directory becomes, and routing the
/// close through `NSDocument` would create a second window with no recording in it — the same
/// reasoning `SoredemoApp`'s Open command already records. So the window registers what it has
/// and how to save it, and the delegate below asks.
@MainActor
@Observable
final class UnsavedWorkGuard {
    static let shared = UnsavedWorkGuard()

    private(set) var hasUnsavedChanges = false
    /// Saves and reports whether it worked. `false` cancels the close: a person who chose Save
    /// and got a failed write must not then lose the work anyway.
    private var save: (@MainActor () -> Bool)?

    private init() {}

    /// Called by the window whenever its dirty state changes. `save` is re-registered each time
    /// because it captures the window's current state, which a stale closure would not have.
    func update(hasUnsavedChanges: Bool, save: @escaping @MainActor () -> Bool) {
        self.hasUnsavedChanges = hasUnsavedChanges
        self.save = save
        // The dot in the close button, which is how macOS says "unsaved" everywhere else.
        for window in NSApp.windows where window.isVisible {
            window.isDocumentEdited = hasUnsavedChanges
        }
    }

    /// Nothing is open any more, so nothing is at risk.
    func clear() {
        hasUnsavedChanges = false
        save = nil
        for window in NSApp.windows { window.isDocumentEdited = false }
    }

    /// Whether the caller may proceed with closing or quitting.
    ///
    /// **Three buttons, and Cancel is the default.** A person who hit ⌘Q by accident presses
    /// Return next; if that discarded the work, the accident would be complete. `NSAlert` gives
    /// the first button Return, so Save is first and destructive Discard is last.
    func mayDiscard(actionName: String) -> Bool {
        guard hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Save this recording before \(actionName)?"
        alert.informativeText =
            "A recording cannot be made again. If you don't save, the edits are lost."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // A save that failed — no destination chosen, or the write threw — must not be
            // read as consent to lose the work.
            return save?() ?? false
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }
}

/// The one thing an `NSApplicationDelegate` is needed for here.
final class SoredemoAppDelegate: NSObject, NSApplicationDelegate {
    /// Takes the Dock icon away again once the last editor closes — see `EditorWindowPresence`.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
                // After the close, not during it: the window being closed is still in
                // `NSApp.windows` while the notification is being delivered.
                Task { @MainActor in EditorWindowPresence.windowClosed() }
            }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // `runModal` inside this callback rather than `.terminateLater` plus a reply: the alert
        // is synchronous and modal either way, and `.terminateLater` adds a state machine whose
        // only failure mode is an app that never finishes quitting.
        MainActor.assumeIsolated {
            UnsavedWorkGuard.shared.mayDiscard(actionName: "quitting") ? .terminateNow
                                                                      : .terminateCancel
        }
    }

    /// **False, because this app lives in the menu bar.** It used to be true, on the grounds
    /// that one window held the recording so closing it was quitting. That stopped being true
    /// when the menu bar item became the way in: quitting on a window close would take the
    /// recorder away from a person who closed an editor, which is the opposite of what closing
    /// an editor means. ⌘Q still quits, and still asks first.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
