/// The one place `Sources/Headless` reads a clock. Every member of this file reads it —
/// that is what makes the whole-file permit in `Tests/AppSourceTests` cost nothing,
/// the same granularity argument `Soredemo/Support/Minting.swift` carries for the app
/// target. Code elsewhere in `Headless` that needs elapsed time takes one of these; if
/// the stopwatch cannot express the need, widen this file, not the permit.
///
/// `SuspendingClock` on purpose: `Date` is settable, so a clock stepped backwards
/// mid-poll unbounds the very deadline this exists to enforce; and `ContinuousClock`
/// advances across system sleep, which would bill a closed laptop lid as a stall.
/// Internal, not public: its one caller is `MP4Exporter`, in this module. The entry
/// rule wants every public type named by a test that links the product; the cheaper
/// and truer fix is not being public until someone outside needs it.
nonisolated struct MonotonicStopwatch: Sendable {
    private let start: SuspendingClock.Instant

    /// Starts at the moment of construction — the construction IS the clock read.
    init() {
        start = SuspendingClock.now
    }

    /// Seconds since construction, excluding time the machine spent asleep.
    var elapsedSeconds: Double {
        let elapsed = SuspendingClock.now - start
        return Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
    }
}
