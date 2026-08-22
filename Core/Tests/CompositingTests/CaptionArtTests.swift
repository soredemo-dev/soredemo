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

@Suite struct TextArtTests {
    /// Titles break where a person typed a break, and a blank line is a gap they typed.
    @Test func linesSplitOnNewlinesAndBlankOnesAreKept() {
        #expect(TextArt.lines(of: "one\ntwo") == ["one", "two"])
        #expect(TextArt.lines(of: "one\n\nthree") == ["one", "", "three"])
        #expect(TextArt.lines(of: "one") == ["one"])
    }

    /// The plate has to hold every line, so the width is the widest one.
    @Test func widthIsTheWidestLineNotTheFirstOrTheSum() {
        let narrow = TextArt.width(of: "i", pointSize: 40, bold: false)
        let wide = TextArt.width(of: "wwwwwwwwww", pointSize: 40, bold: false)
        let both = TextArt.width(of: "i\nwwwwwwwwww", pointSize: 40, bold: false)
        #expect(both == wide)
        #expect(both > narrow)
    }

    @Test func emptyTextMeasuresZeroAndDrawsNothing() {
        #expect(TextArt.width(of: "", pointSize: 40, bold: false) == 0)
        #expect(TextArt.width(of: "\n\n", pointSize: 40, bold: false) == 0)
        #expect(TextArt.image(TextOverlay(text: "  \n ", style: .default),
                              outputWidth: 640, outputHeight: 360) == nil)
    }

    @Test func aZeroSizedFrameProducesNoImageRatherThanTrapping() {
        let overlay = TextOverlay(text: "hello", style: .default)
        #expect(TextArt.image(overlay, outputWidth: 0, outputHeight: 360) == nil)
        #expect(TextArt.image(overlay, outputWidth: 640, outputHeight: 0) == nil)
    }

    /// **The anchor is why a title pinned left stays pinned left when its text gets longer.**
    /// Measured by where the ink is, not by reading the arithmetic back.
    @Test func theAnchorDecidesWhichEdgeXPointsAt() throws {
        let context = CIContext()
        let base = TextOverlayStyle.default.changing(heightFraction: 0.12, y: 0.4)

        let leading = try #require(TextArt.image(
            TextOverlay(text: "AA", style: base.changing(x: 0.05, anchor: .leading)),
            outputWidth: 800, outputHeight: 400))
        let trailing = try #require(TextArt.image(
            TextOverlay(text: "AA", style: base.changing(x: 0.95, anchor: .trailing)),
            outputWidth: 800, outputHeight: 400))

        #expect(inkColumns(of: leading, context: context).first ?? 800 < 200)
        #expect(inkColumns(of: trailing, context: context).last ?? 0 > 600)
    }

    /// Two lines are taller than one, which is the check that the stacking runs at all.
    @Test func asecondLineMakesTheDrawnBlockTaller() throws {
        let context = CIContext()
        let style = TextOverlayStyle.default.changing(heightFraction: 0.1, y: 0.3)
        let one = try #require(TextArt.image(TextOverlay(text: "A", style: style),
                                             outputWidth: 400, outputHeight: 400))
        let two = try #require(TextArt.image(TextOverlay(text: "A\nA", style: style),
                                             outputWidth: 400, outputHeight: 400))
        #expect(inkRows(of: two, context: context).count > inkRows(of: one, context: context).count)
    }

    /// `y` is measured from the BOTTOM. Getting that wrong puts a title on the wrong half of the
    /// frame, which survives review because it looks deliberate.
    @Test func yIsMeasuredUpFromTheBottom() throws {
        let context = CIContext()
        let style = TextOverlayStyle.default.changing(heightFraction: 0.1)
        let low = try #require(TextArt.image(TextOverlay(text: "A", style: style.changing(y: 0.05)),
                                             outputWidth: 400, outputHeight: 400))
        let high = try #require(TextArt.image(TextOverlay(text: "A", style: style.changing(y: 0.8)),
                                              outputWidth: 400, outputHeight: 400))
        let lowRows = inkRows(of: low, context: context)
        let highRows = inkRows(of: high, context: context)
        #expect((lowRows.first ?? 0) < (highRows.first ?? 0))
    }

    /// **The whole image once, then scanned in memory.** One `CIContext.render` per PIXEL is
    /// what the first version of these helpers did, and it made this suite take fourteen
    /// seconds — each call sets up and tears down a GPU pass to read four bytes.
    private func alphaMap(of image: CIImage, context: CIContext) -> (width: Int, height: Int, alpha: [UInt8]) {
        let width = Int(image.extent.width)
        let height = Int(image.extent.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        // The buffer is exactly `width * height` RGBA pixels and `render` is told exactly that,
        // so the pointer cannot outlive the call and the size cannot be wrong.
        unsafe bytes.withUnsafeMutableBytes { raw in
            unsafe context.render(image, toBitmap: raw.baseAddress!, rowBytes: width * 4,
                                  bounds: image.extent, format: .RGBA8,
                                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        // `render(toBitmap:)` writes top-down while the image's own y runs bottom-up, so the
        // rows are flipped back here — a position assertion read off unflipped rows would be
        // exactly upside down, which is the bug these tests exist to catch.
        var alpha = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                alpha[y * width + x] = bytes[((height - 1 - y) * width + x) * 4 + 3]
            }
        }
        return (width, height, alpha)
    }

    /// Which columns of a frame-sized image have any ink in them.
    private func inkColumns(of image: CIImage, context: CIContext) -> [Int] {
        let map = alphaMap(of: image, context: context)
        return (0..<map.width).filter { x in
            (0..<map.height).contains { map.alpha[$0 * map.width + x] > 76 }
        }
    }

    private func inkRows(of image: CIImage, context: CIContext) -> [Int] {
        let map = alphaMap(of: image, context: context)
        return (0..<map.height).filter { y in
            (0..<map.width).contains { map.alpha[y * map.width + $0] > 76 }
        }
    }
}
