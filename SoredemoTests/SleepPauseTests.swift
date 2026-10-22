import Testing
import AppKit
@testable import Soredemo

/// **A Mac that sleeps mid-take used to take the take with it** — the stream stopped with nothing
/// recorded about why, and with no movie fragments the open segment was unreadable (audit R1, R4).
/// Pausing before the sleep closes the segment, so everything recorded so far is a finished file.
@MainActor @Suite struct SleepPauseTests {
    final class Count { var value = 0 }

    @Test func theTakeIsPausedWhenTheMacIsAboutToSleep() {
        let centre = NotificationCenter()
        let pauses = Count()
        let guardian = SleepPause(centre: centre) { pauses.value += 1 }
        centre.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(pauses.value == 1)
        withExtendedLifetime(guardian) {}
    }

    /// Waking is not a reason to pause, and nothing resumes on its own: the person decides
    /// whether the take goes on after a sleep.
    @Test func wakingPausesNothingAndResumesNothing() {
        let centre = NotificationCenter()
        let pauses = Count()
        let guardian = SleepPause(centre: centre) { pauses.value += 1 }
        centre.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(pauses.value == 0)
        withExtendedLifetime(guardian) {}
    }

    /// Gone with its owner: a take that has ended must not be paused by the next sleep.
    @Test func aReleasedGuardPausesNothing() {
        let centre = NotificationCenter()
        let pauses = Count()
        var guardian: SleepPause? = SleepPause(centre: centre) { pauses.value += 1 }
        guardian = nil
        centre.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(pauses.value == 0)
        _ = guardian
    }
}
