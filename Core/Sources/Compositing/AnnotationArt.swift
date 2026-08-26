import CoreGraphics
import Foundation
import Render

/// The paths an annotation is drawn from.
///
/// Three, not one, because they are drawn with three different settings and a single path would
/// have to be drawn three times to get them: the outline in the stroke colour at the stroke
/// width, the arrow's head as a solid in that same colour, and the interior at whatever
/// `fillOpacity` says. `CursorArt` splits its ripple out of its pointer for the same reason.
///
/// A `nil` member is "this shape has none", never "not computed": an arrow has no interior, a
/// rectangle has no head, and a rectangle at `fillOpacity == 0` has an interior it does not want
/// drawn. Each refusal is a value rather than an empty path, so a caller cannot mistake "nothing
/// here" for "an empty shape here" — which draws nothing either way but means something else.
struct AnnotationArtwork {
    /// The outline, to be stroked. Every shape has one.
    let stroked: CGPath
    /// The arrow's head, filled with the STROKE colour — it is part of the line, not a fill the
    /// person chose. `nil` for every other shape.
    let head: CGPath?
    /// The area inside a closed shape, filled at `AnnotationStyle.fillOpacity`. `nil` for an
    /// arrow or a line, which enclose nothing, and for a closed shape whose fill is zero.
    let interior: CGPath?
}

/// Arrows, lines, boxes and ellipses, as paths in a local space.
///
/// **Built around a caller-supplied origin rather than around the frame.** The renderer draws
/// these into a bitmap the size of the annotation, not the size of the output — a 1920×1080
/// canvas per annotation per frame is the allocation `RedactionArt.masked`'s header refuses —
/// so every coordinate here is relative to the bottom-left of that bitmap. The caller passes the
/// same origin it positions the finished image at, and `padding(for:)` is what makes the two
/// agree about how much room the stroke and its shadow need.
///
/// **Bottom-left origin throughout**, which is `CGContext`'s own convention for a
/// self-built bitmap and Core Image's. `AnnotationOverlay`'s points are already in that space —
/// `AnnotationTrack`'s header explains why they are stored that way — so there is no flip here,
/// and there must not be one.
enum AnnotationArt {
    /// How far outside the two points the drawing can reach: half the stroke sits outside the
    /// path it is centred on, the shadow spreads further, and an arrow's head is wider than its
    /// shaft. Under-estimating this clips the drawing at the bitmap's edge — silently, and only
    /// on the side the shadow falls — so it is computed once here and used by both the canvas
    /// size and the placement.
    static func padding(for overlay: AnnotationOverlay, strokeWidth: Double,
                        shadowBlur: Double) -> Double {
        let head = overlay.shape == .arrow ? headLength(for: overlay, strokeWidth: strokeWidth)
                                           : 0
        // **Three blur radii, not one.** A Core Graphics shadow spreads well past its stated
        // radius — the radius is the Gaussian's sigma, not its support — and the drawing is
        // clipped at the bitmap's edge silently when the canvas is too small. Three is the
        // conventional cut-off for a Gaussian's visible extent; the `+ 2` on the end is for the
        // half-pixel each side that antialiasing reaches.
        return strokeWidth / 2 + shadowBlur * 3 + head / 2 + 2
    }

    /// The two points after the animation's scale, in output pixels.
    ///
    /// **One definition, used by both the canvas and the paths.** They were computed separately
    /// in the first draft — the canvas from the unscaled bounding box, the paths from the scaled
    /// points — which is fine at `scale == 1` and clips the drawing at every other value. That
    /// is a defect visible only during the 0.35 s an annotation is arriving, which is the sort
    /// that ships.
    ///
    /// The scale is about the annotation's own centre, so a `pop` grows outward from the shape
    /// rather than sliding it toward the frame's origin.
    static func scaledPoints(of overlay: AnnotationOverlay)
    -> (from: (x: Double, y: Double), to: (x: Double, y: Double)) {
        let centreX = (overlay.startX + overlay.endX) / 2
        let centreY = (overlay.startY + overlay.endY) / 2
        return (from: (x: centreX + (overlay.startX - centreX) * overlay.scale,
                       y: centreY + (overlay.startY - centreY) * overlay.scale),
                to: (x: centreX + (overlay.endX - centreX) * overlay.scale,
                     y: centreY + (overlay.endY - centreY) * overlay.scale))
    }

