import Foundation

/// How long an export has left, which is the question a progress bar does not
/// answer.
///
/// Estimated from elapsed time over the reported fraction, never from a frame
/// rate — frames cost different amounts, so a rate measured early describes only
/// the early frames. Why nothing is claimed for the first two seconds, and why
/// the reading is rounded as coarsely as it is, are in
/// `docs/design/how-long-is-left.md`.
public struct ExportETA: Sendable, Equatable {
    /// How long the export must have been running before any estimate is offered.
    public static let settleSeconds: TimeInterval = 2

    /// How far it must have got before any estimate is offered.
    public static let settleFraction = 0.02

    /// How much of the new estimate is taken each time. 0.25, so a number reaches
    /// a change in about four updates.
    public static let smoothing = 0.25

    /// The smoothed estimate of seconds remaining, or `nil` while nothing is claimed.
    public private(set) var secondsRemaining: TimeInterval?

    public init() {}

    /// Folds in one progress report.
    ///
    /// `fraction` is how much is done, 0…1. `elapsed` is how long the export has been running.
    /// Returns the estimate, which is also left in `secondsRemaining`.
    @discardableResult
    public mutating func update(fraction: Double, elapsed: TimeInterval) -> TimeInterval? {
        guard fraction.isFinite, elapsed.isFinite,
              elapsed >= Self.settleSeconds, fraction >= Self.settleFraction,
              fraction < 1 else {
            // Not cleared: an export reaching 100%, or reporting a moment of
            // nonsense, must not blank a number somebody is reading.
            return secondsRemaining
        }
        let total = elapsed / fraction
        let remaining = max(total - elapsed, 0)
        secondsRemaining = secondsRemaining.map {
            $0 + (remaining - $0) * Self.smoothing
        } ?? remaining
        return secondsRemaining
    }

    /// The estimate as a reading, for whoever draws it to put into words.
    ///
    /// A value rather than a sentence, because an interpolated English string
    /// cannot be a key in a string table — there would be one key per number.
    /// Six cases means six keys, and the interface interpolates on its own side.
    public enum Reading: Sendable, Equatable, Hashable {
        case aFewSeconds
        /// Always a multiple of ten, and never zero.
        case seconds(Int)
        case aMinute
        case minutes(Int)
        case anHour
        case hours(Int)
    }

    public static func reading(_ seconds: TimeInterval?) -> Reading? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        if seconds < 10 { return .aFewSeconds }
        // 55, not 60, and a test found the difference: rounding to the nearest ten
        // inside a boundary of 60 makes 55 seconds read as "60 seconds".
        if seconds < 55 { return .seconds(max(Int((seconds / 10).rounded()) * 10, 10)) }
        if seconds < 90 { return .aMinute }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 55 { return .minutes(minutes) }
        let hours = Int((Double(minutes) / 60).rounded())
        return hours <= 1 ? .anHour : .hours(hours)
    }
}
