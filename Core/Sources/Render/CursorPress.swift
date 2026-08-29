import Foundation

/// The drawn cursor's size while a button is held, and its spring back on
/// release.
///
/// A pure function of two elapsed times: `ClickTrack` owns finding the press and
/// release edges, this owns what they look like. Nothing here reads a clock,
/// holds state, or knows what a `HostInstant` is.
///
/// Why the cursor moves at all rather than only being circled by a ripple, and
/// why the hold needs the release edge, are in
/// `docs/design/how-the-drawn-cursor-behaves.md`.
public enum CursorPress {
    /// How small the cursor goes while a button is held. **Uncalibrated.**
    public static let pressedScale: Double = 0.82
    /// How long the shrink takes. **Uncalibrated.**
    public static let pressSeconds: Double = 0.10
    /// How long the spring back takes. **Uncalibrated**, and longer than the
    /// press deliberately: a press is an event, a release is a recovery.
    public static let releaseSeconds: Double = 0.25

    /// The multiplier on the drawn cursor's size.
    ///
    /// `sincePress` and `sinceRelease` are seconds, or `nil` for "has not
    /// happened". The button is HELD when there is a press and either no release
    /// or a release older than the press.
    public static func scale(sincePress: Double?, sinceRelease: Double?) -> Double {
        guard let pressed = sincePress, pressed >= 0 else { return 1 }
        let isHeld = sinceRelease.map { $0 < 0 || $0 > pressed } ?? true

        if isHeld {
            guard pressed < pressSeconds else { return pressedScale }
            // Ease-out quad: fast at contact, settling into the hold.
            let t = pressed / pressSeconds
            let eased = 1 - (1 - t) * (1 - t)
            return 1 + (pressedScale - 1) * eased
        }

        guard let released = sinceRelease, released >= 0 else { return 1 }
        guard released < releaseSeconds else { return 1 }
        let t = released / releaseSeconds
        let eased = 1 - (1 - t) * (1 - t) * (1 - t)
        // 4%, not more: the same curve at 20% is a bounce, which is a different
        // and more annoying thing.
        let overshoot = 1 + 0.04 * sin(t * .pi)
        // `(1 − e)·a + e·b` for `CursorLoop.position`'s reason: exact at both
        // ends, so the cursor finishes at exactly its own size.
        return (1 - eased) * pressedScale + eased * overshoot
    }
}
