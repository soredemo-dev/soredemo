import AppKit
import Carbon.HIToolbox

/// A keyboard shortcut that works while another application is in front.
///
/// **The reason this has to exist.** A recorder's stop key is pressed while the thing being
/// demonstrated has focus — that is what recording IS. A `.keyboardShortcut` on a SwiftUI button
/// only fires when this app's window is key, and the floating bar is a `.nonactivatingPanel` on
/// purpose, so it never becomes key either. Without a system-wide registration there is no key
/// that stops a recording, which is exactly what happened: ⌘R worked in the app's own window and
/// nowhere else. Every recorder surveyed in `docs/research/landscape.md` registers global
/// shortcuts for the same reason; this is that, without a plugin.
///
/// **Carbon's `RegisterEventHotKey`, not an `NSEvent` global monitor.** A global monitor needs
/// Accessibility permission, sees every keystroke in the system, and cannot consume the event —
/// so the shortcut would also reach whatever app is in front. `RegisterEventHotKey` needs no
/// permission, receives only the combination it registered, and swallows it.
///
/// **Verified by posting the key, not by reading the return value.** Registration reported
/// success while nothing happened, and the first two attempts to test it proved nothing: a
/// command-line process is not a registered GUI application and cannot receive hot keys at all,
/// and AppleScript's `keystroke` delivers to the frontmost application by a route that never
/// reaches the hot key dispatcher. Posting a `CGEvent` at `.cghidEventTap` — where a real
/// keypress goes — fired the handler with this app in the background and another application in
/// front, which is the case the feature exists for.
///
/// **It matches a key CODE and modifier flags and never asks what the key TYPES.**
/// `noAppSourceReadsKeystrokeText` bans every API that turns a key event into text, and says in
/// its own words that key codes and modifier flags stay legal: they are what a shortcut filter
/// matches on. This file is that shape and nothing more.
@MainActor
final class GlobalHotkey {
    /// Registered combinations, kept so `unregister` can reach them and so the process does not
    /// leak a hot key ref per re-registration.
    private var registered: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 1

    static let shared = GlobalHotkey()

    private init() {}

    /// ⇧⌘R — start a recording, or stop the one running. **One key for both**, because the
    /// question a person has mid-recording is "how do I stop this", and an answer that depends on
    /// remembering a second combination is not an answer. A surveyed recorder binds start and stop
    /// separately AND ships a toggle; the toggle is the one people use.
    static let toggleRecordingKeyCode = UInt32(kVK_ANSI_R)
    static let toggleRecordingModifiers = UInt32(cmdKey | shiftKey)
    /// The same combination as a person reads it, in the system's modifier order (⌃⌥⇧⌘).
    ///
    /// **Beside the registration it spells**, so the two cannot be changed one at a time without
    /// a test noticing (`GlobalHotkeyTests`). It lived on the menu bar panel, which four other
    /// surfaces reached into for it, and it read `⌘⇧R` — an order no macOS menu uses.
    static let toggleRecordingSpelling = "\u{21E7}\u{2318}R"

    /// Registers `action` for a key code and Carbon modifier mask. Returns false when the system
    /// refuses — usually because another application already holds the combination, which is a
    /// thing a person can fix and therefore a thing worth reporting rather than swallowing.
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1

        var hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var reference: EventHotKeyRef?
        // **`GetApplicationEventTarget()`, matching Apple's own sample**, and paired with an
        // application-target handler below. `GetEventDispatcherTarget()` is the other spelling
        // and is widely used; the documented pairing is the one to be on when the failure mode
        // is a key that silently does nothing.
        let status = unsafe RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                                GetApplicationEventTarget(), 0, &reference)
        _ = hotKeyID
        guard status == noErr, let reference else { return false }
        registered[id] = reference
        actions[id] = action
        return true
    }

    func unregisterAll() {
        for reference in registered.values { unsafe UnregisterEventHotKey(reference) }
        registered.removeAll()
        actions.removeAll()
    }

    /// The four-character signature Carbon uses to tell one app's hot keys from another's.
    private static let signature: OSType = {
        let bytes = Array("SORE".utf8)
        return bytes.reduce(0) { ($0 << 8) | OSType($1) }
    }()

    /// Runs the action for a fired hot key. Called from the Carbon handler below, which is a C
    /// callback and cannot capture `self`.
    fileprivate func fire(id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        var reference: EventHandlerRef?
        // `unsafe`: a C API taking pointers. The spec is a local that outlives the call — Carbon
        // copies it — and `userData` is nil because the handler reaches the singleton directly
        // rather than round-tripping a pointer to it.
        _ = unsafe InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler,
                                       1, &spec, nil, &reference)
        handler = reference
    }
}

/// The Carbon callback. A bare C function because `InstallEventHandler` takes one; it reads the
/// fired hot key's id out of the event and hands it to the singleton.
///
/// **`nonisolated` is required, not stylistic.** This target builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which makes even a file-scope function main-actor
/// isolated — and an isolated function cannot become a C function pointer. Without this the
/// compiler says only "a C function pointer can only be formed from a reference to a 'func'",
/// which does not mention isolation at all.
private nonisolated func hotKeyEventHandler(_ nextHandler: EventHandlerCallRef?,
                                _ event: EventRef?,
                                _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = unsafe GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                          EventParamType(typeEventHotKeyID), nil,
                                          MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return status }
    let id = hotKeyID.id
    // Hops to the main actor: Carbon delivers on the main thread, but the compiler cannot know
    // that, and asserting it with `assumeIsolated` is the exact shape that produced an
    // EXC_BREAKPOINT earlier in this project.
    Task { @MainActor in GlobalHotkey.shared.fire(id: id) }
    return noErr
}
