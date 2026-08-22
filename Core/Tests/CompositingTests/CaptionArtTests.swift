import Testing
import Foundation
import CoreImage
import Captions
import Render
import Timeline
@testable import Compositing

@Suite struct CaptionArtTests {
    /// **The reason `fits` and `image` share a measurement.** If these two disagreed, breaks
    /// would be computed against one font and drawn in another, and the failure looks like
    /// captions that overflow at only some export sizes.
    @Test func aLineThatFitsIsNoWiderThanTheStyleAllows() {
        let style = CaptionStyle.default
        let fits = CaptionArt.fits(style: style, outputWidth: 1920, outputHeight: 1080)
        let limit = style.maximumWidth(forOutputWidth: 1920)

        #expect(fits("short"))
        #expect(CaptionArt.width(of: "short", style: style, outputHeight: 1080) <= limit)

        let long = String(repeating: "a very long caption line ", count: 12)
        #expect(!fits(long))
        #expect(CaptionArt.width(of: long, style: style, outputHeight: 1080) > limit)
    }

    /// The whole point of fractions: the same caption at every export size.
    @Test func measurementScalesWithTheOutputHeightAndNotWithTheText() {
        let style = CaptionStyle.default
        let small = CaptionArt.width(of: "hello", style: style, outputHeight: 540)
        let large = CaptionArt.width(of: "hello", style: style, outputHeight: 1080)
        // Twice the height, twice the type, twice the width — within rounding of the font's
        // own hinting, which is why this is a ratio band rather than an equality.
        #expect(large / small > 1.8 && large / small < 2.2)
    }

    @Test func anEmptyOrWhitespaceCaptionDrawsNothingRatherThanAnEmptyPlate() {
        let style = CaptionStyle.default
        #expect(CaptionArt.image(CaptionOverlay(text: "", style: style),
                                 outputWidth: 640, outputHeight: 360) == nil)
        #expect(CaptionArt.image(CaptionOverlay(text: "   \n ", style: style),
                                 outputWidth: 640, outputHeight: 360) == nil)
        #expect(CaptionArt.width(of: "", style: style, outputHeight: 1080) == 0)
    }

    /// A zero-sized output is what a misconfigured export looks like; it must not trap.
    @Test func aZeroSizedFrameProducesNoImageRatherThanTrapping() {
        let overlay = CaptionOverlay(text: "hello", style: .default)
        #expect(CaptionArt.image(overlay, outputWidth: 0, outputHeight: 360) == nil)
        #expect(CaptionArt.image(overlay, outputWidth: 640, outputHeight: 0) == nil)
    }

    /// The image covers the whole frame — see `image`'s header for why it is not text-sized.
    @Test func theDrawnImageIsFrameSizedAndHasInkNearTheBottom() throws {
        let overlay = CaptionOverlay(text: "Soredemo", style: .default)
        let image = try #require(CaptionArt.image(overlay, outputWidth: 640, outputHeight: 360))
        #expect(Int(image.extent.width) == 640)
        #expect(Int(image.extent.height) == 360)

        // Where the ink is: sample the middle column at the caption's own inset, and the same
        // column near the top. The first must be opaque, the second clear — which is the check
        // that the caption is at the BOTTOM and not flipped.
        let context = CIContext()
        let inset = Int(360.0 * CaptionStyle.default.bottomInsetFraction)
        #expect(alpha(of: image, x: 320, y: inset + 8, context: context) > 0.2)
        #expect(alpha(of: image, x: 320, y: 350, context: context) < 0.02)
    }

    /// A style with no plate draws only the glyphs, so the row just inside the plate's would-be
    /// edge is clear where the default's is not.
    @Test func turningThePlateOffLeavesTheBackgroundClear() throws {
        let bare = CaptionStyle(heightFraction: 0.045, bottomInsetFraction: 0.07,
                                maximumWidthFraction: 0.9, backgroundOpacity: 0,
                                backgroundCornerFraction: 0.012, red: 1, green: 1, blue: 1)
        let image = try #require(CaptionArt.image(CaptionOverlay(text: "Soredemo", style: bare),
                                                  outputWidth: 640, outputHeight: 360))
        let context = CIContext()
        let inset = Int(360.0 * bare.bottomInsetFraction)
        // The very bottom row of the plate's area: with no plate there is nothing there.
        #expect(alpha(of: image, x: 320, y: inset + 1, context: context) < 0.02)
    }

    /// One alpha sample, read back through Core Image so the test measures the rendered image
    /// rather than the code that made it.
    private func alpha(of image: CIImage, x: Int, y: Int, context: CIContext) -> Double {
        var pixel: [UInt8] = [0, 0, 0, 0]
        // The buffer is four bytes for one RGBA pixel and `render` is told exactly that, so the
        // pointer cannot outlive the call and the size cannot be wrong.
        unsafe pixel.withUnsafeMutableBytes { bytes in
            unsafe context.render(image, toBitmap: bytes.baseAddress!, rowBytes: 4,
                                  bounds: HeadlessGeometryBridge.pixel(x: x, y: y),
                                  format: .RGBA8,
                                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        return Double(pixel[3]) / 255
    }
}

@Suite struct CaptionStyleTests {
    /// Rule 8: a style also arrives from a decoder, and an out-of-range value must not trap.
    @Test func everyFieldIsClampedRatherThanTrappedOn() {
        let wild = CaptionStyle(heightFraction: 99, bottomInsetFraction: -3,
                                maximumWidthFraction: 0, backgroundOpacity: 4,
                                backgroundCornerFraction: -1, red: 2, green: -1, blue: 0.5)
        #expect(wild.heightFraction <= 0.5)
        #expect(wild.bottomInsetFraction == 0)
        #expect(wild.maximumWidthFraction >= 0.1)
        #expect(wild.backgroundOpacity == 1)
        #expect(wild.backgroundCornerFraction == 0)
        #expect(wild.red == 1)
        #expect(wild.green == 0)
        #expect(wild.blue == 0.5)
    }

    @Test func aStyleRoundTripsThroughItsOwnEncoding() throws {
        let style = CaptionStyle.default
        let data = try JSONEncoder().encode(style)
        #expect(try JSONDecoder().decode(CaptionStyle.self, from: data) == style)
    }

    @Test func sizesAreFractionsOfTheOutputTheyAreAskedAbout() {
        let style = CaptionStyle.default
        #expect(style.pointSize(forOutputHeight: 1000) == 45)
        #expect(style.maximumWidth(forOutputWidth: 1000) == 900)
    }
}
