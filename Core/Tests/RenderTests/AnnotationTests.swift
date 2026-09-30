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

    /// **Rewritten 2026-09-25, because the premise it guarded is gone.** It used to assert that
    /// the synthesised decoder bypassed the initialiser and that `clamped` put values back in
    /// range afterwards — and its own failure message said that if the decoder ever stopped
    /// bypassing, the premise had changed. It did: `AnnotationStyle.init(from:)` is hand-written
    /// now and routes through the validating initialiser. So the claim is the stronger one: a
    /// hand-edited project file is in range the moment it is decoded, with nothing to remember
    /// to call.
    @Test func aDecodedStyleOutsideItsRangeIsAlreadyInRange() throws {
        let json = """
        {"strokeWidthFraction": 50, "red": 9, "green": -9, "blue": 0.5, "alpha": 88,
         "fillOpacity": 3, "shadowOpacity": -2, "shadowBlurFraction": 40}
        """
        let decoded = try JSONDecoder().decode(AnnotationStyle.self, from: Data(json.utf8))
        #expect(decoded.strokeWidthFraction <= 0.08)
        #expect(decoded.red <= 1 && decoded.green >= 0 && decoded.alpha <= 1)
        #expect(decoded.fillOpacity <= 1 && decoded.shadowOpacity >= 0)
        #expect(decoded.shadowBlurFraction <= 0.05)
        // And a style saved before callouts existed has no text size, which is the default.
        #expect(decoded.textSizeFraction == AnnotationStyle.default.textSizeFraction)
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
    /// Adding one is not: a project saved before `callout` existed never contains it, so the four
    /// old names still decode, which is what this list keeps honest.
    @Test func theShapeNamesOnDiskAreTheOnesEverySavedProjectUses() {
        #expect(AnnotationShape.allCases.map(\.rawValue).sorted()
                == ["arrow", "callout", "ellipse", "highlight", "image", "line", "rectangle", "step"])
    }

    @Test func everyShapeHasItsOwnDisplayName() {
        let names = AnnotationShape.allCases.map(\.displayName)
        #expect(Set(names).count == names.count)
    }
}

// MARK: - a picture in the box

/// A picture is fitted into the box the drag drew — never stretched, centred — and scaled about
/// the box's centre while it arrives. Boxes are chosen so the fit differs by axis: a wide picture
/// in a tall box is letterboxed top and bottom, a tall one in a wide box left and right.
@Suite struct AnnotationImageFrameTests {
    private func box(scale: Double = 1, name: String = "logo.png") -> AnnotationOverlay {
        // 200 × 100 box at (100, 50), drawn right-to-left and top-to-bottom on purpose: the frame
        // must come from the box, not from which point was pressed first.
        AnnotationOverlay(shape: .image, startX: 300, startY: 150, endX: 100, endY: 50,
                          style: .default, scale: scale, imageName: name)
    }

    @Test func aWidePictureFillsTheBoxesWidthAndIsCentredVertically() throws {
        let frame = try #require(box().imageFrame(imageWidth: 400, imageHeight: 100))
        #expect(frame.width == 200 && frame.height == 50, "\(frame)")
        #expect(frame.x == 100 && frame.y == 75, "centred in the box's height: \(frame)")
    }

    @Test func aTallPictureFillsTheBoxesHeightAndIsCentredHorizontally() throws {
        let frame = try #require(box().imageFrame(imageWidth: 50, imageHeight: 100))
        #expect(frame.width == 50 && frame.height == 100, "\(frame)")
        #expect(frame.x == 175 && frame.y == 50, "centred in the box's width: \(frame)")
    }

    @Test func arrivingScalesThePictureAboutTheBoxesCentre() throws {
        let frame = try #require(box(scale: 0.5).imageFrame(imageWidth: 400, imageHeight: 100))
        #expect(frame.width == 100 && frame.height == 25, "\(frame)")
        #expect(frame.x + frame.width / 2 == 200 && frame.y + frame.height / 2 == 100,
                "still centred on the box: \(frame)")
    }

    @Test func aPictureWithNoSizeHasNoFrame() {
        #expect(box().imageFrame(imageWidth: 0, imageHeight: 100) == nil)
        #expect(box().imageFrame(imageWidth: 100, imageHeight: .nan) == nil)
    }

    @Test func anImageWithNoPictureIsNothingToDraw() {
        #expect(box(name: "").isEmpty)
        #expect(!box().isEmpty)
    }
}
