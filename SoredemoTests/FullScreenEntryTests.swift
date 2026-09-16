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
    /// **Six seconds, and the number is asserted because it was moved on evidence.** Two was
    /// enough on an idle Mac and ran out at load average 6.2 — three gate failures out of three,
    /// against two passes out of two at the same commit on a quiet one. See
    /// `FullScreenEntry.attempts`.
    @Test @MainActor func theBudgetIsSixSeconds() {
        #expect(Double(FullScreenEntry.attempts) * FullScreenEntry.interval == 6.0)
    }

    // MARK: - which ending it was

    // **A red this gate could not read cost five launches on 2026-09-16.** The failure listed
    // four causes and named none, so the only way to classify one was to run it again until it
    // went green — which is how an intermittent failure becomes a rumour. These pin the answers
    // the report now carries.

    /// The success. Asserted first because it is the one that must never be confused with
    /// `exhausted`: they are different defects with different owners.
    @Test @MainActor func arrivingIsItsOwnEnding() {
        #expect(FullScreenEntry.reasonToStop(isFullScreen: true, isVisible: true) == .arrived)
    }

    /// **`arrived` outranks `windowNotVisible`, and the order is the assertion.** A window that
    /// reached full screen and then went away did what it was asked; reporting that as the
    /// window having vanished would send somebody looking for a second instance that is not
    /// there.
    @Test @MainActor func aWindowThatArrivedAndThenWentAwayStillArrived() {
        #expect(FullScreenEntry.reasonToStop(isFullScreen: true, isVisible: false) == .arrived)
    }

    /// The busy-machine ending: still visible, still not full screen, nothing left to spend.
    @Test @MainActor func aBudgetSpentOnAVisibleWindowIsExhausted() {
        #expect(FullScreenEntry.reasonToStop(isFullScreen: false, isVisible: true) == .exhausted)
    }

    /// The one that used to be read as `exhausted` and is a different defect: the window was
    /// taken out from under the retry — a second instance, or `alphaValue = 0`, which AppKit
    /// treats as not on screen.
    @Test @MainActor func aWindowTakenAwayIsNotABudgetProblem() {
        #expect(FullScreenEntry.reasonToStop(isFullScreen: false, isVisible: false)
                == .windowNotVisible)
    }

    /// **Before anything asks, the answer is a value and not an absence.** A report that omitted
    /// the field, or carried an empty one, would read as "the app did not write it" — which is a
    /// fifth thing to rule out rather than an answer.
    @Test @MainActor func nothingHavingAskedIsItselfAnAnswer() {
        let untouched = FullScreenEntry.Attempt(asks: 0, stopped: .notAsked)
        #expect(untouched.stopped.rawValue == "notAsked")
        #expect(untouched.asks == 0)
    }

    /// **Every ending has a distinct spelling**, because the gate's message keys off the raw
    /// value and two endings sharing one would silently collapse into the wrong advice.
    @Test @MainActor func everyEndingIsSpelledDifferently() {
        let endings: [FullScreenEntry.Attempt.Stop] =
            [.notAsked, .asking, .arrived, .exhausted, .windowNotVisible, .windowWentAway]
        #expect(Set(endings.map(\.rawValue)).count == endings.count)
    }
}
