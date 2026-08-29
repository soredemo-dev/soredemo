import Foundation
import Geometry

/// How far to zoom for a framed target: a logarithmic function of the control's
/// apparent size, bounded and quantised.
///
/// Depth is a pure function of SIZE — nothing here reads the target's position,
/// its role, or anything about the click. Why the curve is logarithmic, why the
/// magnification ceiling depends on pixel density, and why `coverage` has no
/// default are in `docs/design/how-deep-the-camera-goes.md`.
public enum FramingDepth {
    /// Never zoom out. A depth below 1 would show more than the recording holds.
    public static let minimumZoom: Double = 1.0

    /// Past this a demo reads as disorienting rather than helpful. **Uncalibrated.**
    public static let maximumZoom: Double = 3.0

    /// The extent at or below which a control gets the deepest zoom, and the one
    /// at or above which it gets none. The curve interpolates in log space.
    /// **Uncalibrated.**
    public static let deepestAtExtent: Double = 0.02
    public static let shallowestAtExtent: Double = 0.5

    /// How far a source pixel may be stretched before the zoom is refused the
    /// rest of its depth. **Uncalibrated.**
    public static let maximumMagnification: Double = 1.5

    /// Depths land on multiples of this. Quantisation is what stops the camera
    /// making small pointless adjustments between two nearby clicks.
    public static let quantisationStep: Double = 0.25

    /// The neutral setting of the intensity dial, and the furthest it goes.
    /// Past 2 the curve's own `maximumZoom` binds for every realistic control and
    /// the dial stops doing anything. **Uncalibrated.**
    public static let neutralIntensity: Double = 1
    public static let maximumIntensity: Double = 2

    /// How much bigger than the target the viewport must be, at minimum. Only
    /// binds for targets `FramingGate.tooLarge` would already have refused, and
    /// exists so this cannot return a depth that crops what it is framing
    /// (`theTargetAlwaysFitsInsideTheViewportItsDepthImplies`).
    private static let minimumContextMultiple: Double = 1.2

    /// The deepest zoom the recording's pixels can carry on a card of
    /// `cardPixels` across, never below `minimumZoom`.
    ///
    /// At zoom `z` the card shows `source / z` source pixels stretched over
    /// `card` output pixels, so the magnification is `z × card / source` and the
    /// ceiling is where that reaches `maximumMagnification`. A card wider than
    /// the recording can carry gives a ceiling below 1 — "no zoom" — clamped
    /// rather than trapped because both sizes arrive from a picker.
    public static func zoomCeiling(sourcePixels: Double, cardPixels: Double) -> Double {
        guard sourcePixels > 0, cardPixels > 0, sourcePixels.isFinite, cardPixels.isFinite
        else { return minimumZoom }
        return max(minimumZoom, maximumMagnification * sourcePixels / cardPixels)
    }

    /// A depth written for a person: "2×", "2.25×".
    ///
    /// Built from integers rather than `String(format:)`, which rounds half to
    /// even and would label a 2.25× block "2.2×" — a depth the pipeline cannot
    /// produce. Here rather than in the view because the reason it is subtle is
    /// `quantisationStep`, which lives here.
    public static func label(for zoom: Double) -> String {
        guard zoom.isFinite, zoom >= 0 else { return "—" }
        let hundredths = Int((zoom * 100).rounded())
        let whole = hundredths / 100
        let fraction = hundredths % 100
        let times = "\u{00D7}"
        if fraction == 0 { return "\(whole)\(times)" }
        if fraction % 10 == 0 { return "\(whole).\(fraction / 10)\(times)" }
        // A fraction under ten needs its leading zero, or 2.05 would be "2.5".
        let padded = fraction < 10 ? "0\(fraction)" : "\(fraction)"
        return "\(whole).\(padded)\(times)"
    }

    /// The LINEAR share of the output frame a card occupies, from the AREA share
    /// `AspectVariant.coverage(ofSourceAspect:)` reports — hence the square root.
    ///
    /// Clamped at 1: a card never occupies more of the frame than the frame has.
    /// Non-finite or non-positive coverage falls back to 1 rather than trapping,
    /// because it arrives from a picker and from a decoder.
    public static func linearShare(ofCoverage coverage: Double) -> Double {
        guard coverage.isFinite, coverage > 0 else { return 1 }
        return min(1, coverage).squareRoot()
    }

    /// Scales the AMOUNT of zoom the curve asked for, not the depth: `1 + (depth
    /// − 1) × intensity`, because depth 1 means "do not zoom" and multiplying it
    /// by 0.5 would give a zoom OUT.
    public static func intensified(_ depth: Double, by intensity: Double) -> Double {
        guard intensity.isFinite, intensity >= 0 else { return depth }
        return 1 + (depth - 1) * min(intensity, maximumIntensity)
    }

    /// How far to zoom, for a target seen through a variant that covers
    /// `coverage` of the output frame.
    ///
    /// `coverage` is `AspectVariant.coverage(ofSourceAspect:)` — 1 when the
    /// output is the recording's own shape, about 0.32 for a 16:9 recording
    /// exported 9:16. `intensity` scales the amount the curve asked for.
    ///
    /// **Neither has a default, deliberately.** Each stands where a silent
    /// inheritance once was: a portrait export taking landscape's depths, and a
    /// zoom ignoring a dial a person moved.
    public static func zoom(for target: FramingTarget, coverage: Double,
                            intensity: Double) -> Double {
        // The LARGER dimension binds: zooming a wide, short field as if it were
        // 24 px tall would crop its ends.
        let extent = max(target.frame.size.width, target.frame.size.height)
        // What the extent is worth in the OUTPUT frame. In the recording's own
        // shape this is the extent itself, so a landscape export is bit-for-bit
        // what it was before this parameter existed
        // (`aVariantMatchingTheRecordingChangesNoDepth`).
        let apparent = extent * linearShare(ofCoverage: coverage)

        let clamped = min(max(apparent, deepestAtExtent), shallowestAtExtent)
        let position = log(clamped / deepestAtExtent) / log(shallowestAtExtent / deepestAtExtent)
        var candidate = maximumZoom - (maximumZoom - minimumZoom) * position

        // Before the clamp, so a dialled-up zoom still cannot crop the control it
        // is framing — that bound is not a person's to turn off. Before
        // quantisation, so the result still lands on the grid.
        candidate = intensified(candidate, by: intensity)

        // A zero-sized target cannot arrive from `FramingGate`, which refuses
        // one, but this is public and pure and must not hand a non-finite number
        // to a camera.
        if extent > 0 {
            candidate = min(candidate, 1.0 / (extent * minimumContextMultiple))
        }
        let stepped = (candidate / quantisationStep).rounded() * quantisationStep
        return min(max(stepped, minimumZoom), maximumZoom)
    }
}
