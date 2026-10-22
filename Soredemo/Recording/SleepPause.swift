import AppKit

/// Pauses a take when the Mac is about to sleep.
///
/// **`TakeWakeLock` stops IDLE sleep; a closed lid or Apple menu → Sleep still sleeps**, and the
/// stream stopped mid-segment with nothing recorded about why. Pausing first closes the segment,
/// so everything recorded so far is a finished file before the Mac goes down. Nothing resumes on
/// wake: whether the take goes on after a sleep is the person's call. Held by
/// `RecordingCoordinator` for the life of a take; releasing it stops listening.
/// See `docs/design/2026-10-22-audit-and-how-to-stand-out.md` R4.
final class SleepPause {
    private var token: (any NSObjectProtocol)?
    private let centre: NotificationCenter

    /// `centre` is `NSWorkspace.shared.notificationCenter` in the app — sleep is posted there,
    /// not on the default centre — and a private one in tests.
    init(centre: NotificationCenter, pause: @escaping @MainActor () -> Void) {
        self.centre = centre
        token = centre.addObserver(forName: NSWorkspace.willSleepNotification, object: nil,
                                   queue: .main) { [pause] _ in
            // `pause` is the owner's own closure and holds the owner weakly — see the call site.
            MainActor.assumeIsolated { pause() }
        }
    }

    /// `isolated`: the token was made on the main actor and is removed there, whichever thread
    /// lets go of the last reference.
    isolated deinit {
        if let token { centre.removeObserver(token) }
    }
}
