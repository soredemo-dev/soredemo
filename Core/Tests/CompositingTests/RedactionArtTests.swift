import Testing
import Foundation
import CoreImage
import Render
@testable import Compositing

@Suite struct RedactionArtTests {
    /// A 200×200 image, black on the left half and white on the right, so a covered region's
    /// colour is a fact about that region rather than about the whole picture.
    private func chequer() -> CIImage {
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
            .cropped(to: HeadlessGeometryBridge.rect(x: 0, y: 0, width: 100, height: 200))
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: HeadlessGeometryBridge.rect(x: 100, y: 0, width: 100, height: 200))
        return white.composited(over: black)
    }

    @Test func nothingToHideReturnsTheImageUntouched() {
        let image = chequer()
        #expect(RedactionArt.applied([], to: image).extent == image.extent)
        let empty = RedactionRegion(id: 0, x: 0.1, y: 0.1, width: 0, height: 0.5)
        #expect(colour(of: RedactionArt.applied([empty], to: image), x: 20, y: 100).red < 0.1)
    }

    /// A solid fill leaves nothing to recover, which is the reason it is offered.
    @Test func aSolidRegionIsExactlyTheColourItSaysAndOnlyInsideItself() {
        // The LEFT quarter of the picture, in source coordinates with y from the top.
        let region = RedactionRegion(id: 0, x: 0, y: 0, width: 0.25, height: 1,
                                     style: .solid(red: 1, green: 0, blue: 0))
        let hidden = RedactionArt.applied([region], to: chequer())
        let inside = colour(of: hidden, x: 20, y: 100)
        #expect(inside.red > 0.9 && inside.green < 0.1 && inside.blue < 0.1)
        // Just outside it, the picture is untouched — still black on this side.
        let outside = colour(of: hidden, x: 70, y: 100)
        #expect(outside.red < 0.1 && outside.green < 0.1)
    }

    /// **The check that a mosaic actually destroys something**, and the reason this file does
    /// not use `CIPixellate`. That filter point-samples, so a block straddling the black/white
    /// boundary came out pure white — the value of the one pixel at its centre. Averaged, it is
    /// neither black nor white.
    @Test func aMosaicAveragesRatherThanMagnifyingOnePixel() {
        let region = RedactionRegion(id: 0, x: 0.4, y: 0.4, width: 0.2, height: 0.2,
                                     style: .mosaic(blockFraction: 0.2))
        let hidden = RedactionArt.applied([region], to: chequer())
        let middle = colour(of: hidden, x: 100, y: 100)
        #expect(middle.red > 0.1 && middle.red < 0.9,
                "the covered block is \(middle.red), which is not an average of anything")
    }

    /// **A pixel takes on colour from forty pixels away**, which is what "the detail is gone"
    /// means concretely: the value at a point is no longer a fact about that point.
    ///
    /// The region starts at pixel 70 and the blocks are 40 wide, so the first block spans 70…110
    /// and straddles the picture's black/white edge at 100. x = 95 is deep inside the black half
    /// — pure black in the original — and after the mosaic it carries a large share of the white
    /// from the other side of the block.
    ///
    /// **Not asserted: that a block is one uniform colour.** Measured, two points inside one
    /// block differ by about 8%, because the Lanczos kernel is wider than a block. An earlier
    /// version of this test claimed uniformity and failed on that 8%; the claim was wrong, not
    /// the code.
    @Test func aPixelTakesOnColourFromAcrossItsWholeBlock() {
        let region = RedactionRegion(id: 0, x: 0.35, y: 0.3, width: 0.4, height: 0.4,
                                     style: .mosaic(blockFraction: 0.2))
        let hidden = RedactionArt.applied([region], to: chequer())

        #expect(colour(of: chequer(), x: 95, y: 100).red < 0.05,
                "the fixture is not black where this test needs it to be")
        let mosaicked = colour(of: hidden, x: 95, y: 100).red
        #expect(mosaicked > 0.3,
                "black stayed black at \(mosaicked) — nothing was averaged in from the far side")
    }

    /// `y` runs from the TOP in a region and from the bottom in a `CIImage`. Getting the flip
    /// wrong hides the mirror image of what a person selected — which looks like it worked.
    @Test func yIsMeasuredFromTheTopOfThePicture() {
        // The top quarter. In CIImage coordinates that is y 150…200, not 0…50.
        let region = RedactionRegion(id: 0, x: 0, y: 0, width: 1, height: 0.25,
                                     style: .solid(red: 1, green: 0, blue: 0))
        let hidden = RedactionArt.applied([region], to: chequer())
        #expect(colour(of: hidden, x: 100, y: 180).red > 0.9)
        #expect(colour(of: hidden, x: 20, y: 20).red < 0.1)
    }

    /// A face is not a rectangle. Measured at a corner of the bounding box, which an ellipse
    /// does not reach, and at its centre, which it covers.
    @Test func anOvalCoversItsCentreAndNotTheCornersOfItsBox() {
        let region = RedactionRegion(id: 0, x: 0.25, y: 0.25, width: 0.5, height: 0.5,
                                     style: .solid(red: 1, green: 0, blue: 0), isOval: true)
        let hidden = RedactionArt.applied([region], to: chequer())
        #expect(colour(of: hidden, x: 100, y: 100).red > 0.9)
        // Two pixels in from the box's own corner: inside the rectangle, outside the ellipse.
        #expect(colour(of: hidden, x: 52, y: 52).red < 0.2)
    }

    @Test func severalRegionsAreAllApplied() {
        let left = RedactionRegion(id: 0, x: 0, y: 0, width: 0.2, height: 1,
                                   style: .solid(red: 1, green: 0, blue: 0))
        let right = RedactionRegion(id: 1, x: 0.8, y: 0, width: 0.2, height: 1,
                                    style: .solid(red: 0, green: 1, blue: 0))
        let hidden = RedactionArt.applied([left, right], to: chequer())
        #expect(colour(of: hidden, x: 10, y: 100).red > 0.9)
        #expect(colour(of: hidden, x: 190, y: 100).green > 0.9)
    }

    /// One pixel, rendered through Core Image so the test measures the produced image.
    private func colour(of image: CIImage, x: Int, y: Int) -> (red: Double, green: Double, blue: Double) {
        var pixel: [UInt8] = [0, 0, 0, 0]
        // Four bytes for one RGBA pixel and `render` is told exactly that, so the pointer cannot
        // outlive the call and the size cannot be wrong.
        unsafe pixel.withUnsafeMutableBytes { bytes in
            unsafe CIContext().render(image, toBitmap: bytes.baseAddress!, rowBytes: 4,
                                      bounds: HeadlessGeometryBridge.pixel(x: x, y: y),
                                      format: .RGBA8,
                                      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }
}
