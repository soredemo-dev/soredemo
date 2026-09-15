import AppKit

/// Notification tokens that belong to one window, and go when it does.
///
/// **One reason to change: how this app remembers what it registered.** Two defects came from
/// not having it. `configure()` runs on every SwiftUI update and registered afresh each time,
/// so `toggleFullScreen` ran once per registration — two calls is enter-then-exit. And the
/// blocks captured `window` strongly and were never removed, so every editor window ever opened
/// stayed alive with its player, its compositor and its waveforms.
///
/// **A block must never capture its window strongly.** The thing that would remove the token
/// lives IN that window, so a strong capture makes a cycle: the window waits for the observer,
/// the observer waits for the window. `everyBlockObserverDeclaresWhatItCaptures` in
/// `AppSourceTests` requires a capture list on every block observer for exactly this reason.
@MainActor
final class WindowObservers {
    private var tokens: [any NSObjectProtocol] = []
    /// Which window these are about. A view can be moved to a different one, and tokens for a
    /// window this view no longer has are tokens about nothing.
    private(set) var subject: ObjectIdentifier?

    /// Whether `window` is the one already registered for.
    func alreadyRegistered(for window: NSWindow) -> Bool {
        subject == ObjectIdentifier(window)
    }

    /// Takes ownership of `newTokens`, dropping whatever was held before.
    func adopt(_ newTokens: [any NSObjectProtocol], for window: NSWindow) {
        removeAll()
        tokens = newTokens
        subject = ObjectIdentifier(window)
    }

    func removeAll() {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens = []
        subject = nil
    }
}

/// A token a block has to be able to remove itself with.
///
/// `@Sendable` closures may not mutate a captured local, so the token lives in a reference the
/// closure can read. `@unchecked Sendable` is sound for `assumeIsolated`'s reason: written on
/// the main actor, read only from a block the notification centre delivers on `.main`.
final class ObserverToken: @unchecked Sendable {
    var value: (any NSObjectProtocol)?

    /// Unregisters, once. Called from inside the block it belongs to.
    func remove() {
        if let value { NotificationCenter.default.removeObserver(value) }
        value = nil
    }
}
