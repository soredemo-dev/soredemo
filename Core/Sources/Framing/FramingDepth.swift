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
