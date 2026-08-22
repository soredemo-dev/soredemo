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
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // `runModal` inside this callback rather than `.terminateLater` plus a reply: the alert
        // is synchronous and modal either way, and `.terminateLater` adds a state machine whose
        // only failure mode is an app that never finishes quitting.
        MainActor.assumeIsolated {
            UnsavedWorkGuard.shared.mayDiscard(actionName: "quitting") ? .terminateNow
                                                                      : .terminateCancel
        }
    }

    /// One window that holds the recording, so closing it is quitting. Saying so here rather
    /// than leaving a process with no windows running in the Dock.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
