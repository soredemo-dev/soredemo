import AppKit
import Capture
import SwiftUI

/// Stops the app closing over an edit nobody has saved.
///
/// **A recording is not reproducible, and that is the whole argument.** Nobody can perform the
/// same demo twice: an edit lost is a demo re-recorded, not a file re-generated. Every editor in
/// Every editor asks before discarding one, and this app did not —
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
    /// A recording that has never been saved lives in a scratch directory that closing deletes —
    /// so for it, "don't save" means the recording is gone, not only the edits.
    private(set) var isNeverSaved = false
    /// Saves and reports whether it worked. `false` cancels the close: a person who chose Save
    /// and got a failed write must not then lose the work anyway.
    private var save: (@MainActor () -> Bool)?

    private init() {}

    /// Called by the window whenever its dirty state changes. `save` is re-registered each time
    /// because it captures the window's current state, which a stale closure would not have.
    func update(hasUnsavedChanges: Bool, isNeverSaved: Bool, save: @escaping @MainActor () -> Bool) {
        self.hasUnsavedChanges = hasUnsavedChanges
        self.isNeverSaved = isNeverSaved
        self.save = save
        // The dot in the close button, which is how macOS says "unsaved" everywhere else.
        for window in NSApp.windows where window.isVisible {
            window.isDocumentEdited = hasUnsavedChanges
        }
    }

    /// Nothing is open any more, so nothing is at risk.
    func clear() {
        hasUnsavedChanges = false
        isNeverSaved = false
        save = nil
        for window in NSApp.windows { window.isDocumentEdited = false }
    }

    /// Whether the caller may proceed with closing or quitting.
    ///
    /// **Three buttons, and Cancel is the default.** A person who hit ⌘Q by accident presses
    /// Return next; if that discarded the work, the accident would be complete. `NSAlert` gives
    /// the first button Return, so Save is first and destructive Discard is last.
    ///
    /// **The whole question, not a verb slotted into one.** "Save this recording before
    /// \(actionName)?" put an English gerund into a sentence no other language could translate,
    /// and the alert was English everywhere besides — `NSAlert` takes plain strings.
    func mayDiscard(asking question: LocalizedStringResource) -> Bool {
        guard hasUnsavedChanges else { return true }
        return ask(question: String(localized: question),
                   detail: String(localized: "A recording cannot be made again. If you don't save, the edits are lost."),
                   discard: String(localized: "Don't Save"))
    }

    /// Whether the editor window may close. See `EditorCloseGuard`.
    func mayCloseEditor() -> Bool {
        guard hasUnsavedChanges else { return true }
        let wording = Self.closingWording(neverSaved: isNeverSaved)
        return ask(question: wording.question, detail: wording.detail, discard: wording.discard)
    }

    /// **What closing loses, said on the button.** A recording never saved is DELETED by closing
    /// without saving — its scratch directory goes with the window — so the button says "Delete
    /// Recording"; one already saved loses only the edits since, which "Don't Save" says.
    static func closingWording(neverSaved: Bool) -> (question: String, detail: String, discard: String) {
        neverSaved
            ? (String(localized: "Save this recording before closing?"),
               String(localized: "It has never been saved. If you don't save it, the recording is deleted, and it cannot be made again."),
               String(localized: "Delete Recording"))
            : (String(localized: "Save this recording before closing?"),
               String(localized: "A recording cannot be made again. If you don't save, the edits are lost."),
               String(localized: "Don't Save"))
    }

    private func ask(question: String, detail: String, discard: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: discard)
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
    /// Set by `SoredemoApp` so the global shortcut has something to toggle. A weak-ish seam
    /// rather than a lookup: the delegate is created by SwiftUI and cannot reach the app's state.
    @MainActor static var toggleRecording: (@MainActor () -> Void)?
    /// Set by `SoredemoApp` for the same reason: the notch surface needs the coordinator, and
    /// panels are made once the application has finished launching.
    @MainActor static var installNotchSurface: (@MainActor () -> Void)?
    /// Registers the global shortcut and takes the Dock icon away again once the last editor
    /// closes — see `GlobalHotkey` and `EditorWindowPresence`.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // **First, before anything else this app does.** If a previous run hid the desktop's
        // icons and then died — crashed, was force-quit, lost power — the icons are still hidden
        // and nothing else will ever put them back. `DesktopIcons.restore()` does nothing unless
        // a debt was recorded, so this is free on every ordinary launch and is the only thing
        // that pays for the one launch in a thousand where it is not.
        DesktopIcons.restore()

        // **Watching from launch, not from when the menu opens, and that ordering is measured.**
        // A phone announces itself ONCE, through `AVCaptureDeviceWasConnected`, seconds after
        // the CoreMediaIO switch is thrown — and `DiscoverySession` does not list it at all, so
        // there is no way to catch up on an announcement that was missed. An app that started
        // listening when somebody opened the menu would see nothing until they unplugged the
        // device and plugged it back in.
        MobileScreen.startWatching()

        // No `MainActor.assumeIsolated` here. This target builds with
        // `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so this delegate method already IS
        // main-actor isolated and the assertion would be ceremony — and asserting isolation a
        // caller does not have is the exact shape that produced an EXC_BREAKPOINT in
        // `SystemCursorShape` earlier in this project.
        let registered = GlobalHotkey.shared.register(
            keyCode: GlobalHotkey.toggleRecordingKeyCode,
            modifiers: GlobalHotkey.toggleRecordingModifiers) {
                Self.toggleRecording?()
            }
        // **Reported rather than swallowed.** A combination another application already holds is
        // a thing a person can fix, and a stop key that silently does nothing is the worst
        // version of this feature.
        if !registered { GlobalHotkeyStatus.shared.failed = true }
        Self.installNotchSurface?()
        if UpdateChecker.checksAtLaunch { Task { await UpdateChecker.check(userInitiated: false) } }
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [] _ in
                // After the close, not during it: the window being closed is still in
                // `NSApp.windows` while the notification is being delivered.
                Task { @MainActor in EditorWindowPresence.windowClosed() }
            }
    }

    /// **The icons come back before the app goes away.** Quitting mid-recording is a normal
    /// thing to do, and `stopRecording`'s restore never runs on that path.
    ///
    /// `applicationWillTerminate` rather than `applicationShouldTerminate`: the latter can return
    /// `.terminateCancel`, and restoring the desktop for a quit that then does not happen would
    /// un-hide the icons in the middle of the recording the person just decided to keep making.
    func applicationWillTerminate(_ notification: Notification) {
        DesktopIcons.restore()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // `runModal` inside this callback rather than `.terminateLater` plus a reply: the alert
        // is synchronous and modal either way, and `.terminateLater` adds a state machine whose
        // only failure mode is an app that never finishes quitting.
        MainActor.assumeIsolated {
            UnsavedWorkGuard.shared.mayDiscard(asking: "Save this recording before quitting?") ? .terminateNow
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


/// Whether the global shortcut is actually registered, so the panel can say when it is not.
///
/// A separate observable object rather than a field on the coordinator: the delegate runs before
/// any of the app's state exists, and a flag it can set without reaching for that state is the
/// smaller seam.
@MainActor
@Observable
final class GlobalHotkeyStatus {
    static let shared = GlobalHotkeyStatus()
    var failed = false
    private init() {}
}
