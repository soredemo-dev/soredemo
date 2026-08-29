import Foundation

/// **The drawn cursor reacts to a click, rather than only being circled by one.**
///
/// This app drew a ripple AROUND the cursor and left the cursor itself inert. Both reference
/// recorders that draw their own cursor move the cursor too: one common answer
/// computes a `clickScaleModifier` and multiplies the cursor's scale by it
/// is to scale it down while a button is held, and another
/// ships `cursorClickBounce: 3.5` over `cursorClickBounceDuration: 350` in its
/// `cursorMotionPresets`. A viewer reads a press as the pointer moving, not as a ring appearing
/// beside it, which is why a recording with the ripple on still looked like nothing happened.
///
/// **Press, hold, release — three phases, and the hold is the one that needs the release edge.**
/// The cursor shrinks while the button is down and springs back when it comes up. A curve driven
/// by the press alone cannot do that: it would have to guess a duration, and a drag would spring
/// back mid-drag while the button was still held.
///
/// **A pure function of two elapsed times.** The caller supplies how long since the last press
/// and how long since the last release, both `nil` where there is none, and this answers a
/// multiplier. Nothing here reads a clock, holds state, or knows what a `HostInstant` is —
/// `ClickTrack` owns finding the two edges and this owns what they look like.
public enum CursorPress {
    /// How small the cursor goes while a button is held. 0.75 is a common figure; this is gentler
    /// because this app draws its own cursor art at a size a person chose, and a quarter off it
    /// reads as the pointer changing shape rather than as a press. **Uncalibrated.**
    public static let pressedScale: Double = 0.82
    /// How long the shrink takes. Short enough to feel like contact rather than an animation —
    /// A measured figure rather than a guess.
    public static let pressSeconds: Double = 0.10
    /// How long the spring back takes. Longer than the press, deliberately: a press is an event
    /// and a release is a recovery, and matching them makes the pair read as a flicker.
    public static let releaseSeconds: Double = 0.25

    /// The multiplier on the drawn cursor's size.
    ///
    /// `sincePress` and `sinceRelease` are seconds, or `nil` for "has not happened". The button
    /// is HELD when there is a press and either no release or a release older than the press.
    ///
    /// **The spring overshoots on the way back and the press does not.** Coming back to 1
    /// without passing it reads as the cursor inflating; a small overshoot reads as a release.
    /// It is small — 4% — for `TextAnimation.pop`'s reason: the same curve at 20% is a bounce,
    /// which is a different and more annoying thing.
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
        let overshoot = 1 + 0.04 * sin(t * .pi)
        // `(1 − e)·a + e·b` for `CursorLoop.position`'s reason: exact at both ends, so the
        // cursor finishes at exactly its own size rather than a hair off it forever.
        return (1 - eased) * pressedScale + eased * overshoot
    }
}
