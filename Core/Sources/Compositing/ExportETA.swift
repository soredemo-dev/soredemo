import Foundation

/// **How long an export has left, which is the question a progress bar does not answer.**
///
/// Reported as a defect by somebody using the app: *"it doesn't have a progress bar so the user
/// doesn't know the actual time the video is going to process"*. There IS a bar — a fraction, 60
/// points wide, in the toolbar — and the complaint is right anyway, because a fraction and a time
/// are different questions. A bar at 40% tells you where you are. It does not tell you whether to
/// wait or to go and do something else, and that is the only decision anybody makes while an
/// export runs.
///
/// ### Estimated from elapsed time, not from a frame rate
///
/// The obvious spelling counts frames per second and divides the frames left by it. It is worse:
/// frames cost different amounts — a zoomed frame with a camera, captions and a blurred wallpaper
/// is several times the work of a still one — so a rate measured over the first second describes
/// the first second. The FRACTION already integrates all of that, and elapsed ÷ fraction is the
/// total the whole export is heading for.
///
/// ### Nothing is claimed until there is something to claim
///
/// **The first estimate is the one that decides whether anybody believes the rest.** An export
/// half a second in has a fraction near zero and a division near infinity; showing "about 4 hours"
/// and then "about 30 seconds" two seconds later teaches somebody that the number is noise, and
/// they will not read it again. So nothing is shown until the export has been running for
/// `settleSeconds` AND is past `settleFraction`. Both, not either: a fast export passes the
/// fraction in a moment with a rate measured over almost nothing, and a slow one sits below the
/// fraction for a while with plenty of elapsed time and no idea where it is going.
///
/// ### Smoothed, and rounded coarsely on purpose
///
/// The raw estimate wobbles frame to frame. It is smoothed exponentially, and then `wording`
/// rounds hard — "about 2 minutes", never "1 minute 47 seconds". **Precision that the number does
/// not have is worse than no number**: a countdown that says 47 seconds and takes 80 is a broken
/// promise, where "about a minute" was never one.
public struct ExportETA: Sendable, Equatable {
    /// How long the export must have been running before any estimate is offered.
    public static let settleSeconds: TimeInterval = 2

    /// How far it must have got before any estimate is offered.
    public static let settleFraction = 0.02

    /// How much of the new estimate is taken each time. **0.25, so a number reaches a change in
    /// about four updates** — fast enough to follow an export that genuinely slows down, slow
    /// enough that the reading does not jump while somebody is looking at it.
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
            // **Not cleared.** An export that reaches 100% or reports a moment of nonsense should
            // not blank a number somebody is reading; it stops updating and the caller stops
            // showing it when the job finishes.
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
    /// **A value rather than a sentence, and the reason is translation.** The first version of
    /// this returned English — `"about 3 minutes left"` — built by interpolation, which cannot be
    /// a key in a string table: there is one key per number. Returning the shape instead lets the
    /// interface hold six keys, one per case, and interpolate the number on its own side where
    /// `LocalizedStringKey` turns `\(n)` into `%lld` and the tables can carry it.
    ///
    /// **Rounded to the precision the number actually has.** Under ten seconds it says so without
    /// counting, because a countdown wrong by two seconds at the end is the most annoying place to
    /// be wrong. Seconds go in tens; anything above an hour is whole hours, because an estimate
    /// that long has stopped being a plan and become a warning.
    ///
    /// `nil` when there is nothing to say, so a caller cannot render a placeholder by accident.
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
        // **55, not 60, and a test found the difference.** Rounding to the nearest ten inside a
        // boundary of 60 makes 55 seconds read as "60 seconds" — which is a minute said the long
        // way, and reads as a machine counting rather than as an estimate.
        if seconds < 55 { return .seconds(max(Int((seconds / 10).rounded()) * 10, 10)) }
        if seconds < 90 { return .aMinute }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 55 { return .minutes(minutes) }
        let hours = Int((Double(minutes) / 60).rounded())
        return hours <= 1 ? .anHour : .hours(hours)
    }
}
