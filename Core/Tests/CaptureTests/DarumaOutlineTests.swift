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
