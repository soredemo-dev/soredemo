import Foundation
import Geometry

/// How far to zoom for a framed target: **a logarithmic function of the control's size,
/// bounded and quantised.**
///
/// **Why logarithmic, which is this file's one real decision.** Control sizes span roughly
/// 35× on a 1080p recording — a 16 px checkbox against a 700 px pane — and any linear rule
/// saturates at one end of that range. The obvious formulation, "zoom until the control
/// fills half the frame", puts every control under ~4% of the screen at the ceiling, and
/// most controls are under 4%: the mapping degenerates to two values, which is precisely
/// what `framing-depth`'s ROADMAP row warns against. Measured before writing this, across
/// seven realistic sizes: the linear rule produced four distinct depths with three of them
/// pinned at the ceiling; this curve produces seven.
///
/// Depth is a pure function of SIZE, per the row. Nothing here reads the target's position,
/// its role, or anything about the click.
///
/// **Which frame's size, though — and that was a defect until 2026-08-26.** The size that
/// matters is the one a viewer sees, and a variant that does not match the recording's shape
/// shrinks it: `StagePlanner` fits and never crops, so a 16:9 recording covers about 0.32 of
/// a 9:16 frame and every control in it is 0.56 of the length it had in landscape. Depth was
/// computed from the extent WITHIN the recording, so a portrait export inherited landscape's
/// depths unchanged and its controls came out a little over half the size. `coverage` is now
/// a parameter of `zoom(for:coverage:)` with no default — see that function for why.
public enum FramingDepth {
    /// Never zoom out. A depth below 1 would show more than the recording contains.
    public static let minimumZoom: Double = 1.0

    /// Past this a demo reads as disorienting rather than helpful — the viewer loses where
    /// on screen they are. **Uncalibrated**, like `FramingGate`'s thresholds: a starting
    /// point chosen by eye, named here so one measurement can move it.
    public static let maximumZoom: Double = 3.0

    /// The extent at or below which a control gets the deepest zoom, and the one at or
    /// above which it gets none. The curve interpolates between them in log space.
    /// **Uncalibrated.**
    public static let deepestAtExtent: Double = 0.02
    public static let shallowestAtExtent: Double = 0.5

    /// **How far a source pixel may be stretched before the zoom is refused the rest of its
    /// depth.** A zoom is a magnification of the recording's own pixels, and nothing can put
    /// detail into a pixel that was not recorded: past ~1.5× a Lanczos upscale of text reads
    /// as soft, past 2.5× as smeared. Measured on this project's own table (design doc
    /// 2026-08-25): a 3024 px Retina capture on a 2661 px card is still at 1:1 at zoom 1.14
    /// and at 1.32× at zoom 1.5 — invisible — while zoom 3 is 2.64×, and a 1920 px capture
    /// on the same card is past 1.5× at zoom 1.08. So the ceiling is a function of PIXEL
    /// DENSITY, not a constant: the same control on a 1x display gets a shallower zoom than
    /// on a Retina one, which is what Screen Studio's depth visibly does. **Uncalibrated**,
    /// like the rest of this file.
    public static let maximumMagnification: Double = 1.5

    /// The deepest zoom the recording's pixels can carry on a card of `cardPixels` across,
    /// never below `minimumZoom`. At zoom `z` the card shows `source / z` source pixels
    /// stretched over `card` output pixels, so the magnification is `z × card / source`;
    /// the ceiling is where that reaches `maximumMagnification`. A card wider than the
    /// recording's pixels can carry — a 720p capture in a 4K stage — gives a ceiling below
    /// 1, which is "no zoom", and it is clamped rather than trapped because both sizes
    /// arrive from a picker.
    public static func zoomCeiling(sourcePixels: Double, cardPixels: Double) -> Double {
        guard sourcePixels > 0, cardPixels > 0, sourcePixels.isFinite, cardPixels.isFinite
        else { return minimumZoom }
        return max(minimumZoom, maximumMagnification * sourcePixels / cardPixels)
    }