    /// The bitmap this annotation needs, in output pixels: where its bottom-left corner goes and
    /// how big it is. `nil` when there is nothing to draw, so the caller allocates nothing.
    ///
    /// **Scalars, not a rect** — rule 5 keeps `CGRect` inside the bridge, and a return type
    /// names it as surely as a literal does.
    static func canvas(for overlay: AnnotationOverlay, strokeWidth: Double, shadowBlur: Double)
    -> (x: Double, y: Double, width: Double, height: Double)? {
        guard !overlay.isEmpty else { return nil }
        let points = scaledPoints(of: overlay)
        let pad = padding(for: overlay, strokeWidth: strokeWidth, shadowBlur: shadowBlur)
        let minX = Swift.min(points.from.x, points.to.x) - pad
        let minY = Swift.min(points.from.y, points.to.y) - pad
        let maxX = Swift.max(points.from.x, points.to.x) + pad
        let maxY = Swift.max(points.from.y, points.to.y) + pad
        return (x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// **The head's length, and the two constants in it are the shape of the arrow.**
    ///
    /// `4.5 × strokeWidth` is what reads as an arrowhead rather than as a dart or a wedge; below
    /// about three it disappears into the shaft's own width and the line stops pointing at
    /// anything. The cap at `0.4 × length` is the case that matters: a short arrow — someone
    /// nudging at a control ten pixels away — would otherwise be almost entirely head, which
    /// reads as a triangle that happens to have a stub attached.
    static func headLength(for overlay: AnnotationOverlay, strokeWidth: Double) -> Double {
        min(strokeWidth * 4.5, overlay.length * 0.4)
    }

    /// The artwork for `overlay`, with every coordinate relative to `(originX, originY)`.
    ///
    /// Returns `nil` for an annotation with nothing to draw, so the caller skips the bitmap
    /// entirely rather than allocating one and drawing an empty path into it.
    static func artwork(for overlay: AnnotationOverlay, strokeWidth: Double,
                        originX: Double, originY: Double) -> AnnotationArtwork? {
        guard !overlay.isEmpty else { return nil }

        // **The scale is applied to the geometry, not to the finished image.** A transform on
        // the bitmap would scale the stroke with it, so an arrow would thicken while it arrived
        // and settle at a weight nobody chose. Same argument as `AnnotationOverlay`'s "position
        // follows the content; size does not", one level down.
        let points = scaledPoints(of: overlay)
        let from = (x: points.from.x - originX, y: points.from.y - originY)
        let to = (x: points.to.x - originX, y: points.to.y - originY)

        switch overlay.shape {
        case .line:
            return AnnotationArtwork(stroked: segment(from: from, to: to), head: nil,
                                     interior: nil)
        case .arrow:
            return arrowArtwork(from: from, to: to, overlay: overlay, strokeWidth: strokeWidth)
        case .rectangle, .ellipse:
            let x = Swift.min(from.x, to.x)
            let y = Swift.min(from.y, to.y)
            let width = abs(to.x - from.x)
            let height = abs(to.y - from.y)
            // A degenerate box — a drag along one axis only — has no interior worth filling and
            // an ellipse in it is a line. Stroked as a line so the annotation still exists;
            // returning nothing would make a deliberate horizontal underline vanish.
            guard width > 0, height > 0 else {
                return AnnotationArtwork(stroked: segment(from: from, to: to), head: nil,
                                         interior: nil)
            }
            let box = HeadlessGeometryBridge.rect(x: x, y: y, width: width, height: height)
            // `unsafe`: both initialisers take `transform` as an `UnsafePointer<CGAffineTransform>?`,
            // which the strict-memory-safety gate counts whatever is passed to it. Safe here —
            // `nil` is the documented "no transform" argument, so nothing is dereferenced and
            // there is no pointer whose lifetime could be wrong. `CursorArt`'s header records
            // avoiding `CGPath(ellipseIn:)` for the CGRect it needs; the bridge answers that half
            // (rule 5), and this comment answers the other.
            let outline = overlay.shape == .ellipse
                ? unsafe CGPath(ellipseIn: box, transform: nil)
                : unsafe CGPath(rect: box, transform: nil)
            return AnnotationArtwork(
                stroked: outline, head: nil,
                interior: overlay.style.fillOpacity > 0 ? outline : nil)
        }
    }

    private static func segment(from: (x: Double, y: Double),
                                to: (x: Double, y: Double)) -> CGPath {
        let path = CGMutablePath()
        path.move(to: HeadlessGeometryBridge.point(x: from.x, y: from.y))
        path.addLine(to: HeadlessGeometryBridge.point(x: to.x, y: to.y))
        return path
    }

    /// A shaft and a filled head.
    ///
    /// **The shaft stops short of the tip.** Running it all the way to the end and drawing the
    /// head over it works until the stroke is wide, at which point the round cap pokes out past
    /// the head's point and blunts it. Ending the shaft `0.55 ×` the head length back leaves the
    /// head overlapping it — no seam where the two meet, and the point stays a point.
    private static func arrowArtwork(from: (x: Double, y: Double), to: (x: Double, y: Double),
                                     overlay: AnnotationOverlay,
                                     strokeWidth: Double) -> AnnotationArtwork? {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = (dx * dx + dy * dy).squareRoot()
        // Guarded rather than assumed non-zero: `overlay.isEmpty` is checked against the
        // UNSCALED points, and a scale of zero — the first frame of a `pop` — brings these two
        // together while the annotation is still legitimately on screen.
        guard length > 0 else { return nil }
        let ux = dx / length
        let uy = dy / length

        let head = Swift.min(headLength(for: overlay, strokeWidth: strokeWidth), length)
        let shaftEnd = (x: to.x - ux * head * 0.55, y: to.y - uy * head * 0.55)

        // **0.42 of the head's length, each side.** That is an apex of about 46°, which is what
        // reads as an arrow; much narrower is a needle and much wider is a chevron.
        let halfWidth = head * 0.42
        let baseX = to.x - ux * head
        let baseY = to.y - uy * head
        // The perpendicular, which is the direction rotated a quarter turn.
        let px = -uy
        let py = ux

        let headPath = CGMutablePath()
        headPath.move(to: HeadlessGeometryBridge.point(x: to.x, y: to.y))
        headPath.addLine(to: HeadlessGeometryBridge.point(x: baseX + px * halfWidth,
                                                          y: baseY + py * halfWidth))
        headPath.addLine(to: HeadlessGeometryBridge.point(x: baseX - px * halfWidth,
                                                          y: baseY - py * halfWidth))
        headPath.closeSubpath()

        return AnnotationArtwork(stroked: segment(from: from, to: shaftEnd), head: headPath,
                                 interior: nil)
    }
}
