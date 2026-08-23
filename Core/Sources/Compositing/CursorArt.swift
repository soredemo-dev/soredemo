import CoreGraphics
import Foundation

/// The pointer this app draws, which is never the real cursor: capture runs with
/// `showsCursor = false`, so the real shape (I-beam, hand, spinner) is lost and unrecoverable.
///
/// Rule 5 confines `CGPoint`/`CGRect`/`CGSize`/`CGFloat` to `HeadlessGeometryBridge`, so every
/// `CGPoint` comes from it and the ripple is four cubic Bézier arcs rather than
/// `CGPath(ellipseIn:)`, which would need a `CGRect`.
///
/// `nonisolated` is required under `-default-isolation MainActor`: otherwise these functions could
/// not be called from `CoreImageFrameRenderer.render`, which runs nonisolated on AVFoundation's queue.
nonisolated enum CursorArt {
    /// Arrow silhouette outline, tip at the origin, body toward positive `x` and negative `y` —
    /// the bottom-left-origin convention a self-built `CGContext` uses. Callers translate so the
    /// tip lands on the recorded position.
    private static let outline: [(x: Double, y: Double)] = [
        (0, 0), (0, -22), (5, -17), (8.5, -24.5), (11.5, -23), (8, -15.5), (16, -15.5),
    ]

    /// The largest coordinate magnitude in `outline` at `scale == 1`, for callers sizing a canvas.
    public static let pointerMaxExtent: Double = 24.5

    /// The arrow silhouette scaled uniformly by `scale`, as a closed path to fill and/or stroke.
    public static func pointerPath(scale: Double) -> CGPath {
        let path = CGMutablePath()
        let first = outline[0]
        path.move(to: HeadlessGeometryBridge.point(x: first.x * scale, y: first.y * scale))
        for point in outline.dropFirst() {
            path.addLine(to: HeadlessGeometryBridge.point(x: point.x * scale, y: point.y * scale))
        }
        path.closeSubpath()
        return path
    }

    /// The ripple's radius at the click instant; non-zero so the first frame shows a ring.
    /// The I-beam, three rects in one path — stem plus two serifs — built around the
    /// HOTSPOT at the origin, which for an I-beam is its centre (the arrow's is its tip).
    /// Drawn with the same white-fill/black-stroke treatment as the arrow so the two read
    /// as one cursor family. Half-height 14 at scale 1: inside `pointerMaxExtent`, so the
    /// canvas the renderer sizes for the arrow already fits it.
    public static func iBeamPath(scale s: Double) -> CGPath {
        let path = CGMutablePath()
        let stemHalfWidth = 1.2 * s
        let halfHeight = 14.0 * s
        let serifHalfWidth = 5.0 * s
        let serifThickness = 2.4 * s
        // Point-by-point through the bridge, like `pointerPath` above: the rect type is
        // confined to the two bridge files (rule 5), and its absence here is enforced,
        // not stylistic — `coreGraphicsGeometryTypesAppearOnlyInTheHeadlessBridge` went
        // red on this function's first draft, which reached for the rect initialiser.
        func closedRect(x: Double, y: Double, width: Double, height: Double) {
            path.move(to: HeadlessGeometryBridge.point(x: x, y: y))
            path.addLine(to: HeadlessGeometryBridge.point(x: x + width, y: y))
            path.addLine(to: HeadlessGeometryBridge.point(x: x + width, y: y + height))
            path.addLine(to: HeadlessGeometryBridge.point(x: x, y: y + height))
            path.closeSubpath()
        }
        closedRect(x: -stemHalfWidth, y: -halfHeight,
                   width: stemHalfWidth * 2, height: halfHeight * 2)
        closedRect(x: -serifHalfWidth, y: halfHeight - serifThickness,
                   width: serifHalfWidth * 2, height: serifThickness)
        closedRect(x: -serifHalfWidth, y: -halfHeight,
                   width: serifHalfWidth * 2, height: serifThickness)
        return path
    }

    static let rippleStartRadius: Double = 6
    /// The ripple's radius at `phase == 1`, in `pointerMaxExtent`'s output-pixel unit and not
    /// scaled by `pointerPath`'s `scale`.
    public static let rippleEndRadius: Double = 28

    /// κ, the control-point offset (as a fraction of the radius) approximating a quarter-circle
    /// arc with one cubic Bézier segment.
    private static let circleKappa = 0.5522847498307936

    /// A circle at the origin whose radius interpolates start to end as `phase` runs `0...1`,
    /// clamped to that range. The caller fades the stroke alpha; a `CGPath` carries none.
    public static func ripplePath(phase: Double, size: Double = 1) -> CGPath {
        let clamped = min(max(phase, 0), 1)
        let radius = (rippleStartRadius + (rippleEndRadius - rippleStartRadius) * clamped) * size
        let k = radius * circleKappa

        let path = CGMutablePath()
        path.move(to: HeadlessGeometryBridge.point(x: radius, y: 0))
        path.addCurve(to: HeadlessGeometryBridge.point(x: 0, y: radius),
                      control1: HeadlessGeometryBridge.point(x: radius, y: k),
                      control2: HeadlessGeometryBridge.point(x: k, y: radius))
        path.addCurve(to: HeadlessGeometryBridge.point(x: -radius, y: 0),
                      control1: HeadlessGeometryBridge.point(x: -k, y: radius),
                      control2: HeadlessGeometryBridge.point(x: -radius, y: k))
        path.addCurve(to: HeadlessGeometryBridge.point(x: 0, y: -radius),
                      control1: HeadlessGeometryBridge.point(x: -radius, y: -k),
                      control2: HeadlessGeometryBridge.point(x: -k, y: -radius))
        path.addCurve(to: HeadlessGeometryBridge.point(x: radius, y: 0),
                      control1: HeadlessGeometryBridge.point(x: k, y: -radius),
                      control2: HeadlessGeometryBridge.point(x: radius, y: -k))
        path.closeSubpath()
        return path
    }
}
