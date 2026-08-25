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

    /// The largest coordinate magnitude any of this file's shapes reaches at `scale == 1`, for
    /// callers sizing a canvas. **Every shape, not just the arrow** — it was the arrow's alone
    /// while the arrow was the only art, and a shape that outgrew it would be clipped at the
    /// bitmap's edge rather than drawn. `noShapeOutgrowsTheCanvasItIsDrawnOn` measures each
    /// path's own bounding box against it, so adding a fifth shape that does not fit is a red
    /// test rather than a corner missing from a frame.
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

    /// **The pointing hand, built around its FINGERTIP** — which is where the system puts this
    /// cursor's hotspot, measured on this machine at (0.406, 0.250) of its image
    /// (`PointerSample.hotspot`). Every path in this file is built around its own hotspot at
    /// the origin, because the renderer draws that origin at the recorded position and applies
    /// no offset; a hand built around its centre would sit half a cursor from where the person
    /// pointed.
    ///
    /// One closed silhouette: down the index finger's left edge, out around the thumb and the
    /// fist, up the right, over three knuckle humps, and back up the finger's right edge. The
    /// humps are what make it read as a hand rather than a mitten at 24 px, which is the size
    /// it is actually drawn at.
    public static func pointingHandPath(scale s: Double) -> CGPath {
        closedPath(of: [
            (0, 0),                                          // the fingertip: the hotspot
            (-2.6, -2.0), (-2.6, -12.5),                     // the finger's left edge
            (-4.8, -13.0), (-6.4, -15.0), (-6.7, -18.4),     // the thumb
            (-5.7, -21.6), (-3.4, -23.4),                    // the fist's lower left
            (-0.5, -24.0), (5.4, -24.0),                     // across the bottom
            (8.3, -22.8), (9.8, -20.4), (10.0, -13.8), (8.9, -11.7),
            (7.1, -11.2), (7.1, -13.0),                      // three knuckles, right to left
            (5.1, -11.2), (5.1, -13.0),
            (3.1, -11.2),
            (2.6, -12.5), (2.6, -2.0),                       // the finger's right edge
        ], scale: s)
    }

    /// **The crosshair: four arms around a gap, centred on the origin.** Its hotspot is its
    /// centre — measured at (0.458, 0.458), which is the centre to within the rounding of a
    /// 32 px image — so the path is built symmetrically about zero.
    ///
    /// Four subpaths rather than two crossing bars, because the gap IS the shape: a precision
    /// cursor leaves the pixel it is pointing at visible, and a solid plus covers it. Same
    /// multi-subpath construction `iBeamPath` uses.
    public static func crosshairPath(scale s: Double) -> CGPath {
        let path = CGMutablePath()
        let halfThickness = 1.2 * s
        let gap = 3.0 * s
        let reach = 15.0 * s
        // Point-by-point through the bridge, like every other path here: rule 5 keeps the rect
        // initialiser out of this file, and its absence is enforced rather than stylistic.
        func arm(minX: Double, minY: Double, maxX: Double, maxY: Double) {
            path.move(to: HeadlessGeometryBridge.point(x: minX, y: minY))
            path.addLine(to: HeadlessGeometryBridge.point(x: maxX, y: minY))
            path.addLine(to: HeadlessGeometryBridge.point(x: maxX, y: maxY))
            path.addLine(to: HeadlessGeometryBridge.point(x: minX, y: maxY))
            path.closeSubpath()
        }
        arm(minX: -halfThickness, minY: gap, maxX: halfThickness, maxY: reach)
        arm(minX: -halfThickness, minY: -reach, maxX: halfThickness, maxY: -gap)
        arm(minX: -reach, minY: -halfThickness, maxX: -gap, maxY: halfThickness)
        arm(minX: gap, minY: -halfThickness, maxX: reach, maxY: halfThickness)
        return path
    }

    /// **The horizontal resize cursor: a double-headed arrow, centred.** A shaft between two
    /// triangular heads, as one closed outline — the shape a person drags a column divider
    /// with. Centred for the same reason the crosshair is.
    public static func resizeLeftRightPath(scale s: Double) -> CGPath {
        closedPath(of: [
            (-15, 0), (-8, -5.5), (-8, -2),      // the left head, then into the shaft
            (8, -2), (8, -5.5),
            (15, 0), (8, 5.5), (8, 2),           // the right head, then back along the shaft
            (-8, 2), (-8, 5.5),
        ], scale: s)
    }

    /// The vertical twin, transposed. Written out rather than derived by swapping the axes of
    /// the path above: a transform would need `CGAffineTransform`, and the two shapes reading
    /// identically in this file is worth more than the four lines it saves.
    public static func resizeUpDownPath(scale s: Double) -> CGPath {
        closedPath(of: [
            (0, -15), (-5.5, -8), (-2, -8),
            (-2, 8), (-5.5, 8),
            (0, 15), (5.5, 8), (2, 8),
            (2, -8), (5.5, -8),
        ], scale: s)
    }

    /// One closed polygon from scaled points. The shape `pointerPath` builds by hand, factored
    /// out once the third caller appeared.
    private static func closedPath(of points: [(x: Double, y: Double)], scale: Double) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: HeadlessGeometryBridge.point(x: first.x * scale, y: first.y * scale))
        for point in points.dropFirst() {
            path.addLine(to: HeadlessGeometryBridge.point(x: point.x * scale, y: point.y * scale))
        }
        path.closeSubpath()
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
