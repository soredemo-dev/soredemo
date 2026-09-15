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
    static let attempts = 8
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
    static func enter(_ window: NSWindow, attemptsLeft: Int = attempts) {
        guard shouldAttempt(attemptsLeft: attemptsLeft,
                            isFullScreen: window.styleMask.contains(.fullScreen),
                            isVisible: window.isVisible) else { return }
        window.toggleFullScreen(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak window] in
            MainActor.assumeIsolated {
                guard let window else { return }
                enter(window, attemptsLeft: attemptsLeft - 1)
            }
        }
    }
}
