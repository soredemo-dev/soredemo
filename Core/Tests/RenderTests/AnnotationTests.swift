import Foundation
import Testing
@testable import Render

/// The annotation value types: what they refuse, and what they compute.
///
/// **`AnnotationStyle` is `Codable` with a synthesised decoder**, which never calls the
/// validating initialiser — rule 8's exact case. `clamped` is the answer and these tests are
/// what say it is applied rather than merely present, which is the failure
/// `CameraOverlayStyle.borderOpacity` had: a public option nothing exercised, so nothing said.
@Suite struct AnnotationTests {

    // MARK: - the style

    @Test func aStrokeCannotBeClampedToNothing() {
        // The floor is the point: a zero-width stroke is an annotation that silently does not
        // exist, and "silently" is what makes it worse than an error.
        let vanishing = AnnotationStyle.default.changing(strokeWidthFraction: 0)
        #expect(vanishing.strokeWidthFraction > 0)
        #expect(vanishing.strokeWidth(forOutputWidth: 1920, outputHeight: 1080) >= 1)
    }

    @Test func everyStyleFieldIsClampedIntoItsRange() {
        let absurd = AnnotationStyle(strokeWidthFraction: 99, red: -3, green: 4, blue: .infinity,
                                     alpha: 2, fillOpacity: -1,
                                     shadowOpacity: 7, shadowBlurFraction: 9)
        #expect(absurd.strokeWidthFraction <= 0.08)
        #expect(absurd.red == 0)
        #expect(absurd.green == 1)
        #expect(absurd.alpha == 1)
        #expect(absurd.fillOpacity == 0)
        #expect(absurd.shadowOpacity == 1)
        #expect(absurd.shadowBlurFraction <= 0.05)
        // `.infinity` clamps to 1 rather than propagating, because `min(max(inf, 0), 1)` is 1.
        // NaN would NOT — see `AnnotationItem`'s own clamp, which is why that one is written out
        // by hand instead of reusing this expression.
        #expect(absurd.blue == 1)
    }

    /// The synthesised decoder assigns stored properties directly, so a hand-edited project file
    /// reaches the renderer unclamped unless something puts it back in range. `clamped` is that
    /// something, and this is the test that says so.
    @Test func aDecodedStyleOutsideItsRangeIsBroughtBackByClamped() throws {
        let json = """
        {"strokeWidthFraction": 50, "red": 9, "green": -9, "blue": 0.5, "alpha": 88,
         "fillOpacity": 3, "shadowOpacity": -2, "shadowBlurFraction": 40}
        """
        let decoded = try JSONDecoder().decode(AnnotationStyle.self,
                                               from: Data(json.utf8))
        // Decoding really did bypass the initialiser — otherwise this test proves nothing about
        // `clamped`, because the value would already be in range.
        #expect(decoded.strokeWidthFraction == 50, """
            the synthesised decoder no longer bypasses the initialiser, so this test's premise \
            has changed: the value would already be in range and `clamped` would be doing \
            nothing observable below.
            """)
        let safe = decoded.clamped
        #expect(safe.strokeWidthFraction <= 0.08)
        #expect(safe.red == 1 && safe.green == 0 && safe.alpha == 1)
        #expect(safe.fillOpacity == 1 && safe.shadowOpacity == 0)
    }

    /// The shorter edge, not the height. A stroke picked in landscape must weigh the same in the
    /// portrait variant of the same recording — which is the whole reason the fraction is not of
    /// the height.
    @Test func aStrokeWeighsTheSameInLandscapeAndPortrait() {
        let style = AnnotationStyle.default
        let landscape = style.strokeWidth(forOutputWidth: 1920, outputHeight: 1080)
        let portrait = style.strokeWidth(forOutputWidth: 1080, outputHeight: 1920)
        #expect(landscape == portrait)
    }

    // MARK: - the overlay

    private func overlay(_ shape: AnnotationShape = .arrow,
                         from: (Double, Double) = (100, 100),
                         to: (Double, Double) = (400, 500),
                         style: AnnotationStyle = .default,
                         opacity: Double = 1, scale: Double = 1) -> AnnotationOverlay {
        AnnotationOverlay(shape: shape, startX: from.0, startY: from.1,
                          endX: to.0, endY: to.1, style: style, opacity: opacity, scale: scale)
    }

    @Test func lengthIsTheDistanceBetweenTheTwoPoints() {
        // 3-4-5, so the expected value is exact rather than a tolerance.
        let a = overlay(from: (0, 0), to: (300, 400))
        #expect(a.length == 500)
    }

    @Test func aBoundingBoxIsTheSameWhicheverCornerTheDragStartedAt() {
        let downLeft = overlay(.rectangle, from: (400, 500), to: (100, 100)).boundingBox
        let upRight = overlay(.rectangle, from: (100, 100), to: (400, 500)).boundingBox
        #expect(downLeft.x == upRight.x && downLeft.y == upRight.y)
        #expect(downLeft.width == upRight.width && downLeft.height == upRight.height)
        #expect(downLeft.x == 100 && downLeft.y == 100)
        #expect(downLeft.width == 300 && downLeft.height == 400)
    }

    /// Two ways to be empty, and both must be caught before a bitmap is allocated for them: a
    /// click that never became a drag, and an annotation faded fully out.
    @Test func anAnnotationWithNoLengthOrNoOpacityIsEmpty() {
        #expect(overlay(from: (200, 200), to: (200, 200)).isEmpty)
        #expect(overlay(opacity: 0).isEmpty)
        #expect(!overlay().isEmpty)
    }

    @Test func opacityIsClampedButScaleIsNot() {
        #expect(overlay(opacity: 5).opacity == 1)
        #expect(overlay(opacity: -5).opacity == 0)
        // Scale is deliberately unclamped: `TextAnimation.pop` overshoots past 1 on purpose, and
        // a clamp here would flatten the overshoot that makes it read as a pop.
        #expect(overlay(scale: 1.06).scale == 1.06)
    }

    // MARK: - the shapes

    @Test func onlyClosedShapesCanBeFilled() {
        #expect(AnnotationShape.rectangle.canBeFilled)
        #expect(AnnotationShape.ellipse.canBeFilled)
        #expect(!AnnotationShape.arrow.canBeFilled)
        #expect(!AnnotationShape.line.canBeFilled)
    }

    /// Raw values are the on-disk vocabulary for every saved project, so renaming a case is a
    /// wire-breaking change — the same claim `FramingRejection`'s header makes about its own.
    @Test func theShapeNamesOnDiskAreTheOnesEverySavedProjectUses() {
        #expect(AnnotationShape.allCases.map(\.rawValue).sorted()
                == ["arrow", "ellipse", "line", "rectangle"])
    }

    @Test func everyShapeHasItsOwnDisplayName() {
        let names = AnnotationShape.allCases.map(\.displayName)
        #expect(Set(names).count == names.count)
    }
}
