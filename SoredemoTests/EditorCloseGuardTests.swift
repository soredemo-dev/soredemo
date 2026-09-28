import Testing
import AppKit
@testable import Soredemo

/// **Closing the editor asks first.** It closed without a word — only quitting asked — so a
/// recording never saved was lost to the red button, and its sound kept playing after the window
/// had gone (reported 2026-09-28). The guard sits in front of the window's own delegate, which
/// SwiftUI owns, answering `windowShouldClose` and passing everything else through.
@MainActor @Suite(.serialized) struct EditorCloseGuardTests {
    /// The delegate SwiftUI would have put there, standing in: it answers one question and
    /// counts another, so the test can see both the veto and the forwarding.
    final class Original: NSObject, NSWindowDelegate {
        var answersShouldClose = true
        var resizes = 0
        func windowShouldClose(_ sender: NSWindow) -> Bool { answersShouldClose }
        func windowDidResize(_ notification: Notification) { resizes += 1 }
    }

    private func window(with original: Original) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.delegate = original
        return window
    }

    @Test func aRefusedCloseKeepsTheWindow() {
        let original = Original()
        let window = window(with: original)
        EditorCloseGuard.install(on: window, shouldClose: { false }, didClose: {})
        #expect(window.delegate?.windowShouldClose?(window) == false)
    }

    /// Allowed by the guard, the original delegate still has its say — the guard adds a question,
    /// it does not remove SwiftUI's.
    @Test func anAllowedCloseStillAsksTheOriginalDelegate() {
        let original = Original()
        let window = window(with: original)
        EditorCloseGuard.install(on: window, shouldClose: { true }, didClose: {})
        #expect(window.delegate?.windowShouldClose?(window) == true)
        original.answersShouldClose = false
        #expect(window.delegate?.windowShouldClose?(window) == false)
    }

    /// Everything the guard does not answer reaches SwiftUI's delegate unchanged.
    @Test func everythingElseReachesTheOriginalDelegate() {
        let original = Original()
        let window = window(with: original)
        EditorCloseGuard.install(on: window, shouldClose: { true }, didClose: {})
        let delegate = window.delegate as? NSObject
        #expect(delegate !== original, "the guard is installed")
        #expect(delegate?.responds(to: #selector(NSWindowDelegate.windowDidResize(_:))) == true)
        window.delegate?.windowDidResize?(Notification(name: NSWindow.didResizeNotification, object: window))
        #expect(original.resizes == 1)
    }

    /// Installed again — `configure()` runs on every key change — it replaces its own question
    /// rather than wrapping itself, which would ask twice.
    @Test func installingAgainDoesNotAskTwice() {
        let original = Original()
        let window = window(with: original)
        var asked = 0
        EditorCloseGuard.install(on: window, shouldClose: { asked += 1; return true }, didClose: {})
        EditorCloseGuard.install(on: window, shouldClose: { asked += 1; return true }, didClose: {})
        _ = window.delegate?.windowShouldClose?(window)
        #expect(asked == 1)
    }

    /// What happens after is only for a close that is going ahead.
    @Test func afterwardsRunsOnlyWhenTheCloseGoesAhead() {
        let original = Original()
        let window = window(with: original)
        var closed = 0
        var allow = false
        EditorCloseGuard.install(on: window, shouldClose: { allow }, didClose: { closed += 1 })
        _ = window.delegate?.windowShouldClose?(window)
        #expect(closed == 0)
        allow = true
        _ = window.delegate?.windowShouldClose?(window)
        #expect(closed == 1)
        original.answersShouldClose = false
        _ = window.delegate?.windowShouldClose?(window)
        #expect(closed == 1, "SwiftUI's delegate refused; nothing may be torn down")
    }

    /// A recording that was never saved is DELETED by closing without saving, and the button
    /// says so — "Don't Save" there would undersell it.
    @Test func theQuestionNamesWhatIsLost() {
        // Compared through the string tables: the test process runs in the machine's language,
        // and the first version compared with English and failed on a Chinese Mac.
        #expect(UnsavedWorkGuard.closingWording(neverSaved: true).discard == String(localized: "Delete Recording"))
        #expect(UnsavedWorkGuard.closingWording(neverSaved: false).discard == String(localized: "Don't Save"))
        #expect(UnsavedWorkGuard.closingWording(neverSaved: true).detail
                != UnsavedWorkGuard.closingWording(neverSaved: false).detail)
    }
}
