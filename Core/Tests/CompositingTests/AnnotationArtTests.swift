import CoreVideo
import Foundation
import Render
import Testing
@testable import Compositing

/// **The annotation reaches the picture, and this is the test that says so.**
///
/// The handoff from `itsYoga/UIUX` names `CameraOverlayStyle.borderOpacity` as the shape this is
/// written against: a public option that had never drawn a pixel in any build, because its ring
/// was blended over a `CIImage.empty()` with zero extent and the pass evaporated silently.
/// Nothing exercised it, so nothing said. Every claim below is about pixels read back out of a
/// destination buffer, never about a call returning.
@Suite struct AnnotationArtTests {
    private let width = 640
    private let height = 360

    /// The whole frame, or `nil` on a machine with no Metal device — recorded as a real failure
    /// by the caller rather than skipped, which is what `theProductionRendererDrawsIntoThe
    /// DestinationBuffer` does for the same reason.
    private func rendered(_ annotations: [AnnotationOverlay]) throws -> [(r: UInt8, g: UInt8, b: UInt8)]? {
        let source = try makePixelBuffer(width: width, height: height, fill: sourceFill)
        let destination = try makePixelBuffer(width: width, height: height, fill: (0, 0, 0))
        let base = StagePlanner.plan(outputWidth: width, outputHeight: height,
                                     sourceWidth: width, sourceHeight: height, style: .default)
        let plan = RenderPlan(outputWidth: base.outputWidth, outputHeight: base.outputHeight,
                              card: base.card, cornerRadius: base.cornerRadius,
                              style: base.style, pointer: nil, annotations: annotations)
        let renderer: any FrameRendering
        do { renderer = try CoreImageFrameRenderer() }
        catch FrameRenderingError.noRenderDevice {
            Issue.record("no Metal render device on this machine — a real answer, not a skip")
            return nil
        }
        try renderer.render(plan, source: source, camera: nil, into: destination)
        return try pixels(of: destination)
    }

    /// **A strong red, and the source fill is a mid-blue.** `PixelBufferSupport`'s own header
    /// picked that blue to be far from the stage's near-black and from the cursor's white; red
    /// is far from all three again, so a differing pixel is attributable to this annotation and
    /// not to something else moving.
    private let red = AnnotationStyle.default.changing(strokeWidthFraction: 0.02,
                                                       shadowOpacity: 0)

    private func overlay(_ shape: AnnotationShape) -> AnnotationOverlay {
        // Well inside the card, which is inset from the frame — an annotation drawn over the
        // stage background instead of the picture would still differ from the empty render, so
        // the coordinates are chosen to make the claim about the card.
        // Words on every shape, not only the callout: a callout with nothing in it is empty by
        // definition, and the others store text and ignore it — so one fixture serves all five.
        AnnotationOverlay(shape: shape, startX: 200, startY: 120, endX: 440, endY: 240,
                          style: red, text: "Here")
    }

    /// Counts pixels that are recognisably the annotation's own colour rather than merely
    /// "different": a test that only counted differences would pass on an annotation drawn in
    /// the wrong colour, or on any other change to the frame.
    private func reddish(_ frame: [(r: UInt8, g: UInt8, b: UInt8)]) -> Int {
        frame.count { $0.r > 150 && $0.g < 110 && $0.b < 110 }
    }

    // MARK: - the callout's words

    /// White pixels inside the bubble. The bubble is red, the source is blue, the stage is dark,
    /// so a white pixel there can only be a glyph — the words were drawn, and drawn in the
    /// contrasting colour rather than in the bubble's own.
    private func whiteNear(_ frame: [(r: UInt8, g: UInt8, b: UInt8)], x: Int, y: Int,
                           radius: Int) -> Int {
        var count = 0
        for row in Swift.max(0, y - radius)..<Swift.min(height, y + radius) {
            for column in Swift.max(0, x - radius)..<Swift.min(width, x + radius) {
                // Frames are read top-down; the plan's y is bottom-up.
                let p = frame[(height - 1 - row) * width + column]
                if p.r > 220 && p.g > 220 && p.b > 220 { count += 1 }
            }
        }
        return count
    }

