import CoreGraphics
import Geometry
import Testing
@testable import Capture

/// The daruma's body, as the app draws it: the brand kit's path in a 100-unit box, mapped onto
/// any rectangle. **Off the origin and at twice the scale**, so a mapping that forgot either the
/// offset or the scale cannot pass by accident.
@Test func theDarumaFillsItsBoxAsTheBrandKitDrawsIt() {
    let path = CGGeometryBridge.darumaOutline(in: PointRect(x: 10, y: 20, width: 200, height: 200))
    let bounds = path.boundingBoxOfPath
    // The body spans x 14…86 and y 8…92 of its 100-unit box.
    #expect(abs(bounds.minX - 38) < 0.5 && abs(bounds.maxX - 182) < 0.5, "x \(bounds.minX)…\(bounds.maxX)")
    #expect(abs(bounds.minY - 36) < 0.5 && abs(bounds.maxY - 204) < 0.5, "y \(bounds.minY)…\(bounds.maxY)")
    // Egg-shaped: the box's middle is inside, its top corners are not.
    #expect(path.contains(CGPoint(x: 110, y: 120)))
    #expect(!path.contains(CGPoint(x: 40, y: 40)) && !path.contains(CGPoint(x: 180, y: 40)))
}

/// The countdown's ring starts at twelve o'clock and runs clockwise on screen — y down — so a
/// quarter left is the arc from the top to three o'clock, and nothing left draws nothing.
/// Centred off the origin so an arc drawn about (0, 0) cannot pass.
@Test func theCountdownArcRunsClockwiseFromTheTop() {
    let quarter = CGGeometryBridge.countdownArc(centreX: 40, centreY: 60, radius: 10, remaining: 0.25)
    let box = quarter.boundingBoxOfPath
    #expect(abs(box.minX - 40) < 0.01 && abs(box.maxX - 50) < 0.01, "x \(box.minX)…\(box.maxX)")
    #expect(abs(box.minY - 50) < 0.01 && abs(box.maxY - 60) < 0.01, "y \(box.minY)…\(box.maxY)")
    #expect(abs(quarter.currentPoint.x - 50) < 0.01 && abs(quarter.currentPoint.y - 60) < 0.01,
            "ends at three o'clock, not nine: \(quarter.currentPoint)")
    #expect(CGGeometryBridge.countdownArc(centreX: 40, centreY: 60, radius: 10, remaining: 0).isEmpty)
}

/// The character's body: the brand kit's egg from width, height and crown, in a box off the
/// origin at twice the scale. At 1, 1 it spans the box's own 11…89 by 11…93 units — measured in
/// the box, so an outline that ignored the offset or the scale lands elsewhere.
@Test func theCharactersBodyFillsItsBoxFromItsParameters() {
    let path = CGGeometryBridge.darumaBody(width: 1, height: 1, crown: 1.15,
                                           in: PointRect(x: 10, y: 20, width: 200, height: 200))
    let b = path.boundingBoxOfPath
    #expect(abs(b.minX - (10 + 11 * 2)) < 0.6 && abs(b.maxX - (10 + 89 * 2)) < 0.6, "x \(b.minX)…\(b.maxX)")
    #expect(abs(b.minY - (20 + 11 * 2)) < 0.6 && abs(b.maxY - (20 + 93 * 2)) < 0.6, "y \(b.minY)…\(b.maxY)")
    // A wider, shorter body is wider and shorter: the parameters reach the outline.
    let squat = CGGeometryBridge.darumaBody(width: 1.1, height: 0.9, crown: 1, in: PointRect(x: 10, y: 20, width: 200, height: 200)).boundingBoxOfPath
    #expect(squat.width > b.width && squat.height < b.height)
}

/// A pill and an ellipse turned about their own centres: a tall pill turned 90° lies down, its
/// centre where it was. Off the origin, so a turn about (0, 0) moves it and fails.
@Test func aTurnedPillAndEllipseTurnAboutTheirCentres() {
    let upright = CGGeometryBridge.pill(centreX: 60, centreY: 40, width: 6, height: 20, tilt: 0).boundingBoxOfPath
    let lying = CGGeometryBridge.pill(centreX: 60, centreY: 40, width: 6, height: 20, tilt: 90).boundingBoxOfPath
    #expect(abs(upright.width - 6) < 0.01 && abs(upright.height - 20) < 0.01)
    #expect(abs(lying.width - 20) < 0.01 && abs(lying.height - 6) < 0.01)
    #expect(abs(lying.midX - 60) < 0.01 && abs(lying.midY - 40) < 0.01)
    let e = CGGeometryBridge.ellipse(centreX: 30, centreY: 70, radiusX: 10, radiusY: 4, tilt: 90).boundingBoxOfPath
    #expect(abs(e.width - 8) < 0.05 && abs(e.height - 20) < 0.05 && abs(e.midX - 30) < 0.01)
}

/// A stroked arc is a fillable band: it contains its own midpoint and not a point a line-width
/// away from it.
@Test func aStrokedArcIsABandAlongTheCurve() {
    let arc = CGGeometryBridge.strokedArc(fromX: 40, fromY: 50, controlX: 50, controlY: 40, toX: 60, toY: 50, lineWidth: 3)
    #expect(arc.contains(CGPoint(x: 50, y: 45)), "the curve's midpoint")
    #expect(!arc.contains(CGPoint(x: 50, y: 50)), "inside the curve, off the band")
}

/// The brush that paints the record eye: one clockwise sweep from twelve o'clock, so a stroke as
/// wide as the radius covers the disc when drawn whole. Off the origin, so an outline that ignored
/// the centre lands elsewhere.
@Test func theBrushSweepsTheEyeClockwiseFromTwelve() {
    let path = CGGeometryBridge.brushSweep(centreX: 40, centreY: 60, radius: 10)
    let stroke = path.copy(strokingWithWidth: 10, lineCap: .round, lineJoin: .round, miterLimit: 1)
    let missed = stride(from: -9.5, through: 9.5, by: 0.5).flatMap { dx in
        stride(from: -9.5, through: 9.5, by: 0.5).map { (dx, $0) }
    }.filter { hypot($0.0, $0.1) <= 9.5 && !stroke.contains(CGPoint(x: 40 + $0.0, y: 60 + $0.1)) }
    #expect(missed.isEmpty, "unpainted: \(missed.prefix(5))")
    // A quarter painted, the brush is at three o'clock — clockwise, not at nine.
    let quarter = CGGeometryBridge.brushSweep(centreX: 40, centreY: 60, radius: 10, painted: 0.25).currentPoint
    #expect(abs(quarter.x - 45) < 0.01 && abs(quarter.y - 60) < 0.01, "\(quarter)")
    #expect(CGGeometryBridge.brushSweep(centreX: 40, centreY: 60, radius: 10, painted: 0).isEmpty)
}

/// A pause bar: an upright rectangle with rounded corners, centred where it is put — off the origin.
@Test func aBarIsAnUprightRoundedRectangleAboutItsCentre() {
    let bar = CGGeometryBridge.bar(centreX: 40, centreY: 60, width: 6, height: 16, corner: 1.5)
    let box = bar.boundingBoxOfPath
    #expect(abs(box.midX - 40) < 0.01 && abs(box.midY - 60) < 0.01 && abs(box.width - 6) < 0.01 && abs(box.height - 16) < 0.01, "\(box)")
    #expect(bar.contains(CGPoint(x: 40, y: 67.5)) && !bar.contains(CGPoint(x: 37.05, y: 52.05)), "square-ish, its corners rounded")
}
