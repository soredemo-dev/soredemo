import Foundation

/// Keeps the display from dimming or sleeping while a take runs.
///
/// **A person narrating over a still screen touches nothing**, and after the energy setting's idle
/// time the display dims and then sleeps — and ScreenCaptureKit records it going dark. Held by
/// `RecordingCoordinator` for exactly the life of a take, never longer: a menu-bar app that kept
/// every Mac's display on would be a battery complaint.
///
/// **`.idleDisplaySleepDisabled` is the flag that matters.** `.userInitiated` alone was measured
/// holding `PreventUserIdleSystemSleep` and not `PreventUserIdleDisplaySleep`: the Mac stays up
/// and the screen still goes dark. See `docs/design/2026-09-30-before-and-during-a-take.md`.
final class TakeWakeLock {
    private var activity: (any NSObjectProtocol)?

    /// Once, however often it is called, so one `release()` always undoes it.
    func hold() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .userInitiated],
            reason: "Recording the screen")
    }

    func release() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }
}