    @Test func aCalloutDrawsItsWordsInsideItsBubble() throws {
        let callout = AnnotationOverlay(shape: .callout, startX: 200, startY: 120,
                                        endX: 440, endY: 240, style: red, text: "Click here")
        guard let said = try rendered([callout]) else { return }
        guard let silent = try rendered([AnnotationOverlay(
            shape: .callout, startX: 200, startY: 120, endX: 440, endY: 240,
            style: red, text: "")]) else { return }
        // The bubble is centred on `start`, so the words are around (200, 120).
        let withWords = whiteNear(said, x: 200, y: 120, radius: 40)
        #expect(withWords > 0, "no white glyph pixels near the bubble's centre")
        // The positive control: an empty callout draws nothing at all, so nothing white there.
        #expect(whiteNear(silent, x: 200, y: 120, radius: 40) == 0)
    }

    /// **Two callouts with different words must draw different words.** The bitmap cache is
    /// keyed on an overlay rebuilt by hand, and a key without `text` would hand the second
    /// callout the first one's picture.
    @Test func twoCalloutsWithDifferentWordsDrawDifferentPictures() throws {
        func frame(_ words: String) throws -> [(r: UInt8, g: UInt8, b: UInt8)]? {
            try rendered([AnnotationOverlay(shape: .callout, startX: 200, startY: 120,
                                            endX: 440, endY: 240, style: red, text: words)])
        }
        guard let a = try frame("Save"), let b = try frame("Delete everything now") else { return }
        #expect(zip(a, b).contains { $0 != $1 },
                "two callouts with different words produced the same frame")
    }

    @Test func everyShapeDrawsItsOwnColourIntoTheFrame() throws {
        guard let empty = try rendered([]) else { return }
        #expect(reddish(empty) == 0, """
            the frame already contains the annotation's colour before any annotation is drawn, \
            so every count below would be measuring something else.
            """)
        // Every shape drawn in ink. A picture is drawn in its own colours, and its own test says so.
        // A highlight is translucent by design — it never reaches this saturated red over blue —
        // and `aHighlightLetsWhatIsUnderItShowThrough` makes its own claim about its colour.
        for shape in AnnotationShape.allCases where shape.drawsWithInk && shape != .highlight {
            guard let drawn = try rendered([overlay(shape)]) else { return }
            #expect(reddish(drawn) > 0, "\(shape.rawValue) drew nothing into the frame")
        }
    }

    /// An arrow is a shaft AND a head, so it puts more of its colour on the frame than the bare
    /// line between the same two points. Without this, a head that failed to draw would leave
    /// `everyShapeDrawsItsOwnColourIntoTheFrame` green — the shaft alone satisfies it.
    @Test func anArrowPutsMoreOnTheFrameThanTheLineItIsBuiltOn() throws {
        guard let arrow = try rendered([overlay(.arrow)]),
              let line = try rendered([overlay(.line)]) else { return }
        #expect(reddish(arrow) > reddish(line), """
            an arrow covered \(reddish(arrow)) pixels and a line between the same two points \
            covered \(reddish(line)). The head is not being drawn.
            """)
    }

    /// A filled rectangle covers more than its outline. `fillOpacity` is a public option and
    /// this is what stops it becoming another `borderOpacity`.
    @Test func aFilledRectangleCoversMoreThanItsOutline() throws {
        let outline = overlay(.rectangle)
        let filled = AnnotationOverlay(shape: .rectangle, startX: outline.startX,
                                       startY: outline.startY, endX: outline.endX,
                                       endY: outline.endY,
                                       style: red.changing(fillOpacity: 1))
        guard let hollow = try rendered([outline]), let solid = try rendered([filled])
        else { return }
        #expect(reddish(solid) > reddish(hollow) * 2, """
            a filled rectangle covered \(reddish(solid)) pixels against the outline's \
            \(reddish(hollow)); `fillOpacity` is not reaching the drawing.
            """)
    }

    /// **Opacity is applied, and to the whole drawing.** The fade is a colour matrix on the
    /// finished bitmap rather than a change to the fill colours, so this is the check that the
    /// matrix is actually in the path — a cache that returned the full-opacity image unchanged
    /// would look correct on the first frame and never fade.
    @Test func aHalfFadedAnnotationIsWeakerThanAFullOneAndZeroDrawsNothing() throws {
        let solid = overlay(.rectangle)
        func at(_ opacity: Double) -> AnnotationOverlay {
            AnnotationOverlay(shape: .rectangle, startX: solid.startX, startY: solid.startY,
                              endX: solid.endX, endY: solid.endY, style: red, opacity: opacity)
        }
        guard let full = try rendered([at(1)]), let half = try rendered([at(0.35)]),
              let gone = try rendered([at(0)]) else { return }
        #expect(reddish(full) > reddish(half),
                "a 35% annotation reads as strongly as a full one — the fade is not applied")
        #expect(reddish(gone) == 0, "an annotation at zero opacity still drew")
    }

    /// A zero-length annotation is what a click that never became a drag produces, and it must
    /// cost nothing rather than allocating a bitmap to draw nothing into.
    @Test func aClickThatNeverBecameADragDrawsNothing() throws {
        let point = AnnotationOverlay(shape: .arrow, startX: 300, startY: 200,
                                      endX: 300, endY: 200, style: red)
        guard let frame = try rendered([point]) else { return }
        #expect(reddish(frame) == 0)
    }

    // MARK: - the geometry, without a GPU

    /// The canvas must contain the whole drawing. Under-estimating it clips the annotation at
    /// the bitmap's edge — silently, and only on the side the shadow falls, which is why this is
    /// asserted against the numbers rather than left to a pixel test to notice.
    @Test func theCanvasIsBigEnoughForTheStrokeAndItsShadow() throws {
        let overlay = AnnotationOverlay(shape: .arrow, startX: 100, startY: 100,
                                        endX: 300, endY: 200, style: .default)
        let stroke = 12.0
        let blur = 6.0
        let canvas = try #require(AnnotationArt.canvas(for: overlay, strokeWidth: stroke,
                                                       shadowBlur: blur))
        let box = overlay.boundingBox
        #expect(canvas.x < box.x && canvas.y < box.y)
        #expect(canvas.x + canvas.width > box.x + box.width)
        #expect(canvas.y + canvas.height > box.y + box.height)
        let pad = AnnotationArt.padding(for: overlay, strokeWidth: stroke, shadowBlur: blur)
        #expect(pad > stroke / 2 + blur, "the padding does not clear the stroke and the blur")
    }

    /// **The canvas follows the animation's scale.** The first version computed it from the
    /// UNSCALED points while the paths were built from the scaled ones — correct at rest and
    /// clipped at every other value, which is a defect visible only during the third of a second
    /// an annotation spends arriving.
    @Test func theCanvasGrowsWithTheAnimationsScale() throws {
        func canvas(scale: Double) throws -> (x: Double, y: Double, width: Double, height: Double) {
            let overlay = AnnotationOverlay(shape: .rectangle, startX: 100, startY: 100,
                                            endX: 300, endY: 200, style: .default, scale: scale)
            return try #require(AnnotationArt.canvas(for: overlay, strokeWidth: 4, shadowBlur: 2))
        }
        let rest = try canvas(scale: 1)
        let popped = try canvas(scale: 1.5)
        #expect(popped.width > rest.width && popped.height > rest.height)
        // And it grows about the centre, so the shape does not walk toward the origin.
        #expect(abs((popped.x + popped.width / 2) - (rest.x + rest.width / 2)) < 0.001)
    }

    /// A short arrow must not be all head. The cap is what keeps it an arrow rather than a
    /// triangle with a stub attached.
    @Test func aShortArrowsHeadIsCappedAgainstItsOwnLength() {
        let long = AnnotationOverlay(shape: .arrow, startX: 0, startY: 0, endX: 400, endY: 0,
                                     style: .default)
        let short = AnnotationOverlay(shape: .arrow, startX: 0, startY: 0, endX: 10, endY: 0,
                                      style: .default)
        let stroke = 8.0
        #expect(AnnotationArt.headLength(for: long, strokeWidth: stroke) == stroke * 4.5)
        #expect(AnnotationArt.headLength(for: short, strokeWidth: stroke) == short.length * 0.4)
    }

    /// A drag along one axis has no area, and an ellipse inscribed in it is a line. It is still
    /// drawn — a deliberate horizontal underline must not vanish — but it has no interior.
    @Test func aDegenerateBoxIsStrokedAsALineWithNothingToFill() throws {
        let flat = AnnotationOverlay(shape: .ellipse, startX: 100, startY: 150, endX: 300,
                                     endY: 150, style: .default.changing(fillOpacity: 1))
        let artwork = try #require(AnnotationArt.artwork(for: flat, strokeWidth: 4,
                                                         originX: 0, originY: 0))
        #expect(artwork.interior == nil)
        #expect(artwork.head == nil)
        #expect(!artwork.stroked.isEmpty)
    }

    // MARK: - steps and highlights

    private func pixel(_ frame: [(r: UInt8, g: UInt8, b: UInt8)], x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        frame[(height - 1 - y) * width + x]
    }

    /// **A badge of the ink with its number drawn on it, and round.** The box is 240 × 120 about
    /// (320, 180), so the badge is the 120-wide circle at its centre: the digit is at the centre,
    /// ink is a little below it, and two points outside the circle are still the picture.
    @Test func aStepIsARoundBadgeOfItsInkWithItsNumberOnIt() throws {
        guard let frame = try rendered([AnnotationOverlay(
            shape: .step, startX: 200, startY: 120, endX: 440, endY: 240, style: red, text: "2")])
        else { return }
        #expect(whiteNear(frame, x: 320, y: 180, radius: 18) > 0, "no number was drawn on the badge")
        let belowTheDigit = pixel(frame, x: 320, y: 180 - 45)
        #expect(belowTheDigit.r > 150 && belowTheDigit.b < 110, "the badge is not the ink: \(belowTheDigit)")
        let corner = pixel(frame, x: 206, y: 126)
        #expect(corner.b > 150 && corner.r < 110, "the corner of the box was filled: \(corner)")
        // **Inside the badge's own square, outside its circle** — 78 from the centre against a
        // radius of 60. The box's corner above is outside both, so on its own it could not tell a
        // round badge from a square one; this point can, and did (a square badge survived without it).
        let squareCorner = pixel(frame, x: 265, y: 125)
        #expect(squareCorner.b > 150 && squareCorner.r < 110, "the badge is square, not round: \(squareCorner)")
    }

    /// A step with no number has nothing to say, like a callout with no words.
    @Test func aStepWithNoNumberDrawsNothing() {
        #expect(AnnotationOverlay(shape: .step, startX: 200, startY: 120, endX: 440, endY: 240,
                                  style: red, text: "").isEmpty)
    }

    /// **The picture shows through.** Over the blue source a highlight must move the colour toward
    /// the ink and still leave the blue readable — a marker that hides what it marks is a
    /// redaction. Fixed opacity: `fillOpacity` is 0 in this style and the highlight still draws.
    @Test func aHighlightLetsWhatIsUnderItShowThrough() throws {
        guard let empty = try rendered([]),
              let lit = try rendered([AnnotationOverlay(
                shape: .highlight, startX: 200, startY: 120, endX: 440, endY: 240, style: red)])
        else { return }
        let before = pixel(empty, x: 320, y: 180)
        let after = pixel(lit, x: 320, y: 180)
        #expect(Int(after.r) > Int(before.r) + 40, "the highlight did not tint the picture: \(before) → \(after)")
        #expect(after.b > 110, "the highlight hid what is under it: \(before) → \(after)")
        // No outline: the edge of the box is the same tint as its middle, not a stroke of solid ink.
        let edge = pixel(lit, x: 201, y: 180)
        #expect(abs(Int(edge.r) - Int(after.r)) < 25 && edge.b > 110, "the highlight has an outline: \(edge)")
    }
}
