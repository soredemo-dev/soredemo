import Foundation
import Geometry
import Timeline

/// The cursor ends where it began, so a looping video does not jump at the seam.
///
/// Presentation, not observation: this changes where the drawn cursor is, not
/// where the recorded pointer was. `docs/design/how-the-drawn-cursor-behaves.md`
/// records why it is a function of OUTPUT time, and why the glide ends one frame
/// before the duration rather than at it.
public enum CursorLoop {
    /// How long the glide back takes. **Uncalibrated.**
    public static let leadSeconds: Double = 0.8

    /// How far through the glide the frame at `outputOffset` is: `nil` before the
    /// glide begins, 0 at its start and 1 at the video's LAST FRAME — which is at
    /// `outputDuration - frameSeconds`, not at the duration.
    ///
    /// `frameSeconds` has no default: a measurement has no safe default, and a
    /// caller that does not know its own frame rate should say so where it calls
    /// this. Anything within half a frame of the last frame is fully home.
    ///
    /// The lead is capped at half the video, so a one-second clip does not spend
    /// most of itself gliding home.
    public static func progress(outputOffset: Nanoseconds, outputDuration: Nanoseconds,
                                frameDuration frameSeconds: Double) -> Double? {
        let duration = Double(outputDuration.rawValue) / 1_000_000_000
        guard duration > 0, frameSeconds > 0, frameSeconds.isFinite else { return nil }
        let lastFrame = duration - frameSeconds
        guard lastFrame > 0 else { return nil }
        let lead = min(leadSeconds, lastFrame / 2)
        guard lead > 0 else { return nil }
        let position = Double(outputOffset.rawValue) / 1_000_000_000
        let remaining = lastFrame - position
        if remaining <= frameSeconds / 2 { return 1 }
        guard remaining <= lead else { return nil }
        // `1 − remaining/lead` rather than `(position − glideStart)/lead`: at the
        // glide's own start `remaining == lead` exactly, so this is an exact 0.
        return min(max(1 - remaining / lead, 0), 1)
    }

    /// Where to draw the cursor: `actual` blended toward `home` by `progress`.
    ///
    /// At `progress == 1` the answer is `home` EXACTLY, not within a tolerance —
    /// a residual is a one-pixel jump at the seam, which is the thing this exists
    /// to remove. Ease-in-out, so the return neither starts at full speed nor
    /// arrives at speed and stops dead.
    public static func position(actual: NormalizedPoint, home: NormalizedPoint,
                                progress: Double) -> NormalizedPoint {
        let p = min(max(progress, 0), 1)
        let eased = p * p * (3 - 2 * p)
        let stay = 1 - eased
        // `(1 − e)·a + e·h`, not `a + (h − a)·e`: the second form is not exact at
        // `e == 1` and `atFullProgressTheCursorIsExactlyHome` went red on it.
        return NormalizedPoint(x: stay * actual.x + eased * home.x,
                               y: stay * actual.y + eased * home.y)
    }
}