    /// Depths land on multiples of this. **Quantisation is what stops the camera making
    /// small pointless adjustments**: two clicks on buttons a few pixels apart produce one
    /// depth, so there is nothing to animate between them.
    public static let quantisationStep: Double = 0.25

    /// How much bigger than the target the viewport must be, at minimum. Only binds for
    /// targets `FramingGate.tooLarge` would already have refused, and exists so this
    /// function cannot return a depth that crops the very thing it is framing
    /// (`theTargetAlwaysFitsInsideTheViewportItsDepthImplies`).
    private static let minimumContextMultiple: Double = 1.2

    /// **A depth written for a person, and `%.1f` is wrong for it.** Depths land on multiples
    /// of `quantisationStep` (0.25), so one decimal cannot represent half the values this
    /// function produces — and the way it fails is worse than truncation: `String(format:
    /// "%.1f", 2.25)` is "2.2" and 1.25 is "1.2", because the formatter rounds half to even.
    /// The timeline's zoom lane was labelling a 2.25× block "2.2×" and a 1.25× block "1.2×",
    /// neither of which is a depth the pipeline can produce, which reads as the numbers being
    /// made up rather than as a rounding.
    ///
    /// Trailing zeros are trimmed, so a plain doubling reads "2×" rather than "2.00×".
    ///
    /// **Here rather than in the view** because the reason it is subtle is `quantisationStep`,
    /// which lives here — and because a formatter in the app tier could not be tested.
    ///
    /// **Built from integers rather than `String(format:)`, and that is a build gate rather
    /// than a preference.** `String(format:)` is a C-variadic call, which
    /// `check-strict-memory-safety.sh` reports as an unmarked unsafe site; marking it would
    /// be a marker on the very API whose rounding this function exists to avoid. Hundredths
    /// are enough for any multiple of `quantisationStep`, and integer arithmetic cannot round
    /// half to even behind anyone's back.
    public static func label(for zoom: Double) -> String {
        guard zoom.isFinite, zoom >= 0 else { return "—" }
        let hundredths = Int((zoom * 100).rounded())
        let whole = hundredths / 100
        let fraction = hundredths % 100
        let times = "\u{00D7}"
        if fraction == 0 { return "\(whole)\(times)" }
        if fraction % 10 == 0 { return "\(whole).\(fraction / 10)\(times)" }
        // A fraction under ten needs its leading zero, or 2.05 would be written "2.5".
        let padded = fraction < 10 ? "0\(fraction)" : "\(fraction)"
        return "\(whole).\(padded)\(times)"
    }

    /// **The linear share of the output frame a card occupies, from the AREA share
    /// `AspectVariant.coverage(ofSourceAspect:)` reports.** Coverage is an area ratio; a
    /// control's EXTENT is a length, so the two are related by a square root and not by
    /// coverage itself. A 16:9 recording covers 0.32 of a 9:16 frame, and a control in it is
    /// 0.56 of the length it had in landscape — which is the number this returns.
    ///
    /// Clamped at 1: a card never occupies more of the frame than the frame has, and a
    /// coverage above 1 would otherwise make a zoom SHALLOWER than the recording's own
    /// shape gives. Non-finite or non-positive coverage falls back to 1 rather than
    /// trapping, because it arrives from a picker and from a decoder.
    public static func linearShare(ofCoverage coverage: Double) -> Double {
        guard coverage.isFinite, coverage > 0 else { return 1 }
        return min(1, coverage).squareRoot()
    }

