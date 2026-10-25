import AppKit
import QuartzCore
import Testing
@testable import Soredemo

/// How the editor's content arrives: scaled about its centre. **A layer off the origin's size
/// and not square**, so a scale about the corner — what a layer anchored at its corner does
/// unasked — or one with the axes swapped cannot pass.
@MainActor @Suite struct EditorOpeningTests {
    func apply(_ t: CATransform3D, _ x: Double, _ y: Double) -> (x: Double, y: Double) {
        (x * Double(t.m11) + y * Double(t.m21) + Double(t.m41), x * Double(t.m12) + y * Double(t.m22) + Double(t.m42))
    }

    @Test func theContentArrivesScaledAboutItsCentre() {
        let t = EditorOpening.scaledAboutCentre(width: 1512, height: 862, scale: 0.9)
        let centre = apply(t, 756, 431)
        #expect(abs(centre.x - 756) < 0.001 && abs(centre.y - 431) < 0.001, "the centre moved: \(centre)")
        let corner = apply(t, 0, 0)
        #expect(abs(corner.x - 75.6) < 0.001 && abs(corner.y - 43.1) < 0.001, "the corner moves in: \(corner)")
        let far = apply(t, 1512, 862)
        #expect(abs(far.x - 1436.4) < 0.001 && abs(far.y - 818.9) < 0.001, "the far corner moves in: \(far)")
    }
}
