import AppKit

/// Getting the editor into full screen, and knowing when to stop asking.
///
/// **One reason to change: how this app enters full screen.** It used to be three lines inside
/// a notification block that also resized the window, registered a restorer and decided
/// collection behaviour — and the defect that kept the editor windowed for a week was invisible
/// there because no single place could say what order any of it happened in.
///
/// **`toggleFullScreen` at `didBecomeKey` is ignored, and AppKit does not say so.** Every
/// documented precondition is met and nothing happens; the identical call seconds later
/// succeeds. Four shapes were measured — synchronous, one turn later, 150 ms later, and without
/// the preceding `setFrame` — and all four failed. Measurements in
/// docs/design/full-screen-and-window-behaviour.md.
@MainActor
enum FullScreenEntry {
    /// How many times to ask, and how long to leave between asks.
    ///
    /// Bounded because a window that will never go full screen must not be poked forever: after
    /// this it stays a window, which is a worse editor and not a broken one.
    ///
    /// **Six seconds, not two, and a measurement moved it.** Two was enough on an idle machine
    /// and ran out on a busy one: at load average 6.2 the full-screen gate failed three times out
    /// of three, and at the same commit on a quiet machine it had passed twice out of twice. The
    /// window is not refusing — AppKit is not ready yet, and the budget expired before it was.
    ///
    /// **Costing nothing on a healthy machine is what makes the longer budget cheap.**
    /// `shouldAttempt` stops the moment the window reports full screen, so an idle Mac still
    /// spends one or two attempts; only the case that used to give up early waits longer. The
    /// alternative is a person opening a project while their machine is busy and getting a small
    /// window with no explanation, which is the defect this whole type exists to prevent.
    static let attempts = 24
    static let interval: Double = 0.25

    /// Whether another attempt is worth making.
    ///
    /// **Pure, and the one rule that matters is the second clause.** `toggleFullScreen`
    /// TOGGLES: asking once more after it has arrived takes the window straight back out, which
    /// is the same even-number-of-calls defect that made the editor open windowed for a week.
    /// Stopping on success rather than after a fixed count is what makes the retry safe.
    static func shouldAttempt(attemptsLeft: Int, isFullScreen: Bool, isVisible: Bool) -> Bool {
        attemptsLeft > 0 && !isFullScreen && isVisible
    }

    /// Asks for full screen until AppKit takes it, or until `attemptsLeft` runs out.
    static func enter(_ window: NSWindow, attemptsLeft: Int = attempts, asks: Int = 0) {
        let isFullScreen = window.styleMask.contains(.fullScreen)
        let isVisible = window.isVisible
        guard shouldAttempt(attemptsLeft: attemptsLeft, isFullScreen: isFullScreen,
                            isVisible: isVisible) else {
            lastAttempt = Attempt(asks: asks,
                                  stopped: reasonToStop(isFullScreen: isFullScreen,
                                                        isVisible: isVisible))
            return
        }
        lastAttempt = Attempt(asks: asks + 1, stopped: .asking)
        window.toggleFullScreen(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak window] in
            MainActor.assumeIsolated {
                guard let window else {
                    // The window was deallocated between two asks. Recorded rather than
                    // returned silently: it is the one ending `reasonToStop` cannot name,
                    // because there is no window left to ask about.
                    lastAttempt = Attempt(asks: asks + 1, stopped: .windowWentAway)
                    return
                }
                enter(window, attemptsLeft: attemptsLeft - 1, asks: asks + 1)
            }
        }
    }

    /// What the last run of `enter(_:)` did, so a failure can say WHICH ending it hit.
    ///
    /// **The gate that needed this could not read its own red.** `check-editor-opens-full-screen.sh`
    /// prints `fullScreen=false` and then lists four causes in the order they have historically
    /// occurred — the toggle asked too early, `.moveToActiveSpace`, an even number of toggles,
    /// `alphaValue = 0` — and says nothing about which one this was. It went red three separate
    /// times across two commits and each time the only way to classify it was to re-run the
    /// gate: five launches on 2026-09-16 alone to establish that a red immediately after the
    /// app-test gate and a green on a quiet machine were the same binary. **An intermittent
    /// failure that is re-run instead of read becomes a rumour**, which is this project's own
    /// rule, and the repair is the one the probe already had: make the check able to show its
    /// evidence. `exhausted` and `arrived` are different defects with different owners.
    ///
    /// Never `nil`: before anything has asked, the answer is `notAsked` with zero asks, which
    /// is a fact about this process and not an absence of one.
    private(set) static var lastAttempt = Attempt(asks: 0, stopped: .notAsked)

    /// How the asking ended, and how many times it asked.
    struct Attempt: Equatable {
        /// How many times `toggleFullScreen` was actually sent. **Not the same as the budget
        /// spent**: a healthy machine takes it on the first or second ask and stops, so a
        /// number near `attempts` is itself the finding.
        let asks: Int
        let stopped: Stop

        /// A `String` raw value because this is written into a report a shell script reads.
        enum Stop: String, Equatable {
            /// Nothing has asked in this process. The state before the editor opens.
            case notAsked
            /// Asked, and waiting out `interval` before looking again.
            case asking
            /// AppKit reported the window full screen. The only success.
            case arrived
            /// The budget ran out with the window still not full screen. AppKit was never
            /// ready, or is refusing for a reason it does not report.
            case exhausted
            /// The window stopped being visible — closed, or never ordered in. A different
            /// defect from `exhausted` and the one a busy machine produces.
            case windowNotVisible
            /// The window was deallocated between two asks.
            case windowWentAway
        }
    }

    /// Why `shouldAttempt` said no, given what the window said.
    ///
    /// Pure, and separate from `enter` so the ordering can be asserted: a window that arrived
    /// full screen AND then went invisible is `arrived`, because it did what it was asked.
    static func reasonToStop(isFullScreen: Bool, isVisible: Bool) -> Attempt.Stop {
        if isFullScreen { return .arrived }
        if !isVisible { return .windowNotVisible }
        return .exhausted
    }
}
