import Foundation

/// The daruma character's body as four cubic curves in its 100-unit box, y down — **the one
/// statement of the shape**: the renderer's bridge strokes these, and the figure asks them
/// whether its face is still on the body. From width, height and crown roundness; at 1, 1 it
/// spans 11…89 across and 11…93 down, its base fixed at 93 so a squash sits it down.
/// `docs/design/2026-10-26-a-character-not-a-logo.md`.
public enum DarumaBodyCurve {
    public struct Point: Equatable, Sendable {
        public let x: Double, y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    /// A cubic segment from the previous end: two controls and an end.
    public struct Segment: Equatable, Sendable {
        public let control1: Point, control2: Point, end: Point
    }

    /// Where the outline starts — the crown — and its four segments, clockwise on screen.
    public static func outline(width w: Double, height h: Double, crown: Double) -> (start: Point, segments: [Segment]) {
        let cx = 50.0, base = 93.0, height = 82 * h, half = 39 * w
        let top = base - height, mid = top + height * 0.55, reach = 22 * crown * w
        func p(_ x: Double, _ y: Double) -> Point { Point(x: x, y: y) }
        return (p(cx, top), [
            Segment(control1: p(cx + reach, top), control2: p(cx + half, top + height * 0.24), end: p(cx + half, mid)),
            Segment(control1: p(cx + half, mid + height * 0.27), control2: p(cx + half * 0.62, base), end: p(cx, base)),
            Segment(control1: p(cx - half * 0.62, base), control2: p(cx - half, mid + height * 0.27), end: p(cx - half, mid)),
            Segment(control1: p(cx - half, top + height * 0.24), control2: p(cx - reach, top), end: p(cx, top)),
        ])
    }

    /// Whether a point is on the body: the outline sampled into a polygon fine enough that the
    /// difference from the curve is a hundredth of a unit, and an even-odd ray test.
    public static func contains(x: Double, y: Double, width w: Double, height h: Double, crown: Double) -> Bool {
        let (start, segments) = outline(width: w, height: h, crown: crown)
        var polygon: [Point] = []
        var from = start
        for segment in segments {
            for step in 0..<48 {
                let t = Double(step) / 48, u = 1 - t
                let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                polygon.append(Point(x: a * from.x + b * segment.control1.x + c * segment.control2.x + d * segment.end.x,
                                     y: a * from.y + b * segment.control1.y + c * segment.control2.y + d * segment.end.y))
            }
            from = segment.end
        }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let pi = polygon[i], pj = polygon[j]
            if (pi.y > y) != (pj.y > y), x < (pj.x - pi.x) * (y - pi.y) / (pj.y - pi.y) + pi.x { inside.toggle() }
            j = i
        }
        return inside
    }
}
