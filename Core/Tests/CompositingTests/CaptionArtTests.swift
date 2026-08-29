import Testing
import AVFoundation
import Foundation
import CoreImage
import Overlays
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
    /// **The camera is never half off the frame, at any setting.** `x` and `y` place the
    /// CENTRE and are clamped to 0…1, so `x = 1` used to hang half a face off the right edge of
    /// the export — and the self-view writes exactly that when somebody drags into a corner,
    /// which is where cameras go. Placing the overlay inside
    /// `container − overlay − margin × 2` and neither can produce a cropped camera.
    @Test func aCameraDraggedIntoACornerStaysWhollyInsideTheFrame() {
        for position in CameraOverlayStyle.Position.allCases {
            let style = CameraOverlayStyle.default.placed(at: position)
            let box = style.rect(inOutputWidth: 1920, outputHeight: 1080, sourceAspect: 16.0 / 9)
            #expect(box.x >= 0, "\(position) put the camera at x \(box.x)")
            #expect(box.y >= 0, "\(position) put the camera at y \(box.y)")
            #expect(box.x + box.width <= 1920.001,
                    "\(position) runs to \(box.x + box.width) of 1920")
            #expect(box.y + box.height <= 1080.001,
                    "\(position) runs to \(box.y + box.height) of 1080")
        }
    }

    /// The margin is real, not zero: a camera flush against the edge reads as a mistake even
    /// when it is entirely inside.
    @Test func aCornerCameraIsInsetFromTheEdgeRatherThanFlushAgainstIt() {
        let box = CameraOverlayStyle.default.placed(at: .bottomRight)
            .rect(inOutputWidth: 1920, outputHeight: 1080, sourceAspect: 16.0 / 9)
        let margin = 1920 * CameraOverlayStyle.edgeMarginFraction
        #expect(abs(box.x + box.width - (1920 - margin)) < 0.001)
        #expect(abs(box.y - margin) < 0.001)
    }

    /// **A camera too big for the frame is centred, not jammed against an edge.** With no room
    /// to satisfy both margins the symmetric answer is the only one that is not arbitrary —
    /// clamping to one side would put the whole crop on the other.
    ///
    /// Only the VERTICAL case is reachable and the test says so: `widthFraction` is clamped to
    /// 0.6 and the margin is 0.025 of the width, so a camera can never be too wide for its own
    /// frame. A circle is as tall as it is wide, and a wide frame is not as tall — 600 points of
    /// camera in a 400-point frame. The horizontal branch is kept because the two axes should
    /// not disagree about what "no room" means.
    @Test func aCameraTallerThanItsFrameIsCentredVertically() {
        let style = CameraOverlayStyle.default.changing(widthFraction: 0.6, x: 1, y: 1)
        let box = style.rect(inOutputWidth: 1000, outputHeight: 400, sourceAspect: 1)
        #expect(abs(box.height - 600) < 0.001, "the premise: 600 of camera in 400 of frame")
        #expect(abs(box.y + box.height / 2 - 200) < 0.001)
    }

    /// A preset and a drag into the same corner have to land in the same place, or a person who
    /// used both would see the camera jump between two answers to one question.
    @Test func aPresetAndADragIntoTheSameCornerAgree() {
        let preset = CameraOverlayStyle.default.placed(at: .bottomRight)
            .rect(inOutputWidth: 1920, outputHeight: 1080, sourceAspect: 1)
        // What a drag writes when the panel is pushed against the corner of the screen.
        let dragged = CameraOverlayStyle.default.changing(x: 1.0, y: 0.0)
            .rect(inOutputWidth: 1920, outputHeight: 1080, sourceAspect: 1)
        #expect(abs(preset.x - dragged.x) < 0.001)
        #expect(abs(preset.y - dragged.y) < 0.001)
    }

    /// **A preset stays a preset.** a Rust recorder carries a `position` enum beside an optional
    /// `manual_position` that overrides it, because baking a corner into coordinates means
    /// "bottom right" stops being bottom right the moment the size changes. Ours resolves the
    /// preset at draw time, so a bigger camera on the same preset is still in the corner.
    @Test func aPresetSurvivesASizeChangeAndAHandPlacementClearsIt() {
        let corner = CameraOverlayStyle.default.placed(at: .bottomRight)
        #expect(corner.position == .bottomRight)
        let bigger = corner.changing(widthFraction: 0.4)
        #expect(bigger.position == .bottomRight, "resizing dropped the preset")
        let box = bigger.rect(inOutputWidth: 1920, outputHeight: 1080, sourceAspect: 1)
        let margin = 1920 * CameraOverlayStyle.edgeMarginFraction
        #expect(abs(box.x + box.width - (1920 - margin)) < 0.001, "no longer in the corner")

        // Moving by hand is not on a preset any more, and must not claim to be.
        let dragged = corner.changing(x: 0.4)
        #expect(dragged.position == nil)
    }

    /// **A hidden camera is off, not deleted.** The switch means "not in
    /// this one" and "throw the footage away" are different decisions and only one is reversible.
    @Test func hidingTheCameraIsAStyleAndNotALostRecording() {
        let hidden = CameraOverlayStyle.default.changing(isHidden: true)
        #expect(hidden.isHidden)
        #expect(hidden.changing(isHidden: false).isHidden == false)
        // Everything else survives, so turning it back on restores what was there.
        #expect(hidden.widthFraction == CameraOverlayStyle.default.widthFraction)
        #expect(hidden.position == CameraOverlayStyle.default.position)
    }

    /// **The camera shrinks as the stage zooms in**, because a zoom makes the picture bigger and
    /// a camera holding its width covers a larger share of a smaller area. Interpolated rather
    /// than snapped: a step at the first frame of a zoom reads as a glitch.
    @Test func theCameraShrinksWithTheZoomRatherThanSnapping() {
        let style = CameraOverlayStyle.default.changing(scaleDuringZoom: 0.7)
        let rest = style.rect(inOutputWidth: 1920, outputHeight: 1080,
                              sourceAspect: 1, contentZoom: 1).width
        let gentle = style.rect(inOutputWidth: 1920, outputHeight: 1080,
                                sourceAspect: 1, contentZoom: 1.5).width
        let hard = style.rect(inOutputWidth: 1920, outputHeight: 1080,
                              sourceAspect: 1, contentZoom: 4).width
        #expect(gentle < rest, "a zoom did not shrink the camera at all")
        #expect(hard < gentle, "a harder zoom did not shrink it further")
        // Never below the fraction that was asked for, however hard the zoom.
        #expect(hard >= rest * 0.7 - 0.001)
    }

    /// A style that holds its size through a zoom is what every project written before the field
    /// existed asked for, and the decoder has to keep meaning that.
    @Test func aScaleOfOneHoldsTheCameraThroughAZoom() {
        let style = CameraOverlayStyle.default.changing(scaleDuringZoom: 1)
        let rest = style.rect(inOutputWidth: 1920, outputHeight: 1080,
                              sourceAspect: 1, contentZoom: 1).width
        let zoomed = style.rect(inOutputWidth: 1920, outputHeight: 1080,
                                sourceAspect: 1, contentZoom: 3).width
        #expect(abs(rest - zoomed) < 0.001)
    }

    /// **An old project decodes to what it meant, not to the new defaults.** `position` absent
    /// means the coordinates are the answer; `scaleDuringZoom` absent means the camera held its
    /// size. `CameraOverlayStyle.default` says otherwise on both, and that is for NEW recordings.
    @Test func aProjectWrittenBeforeTheseFieldsKeepsItsOwnMeaning() throws {
        let old = Data(#"{"widthFraction":0.2,"x":0.3,"y":0.4,"shape":"square"}"#.utf8)
        let style = try JSONDecoder().decode(CameraOverlayStyle.self, from: old)
        #expect(style.position == nil, "a preset was invented for a project that had none")
        #expect(style.scaleDuringZoom == 1, "an old camera would shrink on zoom for the first time")
        #expect(style.isHidden == false)
        let box = style.rect(inOutputWidth: 1000, outputHeight: 1000, sourceAspect: 1)
        #expect(abs(box.x + box.width / 2 - 300) < 0.001, "the saved coordinates moved")
    }

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

/// The word being said, found inside the line's own text.
@Suite struct CaptionHighlightTests {
    private func word(_ text: String, spoken: Bool = false) -> CaptionWord {
        CaptionWord(text: text, isSpoken: spoken)
    }

    @Test func theRangeCoversTheSpokenWordAndNothingElse() throws {
        let words = [word("hello"), word("there", spoken: true), word("friend")]
        let range = try #require(CaptionArt.highlightRange(in: "hello there friend", words: words))
        let text = Array("hello there friend")
        #expect(String(text[range.lowerBound..<range.upperBound]) == "there")
    }

    /// **The reason it counts letters rather than splitting on spaces.** A recogniser hands back
    /// "don't" as three runs, so `text.split(" ")[n]` is not `words[n]` — the same mismatch
    /// `CaptionBuilder` times phrases around.
    @Test func itFindsTheWordWhenTheRunsDoNotSplitOnSpaces() throws {
        let words = [word("I"), word("don"), word("'"), word("t"),
                     word("know", spoken: true)]
        let range = try #require(CaptionArt.highlightRange(in: "I don't know.", words: words))
        let text = Array("I don't know.")
        #expect(String(text[range.lowerBound..<range.upperBound]) == "know")
    }

    /// Punctuation in the line that the runs never carried does not shift the match, because
    /// only letters and digits are counted on both sides.
    @Test func punctuationInTheLineDoesNotShiftTheMatch() throws {
        let words = [word("first"), word("second", spoken: true)]
        let range = try #require(CaptionArt.highlightRange(in: "First, second!", words: words))
        let text = Array("First, second!")
        #expect(String(text[range.lowerBound..<range.upperBound]) == "second")
    }

    @Test func nothingSpokenMeansNoHighlight() {
        #expect(CaptionArt.highlightRange(in: "a b", words: [word("a"), word("b")]) == nil)
        #expect(CaptionArt.highlightRange(in: "a b", words: []) == nil)
    }

    /// **When the two disagree, the whole line draws undimmed.** A range computed past the end
    /// of the text would dim everything and highlight nothing, which looks like a bug in the
    /// caption rather than in the match.
    @Test func aWordThatRunsPastTheLineGivesNoHighlight() {
        let words = [word("beyond", spoken: true), word("more")]
        #expect(CaptionArt.highlightRange(in: "hi", words: words) == nil)
    }

    /// The dimmed spans are everything outside the highlight, and an empty leading span is not
    /// a span at all.
    @Test func theDimmedSpansAreTheTwoSidesAndNeitherIsEmpty() {
        let leading = TextArt.DimmedRun(range: 0..<3, alpha: 0.5).rangesOutside(length: 10)
        #expect(leading.count == 1)
        #expect(leading[0].location == 3)

        let middle = TextArt.DimmedRun(range: 3..<6, alpha: 0.5).rangesOutside(length: 10)
        #expect(middle.count == 2)

        let whole = TextArt.DimmedRun(range: 0..<10, alpha: 0.5).rangesOutside(length: 10)
        #expect(whole.isEmpty)
    }
}

/// The camera's placement.
@Suite struct CameraOverlayTests {
    /// **A circle is square before it is masked.** Fitting a 4:3 camera into a circle by its own
    /// aspect gives an ellipse; the frame is squared and the source is cropped to fill it, which
    /// is what every video-call application does with a round self-view.
    @Test func aCircleIsSquareWhateverTheCameraSAspect() {
        let style = CameraOverlayStyle.default
        let box = style.rect(inOutputWidth: 1920, outputHeight: 1080, sourceAspect: 4.0 / 3)
        #expect(abs(box.width - box.height) < 0.001)
    }

    /// A rectangle keeps the camera's aspect, so a 16:9 camera is not squashed.
    @Test func arectangleKeepsTheCamerasAspect() {
        let style = CameraOverlayStyle.default.changing(shape: .rounded)
        let box = style.rect(inOutputWidth: 1920, outputHeight: 1080, sourceAspect: 16.0 / 9)
        #expect(abs(box.width / box.height - 16.0 / 9) < 0.001)
    }

    /// `x` and `y` point at the camera's CENTRE, and `y` runs up from the bottom.
    @Test func thePositionIsTheCentreAndYRunsUpward() {
        let style = CameraOverlayStyle.default.changing(widthFraction: 0.2, x: 0.5, y: 0.25)
        let box = style.rect(inOutputWidth: 1000, outputHeight: 1000, sourceAspect: 1)
        #expect(abs(box.x + box.width / 2 - 500) < 0.001)
        #expect(abs(box.y + box.height / 2 - 250) < 0.001)
    }

    /// **The camera is never half off the frame, at any setting.** `x` and `y` place the
    /// CENTRE and are clamped to 0…1, so `x = 1` used to hang half a face off the right edge of
    /// the export — and the self-view writes exactly that when somebody drags into a corner,
    /// which is where cameras go. Placing the overlay inside
    /// `container − overlay − margin × 2` and neither can produce a cropped camera.
    @Test func aCameraDraggedIntoACornerStaysWhollyInsideTheFrame() {
        for position in CameraOverlayStyle.Position.allCases {
            let style = CameraOverlayStyle.default.placed(at: position)
            let box = style.rect(inOutputWidth: 1920, outputHeight: 1080, sourceAspect: 16.0 / 9)
            #expect(box.x >= 0, "\(position) put the camera at x \(box.x)")
            #expect(box.y >= 0, "\(position) put the camera at y \(box.y)")
            #expect(box.x + box.width <= 1920.001,
                    "\(position) runs to \(box.x + box.width) of 1920")
            #expect(box.y + box.height <= 1080.001,
                    "\(position) runs to \(box.y + box.height) of 1080")
        }
    }

    /// The margin is real, not zero: a camera flush against the edge reads as a mistake even
    /// when it is entirely inside.
    @Test func aCornerCameraIsInsetFromTheEdgeRatherThanFlushAgainstIt() {
        let box = CameraOverlayStyle.default.placed(at: .bottomRight)
            .rect(inOutputWidth: 1920, outputHeight: 1080, sourceAspect: 16.0 / 9)
        let margin = 1920 * CameraOverlayStyle.edgeMarginFraction
        #expect(abs(box.x + box.width - (1920 - margin)) < 0.001)
        #expect(abs(box.y - margin) < 0.001)
    }

    /// **A camera too big for the frame is centred, not jammed against an edge.** With no room
    /// to satisfy both margins the symmetric answer is the only one that is not arbitrary —
    /// clamping to one side would put the whole crop on the other.
    ///
    /// Only the VERTICAL case is reachable and the test says so: `widthFraction` is clamped to
    /// 0.6 and the margin is 0.025 of the width, so a camera can never be too wide for its own
    /// frame. A circle is as tall as it is wide, and a wide frame is not as tall — 600 points of
    /// camera in a 400-point frame. The horizontal branch is kept because the two axes should
    /// not disagree about what "no room" means.
    @Test func aCameraTallerThanItsFrameIsCentredVertically() {
        let style = CameraOverlayStyle.default.changing(widthFraction: 0.6, x: 1, y: 1)
        let box = style.rect(inOutputWidth: 1000, outputHeight: 400, sourceAspect: 1)
        #expect(abs(box.height - 600) < 0.001, "the premise: 600 of camera in 400 of frame")
        #expect(abs(box.y + box.height / 2 - 200) < 0.001)
    }

    /// A preset and a drag into the same corner have to land in the same place, or a person who
    /// used both would see the camera jump between two answers to one question.
    @Test func aPresetAndADragIntoTheSameCornerAgree() {
        let preset = CameraOverlayStyle.default.placed(at: .bottomRight)
            .rect(inOutputWidth: 1920, outputHeight: 1080, sourceAspect: 1)
        // What a drag writes when the panel is pushed against the corner of the screen.
        let dragged = CameraOverlayStyle.default.changing(x: 1.0, y: 0.0)
            .rect(inOutputWidth: 1920, outputHeight: 1080, sourceAspect: 1)
        #expect(abs(preset.x - dragged.x) < 0.001)
        #expect(abs(preset.y - dragged.y) < 0.001)
    }

    /// **A preset stays a preset.** a Rust recorder carries a `position` enum beside an optional
    /// `manual_position` that overrides it, because baking a corner into coordinates means
    /// "bottom right" stops being bottom right the moment the size changes. Ours resolves the
    /// preset at draw time, so a bigger camera on the same preset is still in the corner.
    @Test func aPresetSurvivesASizeChangeAndAHandPlacementClearsIt() {
        let corner = CameraOverlayStyle.default.placed(at: .bottomRight)
        #expect(corner.position == .bottomRight)
        let bigger = corner.changing(widthFraction: 0.4)
        #expect(bigger.position == .bottomRight, "resizing dropped the preset")
        let box = bigger.rect(inOutputWidth: 1920, outputHeight: 1080, sourceAspect: 1)
        let margin = 1920 * CameraOverlayStyle.edgeMarginFraction
        #expect(abs(box.x + box.width - (1920 - margin)) < 0.001, "no longer in the corner")

        // Moving by hand is not on a preset any more, and must not claim to be.
        let dragged = corner.changing(x: 0.4)
        #expect(dragged.position == nil)
    }

    /// **A hidden camera is off, not deleted.** The switch means "not in
    /// this one" and "throw the footage away" are different decisions and only one is reversible.
    @Test func hidingTheCameraIsAStyleAndNotALostRecording() {
        let hidden = CameraOverlayStyle.default.changing(isHidden: true)
        #expect(hidden.isHidden)
        #expect(hidden.changing(isHidden: false).isHidden == false)
        // Everything else survives, so turning it back on restores what was there.
        #expect(hidden.widthFraction == CameraOverlayStyle.default.widthFraction)
        #expect(hidden.position == CameraOverlayStyle.default.position)
    }

    /// **The camera shrinks as the stage zooms in**, because a zoom makes the picture bigger and
    /// a camera holding its width covers a larger share of a smaller area. Interpolated rather
    /// than snapped: a step at the first frame of a zoom reads as a glitch.
    @Test func theCameraShrinksWithTheZoomRatherThanSnapping() {
        let style = CameraOverlayStyle.default.changing(scaleDuringZoom: 0.7)
        let rest = style.rect(inOutputWidth: 1920, outputHeight: 1080,
                              sourceAspect: 1, contentZoom: 1).width
        let gentle = style.rect(inOutputWidth: 1920, outputHeight: 1080,
                                sourceAspect: 1, contentZoom: 1.5).width
        let hard = style.rect(inOutputWidth: 1920, outputHeight: 1080,
                              sourceAspect: 1, contentZoom: 4).width
        #expect(gentle < rest, "a zoom did not shrink the camera at all")
        #expect(hard < gentle, "a harder zoom did not shrink it further")
        // Never below the fraction that was asked for, however hard the zoom.
        #expect(hard >= rest * 0.7 - 0.001)
    }

    /// A style that holds its size through a zoom is what every project written before the field
    /// existed asked for, and the decoder has to keep meaning that.
    @Test func aScaleOfOneHoldsTheCameraThroughAZoom() {
        let style = CameraOverlayStyle.default.changing(scaleDuringZoom: 1)
        let rest = style.rect(inOutputWidth: 1920, outputHeight: 1080,
                              sourceAspect: 1, contentZoom: 1).width
        let zoomed = style.rect(inOutputWidth: 1920, outputHeight: 1080,
                                sourceAspect: 1, contentZoom: 3).width
        #expect(abs(rest - zoomed) < 0.001)
    }

    /// **An old project decodes to what it meant, not to the new defaults.** `position` absent
    /// means the coordinates are the answer; `scaleDuringZoom` absent means the camera held its
    /// size. `CameraOverlayStyle.default` says otherwise on both, and that is for NEW recordings.
    @Test func aProjectWrittenBeforeTheseFieldsKeepsItsOwnMeaning() throws {
        let old = Data(#"{"widthFraction":0.2,"x":0.3,"y":0.4,"shape":"square"}"#.utf8)
        let style = try JSONDecoder().decode(CameraOverlayStyle.self, from: old)
        #expect(style.position == nil, "a preset was invented for a project that had none")
        #expect(style.scaleDuringZoom == 1, "an old camera would shrink on zoom for the first time")
        #expect(style.isHidden == false)
        let box = style.rect(inOutputWidth: 1000, outputHeight: 1000, sourceAspect: 1)
        #expect(abs(box.x + box.width / 2 - 300) < 0.001, "the saved coordinates moved")
    }

    @Test func everyFieldIsClampedRatherThanTrappedOn() {
        let wild = CameraOverlayStyle(widthFraction: 9, x: -2, y: 4, shape: .square,
                                      cornerFraction: 9, isMirrored: false,
                                      borderOpacity: -1, shadowOpacity: 8)
        #expect(wild.widthFraction <= 0.6)
        #expect(wild.x == 0)
        #expect(wild.y == 1)
        #expect(wild.cornerFraction <= 0.5)
        #expect(wild.borderOpacity == 0)
        #expect(wild.shadowOpacity == 1)
    }

    /// A project written before the camera existed opens with the defaults, and the default is
    /// mirrored — an unmirrored self-view is the one that looks wrong to the person recording.
    ///
    /// **This used to assert `style == .default`, and that claim has moved.** Two fields now
    /// mean different things to an old project than to a new recording, deliberately: `position`
    /// is `nil` because a project that has coordinates and no preset must keep its coordinates,
    /// and `scaleDuringZoom` is `1` because a camera saved before the field existed held its
    /// size through a zoom and opening the project must not shrink it. Everything else still
    /// comes back as the default, which is what this test was written to protect.
    @Test func anEmptyStyleDecodesToTheDefaultsExceptWhereThatWouldMoveSomebodysCamera() throws {
        let style = try JSONDecoder().decode(CameraOverlayStyle.self, from: Data("{}".utf8))
        #expect(style.isMirrored)
        #expect(style.position == nil)
        #expect(style.scaleDuringZoom == 1)
        // Field by field rather than against a constructed twin: `changing` deliberately cannot
        // clear a preset without also moving the camera, so there is no expression for "the
        // default, minus its preset" — which is itself the guarantee this file wants.
        let fallback = CameraOverlayStyle.default
        #expect(style.widthFraction == fallback.widthFraction)
        #expect(style.x == fallback.x)
        #expect(style.y == fallback.y)
        #expect(style.shape == fallback.shape)
        #expect(style.cornerFraction == fallback.cornerFraction)
        #expect(style.borderOpacity == fallback.borderOpacity)
        #expect(style.shadowOpacity == fallback.shadowOpacity)
        #expect(style.isHidden == fallback.isHidden)
        #expect(fallback.position == .bottomRight)
        #expect(fallback.scaleDuringZoom == 0.7)
    }

    @Test func aStyleRoundTripsAndChangingOneFieldLeavesTheRest() throws {
        let style = CameraOverlayStyle.default.changing(shape: .rounded, isMirrored: false)
        let data = try JSONEncoder().encode(style)
        #expect(try JSONDecoder().decode(CameraOverlayStyle.self, from: data) == style)
        #expect(style.widthFraction == CameraOverlayStyle.default.widthFraction)
        #expect(CameraOverlay(style: style).style == style)
    }

    /// No camera file means the screen asset is handed back untouched — the common path builds
    /// no composition at all.
    @MainActor
    @Test func noCameraLeavesTheAssetAlone() async throws {
        let screen = AVURLAsset(url: repositoryRootFromTests
            .appending(path: "Tests/RenderParityFixtures/two-tone.mov"))
        let combined: CameraComposition.Combined =
            try await CameraComposition.combine(screen: screen, cameraURL: nil)
        #expect(combined.cameraTrackID == nil)
        #expect(combined.asset === screen)
    }

    /// A path with no file behind it is the same as no camera, rather than a throw: a project
    /// whose camera file was deleted must still open.
    @MainActor
    @Test func aMissingCameraFileIsTheSameAsNone() async throws {
        let screen = AVURLAsset(url: repositoryRootFromTests
            .appending(path: "Tests/RenderParityFixtures/two-tone.mov"))
        let combined = try await CameraComposition.combine(
            screen: screen, cameraURL: URL(fileURLWithPath: "/tmp/nothing-here.mov"))
        #expect(combined.cameraTrackID == nil)
    }
}
