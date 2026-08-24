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

    public static func zoom(for target: FramingTarget) -> Double {
        // The LARGER dimension binds: zooming a wide, short field as if it were 24 px tall
        // would crop its ends.
        let extent = max(target.frame.size.width, target.frame.size.height)

        let clamped = min(max(extent, deepestAtExtent), shallowestAtExtent)
        let position = log(clamped / deepestAtExtent) / log(shallowestAtExtent / deepestAtExtent)
        var candidate = maximumZoom - (maximumZoom - minimumZoom) * position

        // A zero-sized target cannot arrive from `FramingGate`, which refuses one, but this
        // function is public and pure and must not hand a non-finite number to a camera.
        if extent > 0 {
            candidate = min(candidate, 1.0 / (extent * minimumContextMultiple))
        }
        let stepped = (candidate / quantisationStep).rounded() * quantisationStep
        return min(max(stepped, minimumZoom), maximumZoom)
    }
}
