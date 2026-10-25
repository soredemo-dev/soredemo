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