    /// **How far to zoom, for a target seen through a variant that covers `coverage` of the
    /// output frame.**
    ///
    /// `coverage` is `AspectVariant.coverage(ofSourceAspect:)` — 1 when the output is the
    /// recording's own shape, about 0.32 for a 16:9 recording exported 9:16. **It has no
    /// default, deliberately.** The defect this parameter exists to fix was a portrait
    /// export silently inheriting landscape's depths, and a defaulted `1` would be that same
    /// silence spelled differently: every caller should have to say which frame it is
    /// deciding for.
    ///
    /// **Only the curve's input moves; the context clamp keeps the raw extent.** The curve
    /// asks "how big does this look", which is a question about the output frame. The clamp
    /// below asks "does the target still fit inside the viewport this depth implies", which
    /// is a question inside the recording's own coordinates — a target is cropped or not
    /// cropped regardless of what shape it is being exported to. Feeding the shrunken extent
    /// to the clamp would let a portrait zoom crop the very control it is framing, and the
    /// clamp binds MORE often in portrait precisely because the depths are deeper there.
    /// **How much of the derived zoom to use, as a multiplier on the AMOUNT rather than on
    /// the depth.** 1 is what the curve decided; 0 is no zoom at all; 1.5 is half again as
    /// much movement. `1 + (depth - 1) * intensity` rather than `depth * intensity`, because
    /// depth 1 means "do not zoom" and multiplying it by 0.5 would give 0.5 — a zoom OUT,
    /// showing more of the screen than the recording contains.
    ///
    /// ScreenKite ships exactly one dial for this ("increase zoom for detailed UI work,
    /// decrease it where the full screen matters more") and it is the one control this
    /// project's per-block adjustments could not stand in for: correcting forty blocks one at
    /// a time to say "less, everywhere" is not the same act.
    ///
    /// **Uncalibrated**, like the rest of this file. The ceiling is 2 because past it the
    /// curve's own `maximumZoom` binds for every realistic control and the dial stops doing
    /// anything, which is worse than not going further.
    public static let neutralIntensity: Double = 1
    public static let maximumIntensity: Double = 2

    public static func intensified(_ depth: Double, by intensity: Double) -> Double {
        guard intensity.isFinite, intensity >= 0 else { return depth }
        return 1 + (depth - 1) * min(intensity, maximumIntensity)
    }

    /// `intensity` scales the amount of zoom the curve asked for — see `intensified(_:by:)`.
    /// **No default, for the same reason `coverage` has none**: a caller that did not think
    /// about it is a caller whose zooms silently ignore a control a person moved.
    public static func zoom(for target: FramingTarget, coverage: Double,
                            intensity: Double) -> Double {
        // The LARGER dimension binds: zooming a wide, short field as if it were 24 px tall
        // would crop its ends.
        let extent = max(target.frame.size.width, target.frame.size.height)
        // What the control's extent is worth in the OUTPUT frame. In the recording's own
        // shape this is the extent itself, so a landscape export is bit-for-bit what it was
        // before this parameter existed (`aVariantMatchingTheRecordingChangesNoDepth`).
        let apparent = extent * linearShare(ofCoverage: coverage)

        let clamped = min(max(apparent, deepestAtExtent), shallowestAtExtent)
        let position = log(clamped / deepestAtExtent) / log(shallowestAtExtent / deepestAtExtent)
        var candidate = maximumZoom - (maximumZoom - minimumZoom) * position

        // **Intensity BEFORE the context clamp and before quantisation.** Before the clamp so
        // a dialled-up zoom still cannot crop the control it is framing — the safety bound is
        // not a person's to turn off. Before quantisation so the result still lands on the
        // 0.25 grid; applying it afterwards would put every depth between two steps and give
        // the camera small pointless adjustments to animate, which is what quantising exists
        // to prevent.
        candidate = intensified(candidate, by: intensity)

        // A zero-sized target cannot arrive from `FramingGate`, which refuses one, but this
        // function is public and pure and must not hand a non-finite number to a camera.
        if extent > 0 {
            candidate = min(candidate, 1.0 / (extent * minimumContextMultiple))
        }
        let stepped = (candidate / quantisationStep).rounded() * quantisationStep
        return min(max(stepped, minimumZoom), maximumZoom)
    }
}
