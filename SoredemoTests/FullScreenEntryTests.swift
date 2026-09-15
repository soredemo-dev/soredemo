import Testing
@testable import Soredemo

/// When to ask AppKit for full screen again, and when to stop.
///
/// The retry exists because `toggleFullScreen` at `didBecomeKey` is ignored without reporting
/// anything — four shapes were measured and all four failed, while the identical call seconds
/// later succeeds. See docs/design/full-screen-and-window-behaviour.md.
@Suite struct FullScreenEntryTests {

    /// **The clause that makes the retry safe.** `toggleFullScreen` TOGGLES: one call after the
    /// window has arrived takes it straight back out — the same even-number-of-calls defect
    /// that kept the editor windowed for a week. Stopping on success, not after a fixed count.
    @Test @MainActor func itStopsTheMomentTheWindowIsFullScreen() {
        #expect(!FullScreenEntry.shouldAttempt(attemptsLeft: 8, isFullScreen: true,
                                               isVisible: true))
    }

    /// Bounded, so a window that will never go full screen is not poked forever. After this it
    /// stays a window, which is a worse editor and not a broken one.
    @Test @MainActor func itGivesUpWhenTheAttemptsAreSpent() {
        #expect(!FullScreenEntry.shouldAttempt(attemptsLeft: 0, isFullScreen: false,
                                               isVisible: true))
    }

    /// A window that has been closed under it is not asked again.
    @Test @MainActor func aWindowThatWentAwayIsNotAsked() {
        #expect(!FullScreenEntry.shouldAttempt(attemptsLeft: 8, isFullScreen: false,
                                               isVisible: false))
    }

    @Test @MainActor func itAsksWhileThereIsSomethingToAskFor() {
        #expect(FullScreenEntry.shouldAttempt(attemptsLeft: 1, isFullScreen: false,
                                              isVisible: true))
    }

    /// The budget is stated rather than implied: eight attempts a quarter-second apart is two
    /// seconds, which is the number a reader needs to judge whether it is enough.
    @Test @MainActor func theBudgetIsTwoSeconds() {
        #expect(Double(FullScreenEntry.attempts) * FullScreenEntry.interval == 2.0)
    }
}
