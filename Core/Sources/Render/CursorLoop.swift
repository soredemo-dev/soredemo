import Foundation
import Geometry
import Timeline

/// **The cursor ends where it began, so a looping video does not jump.**
///
/// A demo embedded in a README or a landing page plays
/// on repeat, and at the seam the cursor teleports from wherever the recording left it back to
/// wherever it started — the one frame in the whole loop where the viewer's eye is yanked. The
/// fix is to spend the final stretch of the video gliding the cursor back to its opening
/// position, so the last frame and the first frame agree and the seam is invisible.
///
/// **Presentation, not observation.** Like the idle fade and the lean, this changes where the
/// drawn cursor is, not where the recorded pointer was — `PointerTrack` keeps the stepwise
/// truth for the review path (recorder-parity design, 2026-08-19), and this is applied one
/// layer out, in the compositor, beside the other presentation adjustments. Nothing here
/// touches a track.
///
/// **A pure function of output time**, and it has to be: the last frame of an EXPORT is what
/// must match the first, and an export's last frame is at the edit's output duration, not the
/// recording's. A loop computed in source time would return the cursor to the start of a
/// take whose first two seconds were cut, which is not where the exported video begins.
public enum CursorLoop {
    /// How long the glide back takes. **Uncalibrated.** Long enough that the return reads as a
    /// deliberate movement rather than a snap; short enough that it does not eat the end of a
    /// demo, where the last click is usually the payoff. There is no published
    /// figure.
    public static let leadSeconds: Double = 0.8

    /// How far through the glide the frame at `outputOffset` is: `nil` before the glide begins,
    /// 0 at its start and 1 at the video's LAST FRAME.
    ///
    /// **The last frame, not the last instant, and the difference cost a red test.** A video of
    /// duration D has no frame AT D — its last frame is at D − Δ, one frame duration earlier,
    /// and `EditTimeline` is half-open so an offset of D maps to no source time at all
    /// (`pastTheEndOfTheEditThereIsNoSourcePosition`). A glide that reached `home` only at D
    /// would leave the last frame that actually exists a fraction short of it, which is a
    /// small jump at the seam instead of a large one. So the glide ends at D − Δ, and `Δ` is
    /// a parameter with no default: a measurement has no safe default, and a caller that does
    /// not know its own frame rate should say so where it calls this.
    ///
    /// **Anything within half a frame of the last frame is fully home.** The offset arrives
    /// from a `CMTime` converted to nanoseconds and D − Δ is computed in seconds; the two
    /// disagree at the tenth decimal, and an eased 0.9999999996 is a residual — the thing the
    /// exactness promise is about. Half a frame is the natural quantum: no request can be
    /// closer to the last frame than that without being it.
    ///
    /// **The lead is capped at half the video**, for the reason `TextItem.animationState` caps
    /// its own: a two-second clip with an 0.8 s return is fine, and a one-second clip must not
    /// spend most of itself gliding home.
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
        // `1 − remaining/lead` rather than `(position − glideStart)/lead`: at the glide's own
        // start `remaining == lead` exactly, so this is an exact 0, where the other form's
        // subtraction of two nearby doubles is not.
        return min(max(1 - remaining / lead, 0), 1)
    }

    /// Where to draw the cursor: `actual` blended toward `home` by `progress`.
    ///
    /// **Ease-in-out, not linear and not the ease-out `TextAnimation` uses.** The cursor is
    /// already moving under the spring when the glide begins, and a glide that started at full
    /// speed would kink its path visibly. Easing in lets the return take over gradually; easing
    /// out lets it settle on `home` rather than arriving at speed and stopping dead, which is
    /// the other visible kink.
    ///
    /// At `progress == 1` the answer is `home` EXACTLY, not within a tolerance — that is the
    /// whole promise. A residual is a one-pixel jump at the seam, which is the thing this exists
    /// to remove.
    ///
    /// **Written as `(1 − e)·a + e·h`, not as `a + (h − a)·e`, and the test is why.** The second
    /// form is the one everybody writes and it is NOT exact at `e == 1`: `0.8 + (0.1 − 0.8) × 1`
    /// comes out at `0.10000000000000003`, because `0.1 − 0.8` is already rounded before the
    /// add. `atFullProgressTheCursorIsExactlyHome` went red on it. The first form multiplies
    /// `actual` by an exact zero and `home` by an exact one, and `0 + h` is `h` — exact at both
    /// ends by construction, whatever the operands.
    public static func position(actual: NormalizedPoint, home: NormalizedPoint,
                                progress: Double) -> NormalizedPoint {
        let p = min(max(progress, 0), 1)
        let eased = p * p * (3 - 2 * p)
        let stay = 1 - eased
        return NormalizedPoint(x: stay * actual.x + eased * home.x,
                               y: stay * actual.y + eased * home.y)
    }
}
