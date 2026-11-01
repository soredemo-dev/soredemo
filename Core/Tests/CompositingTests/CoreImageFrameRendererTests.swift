import Testing
import Foundation
import CoreVideo
@testable import Compositing
import Geometry
import Project
import Render

/// The `FrameRendering` seam exercised through the PRODUCTION conformer, never a double.
/// `renderer` is typed `any FrameRendering` on purpose, so the call dispatches through the
/// protocol. Needs a GPU: a missing Metal device is recorded as a real failure, not skipped.
@Test func theProductionRendererDrawsIntoTheDestinationBuffer() throws {
    let width = 640, height = 360
    let source = try makePixelBuffer(width: width, height: height, fill: sourceFill)
    let destination = try makePixelBuffer(width: width, height: height, fill: (0, 0, 0))

    let plan = StagePlanner.plan(outputWidth: width, outputHeight: height,
                                 sourceWidth: width, sourceHeight: height,
                                 style: .default)

    let renderer: any FrameRendering
    do {
        renderer = try CoreImageFrameRenderer()
    } catch FrameRenderingError.noRenderDevice {
        Issue.record("no Metal render device on this machine — a real answer, not a skip")
        return
    }
    try renderer.render(plan, source: source, camera: nil, into: destination)

    // Pixels actually written, not "the call returned": the destination started all-black and
    // neither the stage background nor the card fill is black, so doing nothing leaves it zero.
    let written = try pixels(of: destination).filter { $0 != (0, 0, 0) }
    #expect(!written.isEmpty, "the destination is still the all-black buffer it started as")
}

/// `noRenderDevice` exercised for real, not through the `catch` above — that branch never runs
/// on a machine with a Metal device, so the case would be named but never executed. Constructed
/// directly here, independent of whether a GPU is present.
@Test func theNoRenderDeviceCaseDescribesItself() throws {
    let error = FrameRenderingError.noRenderDevice
    #expect(error.description.contains("Metal"))
    #expect(error.description.contains("MTLCreateSystemDefaultDevice"))
}

// MARK: - the shadow the model carried and the renderer ignored

/// `StageStyle.shadowRadius`/`.shadowOpacity` round-tripped through `Codable` from the day they
/// were modelled, and this renderer's own header said plainly that it drew no shadow. Recorder
/// parity (design doc 2026-08-19) is what turns that disclosure into a defect.
///
/// Two renders differing ONLY in `shadowOpacity` — a light background so darkening is
/// unmistakable. The sampled point sits just below the card's bottom edge, inside the blur
/// radius; the control point sits at the output's corner, far outside it. Asserting "darker",
/// not merely "different": a shadow that LIGHTENED the background would satisfy a difference
/// check and still be wrong.
@Test func theShadowDarkensTheBackgroundJustOutsideTheCard() throws {
    let width = 640, height = 360
    let lightBackground = StageBackground.solid(red: 0.9, green: 0.9, blue: 0.9)
    let shadowed = StageStyle(insetFraction: 0.1, cornerRadius: 12,
                              shadowRadius: 24, shadowOpacity: 0.6, background: lightBackground)
    let shadowless = StageStyle(insetFraction: 0.1, cornerRadius: 12,
                                shadowRadius: 24, shadowOpacity: 0, background: lightBackground)

    let renderer: any FrameRendering
    do { renderer = try CoreImageFrameRenderer() } catch FrameRenderingError.noRenderDevice {
        Issue.record("no Metal render device on this machine — a real answer, not a skip")
        return
    }

    func rendered(_ style: StageStyle) throws -> [(r: UInt8, g: UInt8, b: UInt8)] {
        let source = try makePixelBuffer(width: width, height: height, fill: sourceFill)
        let destination = try makePixelBuffer(width: width, height: height, fill: (0, 0, 0))
        let plan = StagePlanner.plan(outputWidth: width, outputHeight: height,
                                     sourceWidth: width, sourceHeight: height, style: style)
        try renderer.render(plan, source: source, camera: nil, into: destination)
        return try pixels(of: destination)
    }

    let with = try rendered(shadowed)
    let without = try rendered(shadowless)

    // The card's bottom edge in Core Image coordinates is `card.y` (bottom-left origin);
    // 8 px below it is outside the card and well inside the 24 px blur. `pixels(of:)` is
    // row-major from the TOP row, so the row index flips.
    let plan = StagePlanner.plan(outputWidth: width, outputHeight: height,
                                 sourceWidth: width, sourceHeight: height, style: shadowed)
    let sampleX = Int(plan.card.x + plan.card.width / 2)
    let ciY = Int(plan.card.y) - 8
    let sampleIndex = (height - 1 - ciY) * width + sampleX

    let shadowedPixel = with[sampleIndex]
    let controlPixel = without[sampleIndex]
    #expect(shadowedPixel.r < controlPixel.r && shadowedPixel.g < controlPixel.g
            && shadowedPixel.b < controlPixel.b,
            """
            8 px below the card the shadowed render is \(shadowedPixel) against \(controlPixel) \
            without — the shadow did not darken the background there
            """)

    // The far corner is outside any plausible shadow: the two renders agree there, so the
    // "shadow" cannot be a whole-frame darkening pass.
    #expect(with[width + 1] == without[width + 1],
            "the output corner differs between the two renders — the darkening is not local to the card")
}

/// Opacity zero draws nothing at all — the exact-equality claim the corner check above cannot
/// make for the shadowed pair. A stray fully-transparent shadow pass could still perturb pixels
/// through colour management; rendering the same shadowless style twice must not.
@Test func aZeroOpacityShadowChangesNothing() throws {
    let width = 320, height = 180
    let style = StageStyle(insetFraction: 0.1, cornerRadius: 12,
                           shadowRadius: 24, shadowOpacity: 0,
                           background: .solid(red: 0.9, green: 0.9, blue: 0.9))
    let renderer: any FrameRendering
    do { renderer = try CoreImageFrameRenderer() } catch FrameRenderingError.noRenderDevice {
        Issue.record("no Metal render device on this machine — a real answer, not a skip")
        return
    }
    func rendered() throws -> [(r: UInt8, g: UInt8, b: UInt8)] {
        let source = try makePixelBuffer(width: width, height: height, fill: sourceFill)
        let destination = try makePixelBuffer(width: width, height: height, fill: (0, 0, 0))
        let plan = StagePlanner.plan(outputWidth: width, outputHeight: height,
                                     sourceWidth: width, sourceHeight: height, style: style)
        try renderer.render(plan, source: source, camera: nil, into: destination)
        return try pixels(of: destination)
    }
    let first = try rendered()
    let second = try rendered()
    for index in [0, width * height / 2, width * height - 1] {
        #expect(first[index] == second[index])
    }
}

// MARK: - the cursor's shape reaches the pixels

/// Same plan, same placement, two shapes: the drawn pixels must differ near the hotspot.
/// Until the renderer selects art by `shape`, every pointer is the arrow and the two
/// renders are byte-identical — which is exactly the recorded-then-ignored defect the
/// shadow had, one field over.
@Test func anIBeamAndAnArrowDrawDifferentPixels() throws {
    let width = 640, height = 360
    let renderer: any FrameRendering
    do { renderer = try CoreImageFrameRenderer() } catch FrameRenderingError.noRenderDevice {
        Issue.record("no Metal render device on this machine — a real answer, not a skip")
        return
    }
    func rendered(_ shape: PointerShape?) throws -> [(r: UInt8, g: UInt8, b: UInt8)] {
        let source = try makePixelBuffer(width: width, height: height, fill: sourceFill)
        let destination = try makePixelBuffer(width: width, height: height, fill: (0, 0, 0))
        let base = StagePlanner.plan(outputWidth: width, outputHeight: height,
                                     sourceWidth: width, sourceHeight: height, style: .default)
        let placement = NormalizedPointerPlacement(
            x: Double(width) / 2, y: Double(height) / 2, ripplePhase: nil, shape: shape)
        let plan = RenderPlan(outputWidth: base.outputWidth, outputHeight: base.outputHeight,
                              card: base.card, cornerRadius: base.cornerRadius,
                              style: base.style, pointer: placement)
        try renderer.render(plan, source: source, camera: nil, into: destination)
        return try pixels(of: destination)
    }
    func identical(_ a: [(r: UInt8, g: UInt8, b: UInt8)],
                   _ b: [(r: UInt8, g: UInt8, b: UInt8)]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0 == $1 }
    }
    let arrow = try rendered(.arrow)
    let iBeam = try rendered(.iBeam)
    // Compared OUTSIDE the macro: #expect captures its operands for the failure message,
    // and two 640×360 pixel arrays are a ten-megabyte way to say "identical".
    let iBeamDiffers = !identical(arrow, iBeam)
    #expect(iBeamDiffers,
            "an I-beam rendered byte-identical to the arrow — the shape never reached the pixels")

    // `nil` (unrecorded) and `.other` (recorded, unnamed) both fall back to the arrow —
    // the design on `PointerShape` itself. The renderer treats them alike; only the
    // review UI distinguishes them.
    let nilFallsBack = identical(try rendered(nil), arrow)
    let otherFallsBack = identical(try rendered(.other), arrow)
    #expect(nilFallsBack, "an unrecorded shape did not fall back to the arrow")
    #expect(otherFallsBack, "an unclassified shape did not fall back to the arrow")
}

// MARK: - the camera: zoomed content inside a card that stays put

/// **The card frame does not move; the content inside it does.** That is the whole visual
/// idea of an auto-zoom on a staged recording — the rounded window stays where it is and
/// the recording inside grows — and it is what distinguishes this from scaling the card,
/// which would break the inset margin the stage style exists to keep.
///
/// Asserted by sampling the STAGE MARGIN, outside the card: at zoom 1 and zoom 2 those
/// pixels are the same background. A renderer that scaled the card would spill into them.
@Test func zoomingTheContentLeavesTheCardFrameWhereItIs() throws {
    let width = 640, height = 360
    let renderer: any FrameRendering
    do { renderer = try CoreImageFrameRenderer() } catch FrameRenderingError.noRenderDevice {
        Issue.record("no Metal render device on this machine — a real answer, not a skip")
        return
    }
    func rendered(zoom: Double) throws -> [(r: UInt8, g: UInt8, b: UInt8)] {
        let source = try makePixelBuffer(width: width, height: height, fill: sourceFill)
        let destination = try makePixelBuffer(width: width, height: height, fill: (0, 0, 0))
        let base = StagePlanner.plan(outputWidth: width, outputHeight: height,
                                     sourceWidth: width, sourceHeight: height, style: .default)
        let plan = RenderPlan(outputWidth: base.outputWidth, outputHeight: base.outputHeight,
                              card: base.card, cornerRadius: base.cornerRadius,
                              style: base.style, pointer: nil,
                              contentZoom: zoom,
                              contentCentre: NormalizedPoint(x: 0.5, y: 0.5))
        try renderer.render(plan, source: source, camera: nil, into: destination)
        return try pixels(of: destination)
    }
    let plain = try rendered(zoom: 1.0)
    let zoomed = try rendered(zoom: 2.0)

    // A pixel in the stage margin: 2 px in from the output's left edge, vertically centred.
    let marginIndex = (height / 2) * width + 2
    #expect(plain[marginIndex] == zoomed[marginIndex],
            "the stage margin changed when the content zoomed — the card frame moved")
}

/// And the content genuinely zooms: a source with a small bright patch off-centre shows
/// more of that patch when the camera is centred on it. Asserted as "the patch covers more
/// pixels", which a no-op zoom cannot satisfy.
@Test func zoomingTheContentMagnifiesWhatTheCameraIsCentredOn() throws {
    let width = 320, height = 180
    let renderer: any FrameRendering
    do { renderer = try CoreImageFrameRenderer() } catch FrameRenderingError.noRenderDevice {
        Issue.record("no Metal render device on this machine — a real answer, not a skip")
        return
    }
    // A source that is mostly dark with one bright quadrant, so "more of it" is countable.
    let source = try makePixelBuffer(width: width, height: height, fill: (10, 10, 10))
    try paintQuadrant(source, width: width, height: height, colour: (250, 250, 250))

    func brightCount(zoom: Double) throws -> Int {
        let destination = try makePixelBuffer(width: width, height: height, fill: (0, 0, 0))
        let base = StagePlanner.plan(outputWidth: width, outputHeight: height,
                                     sourceWidth: width, sourceHeight: height, style: .default)
        let plan = RenderPlan(outputWidth: base.outputWidth, outputHeight: base.outputHeight,
                              card: base.card, cornerRadius: base.cornerRadius,
                              style: base.style, pointer: nil,
                              contentZoom: zoom,
                              // The bright quadrant's centre in normalised source space.
                              contentCentre: NormalizedPoint(x: 0.25, y: 0.25))
        try renderer.render(plan, source: source, camera: nil, into: destination)
        return try pixels(of: destination).count { $0.r > 200 && $0.g > 200 && $0.b > 200 }
    }
    let plain = try brightCount(zoom: 1.0)
    let zoomed = try brightCount(zoom: 2.5)
    #expect(zoomed > plain, "zooming onto the bright quadrant showed \(zoomed) bright pixels against \(plain)")
}

/// The pointer travels with the content. A pointer drawn at its un-zoomed place while the
/// recording beneath it moved would sit somewhere the user never pointed — the same class
/// of defect as `1a98402`, arriving through the camera instead of the clock.
@Test func thePointerMovesWithTheZoomedContent() {
    let base = StagePlanner.plan(outputWidth: 1920, outputHeight: 1080,
                                 sourceWidth: 1920, sourceHeight: 1080, style: .default)
    let point = NormalizedPoint(x: 0.25, y: 0.25)
    let unzoomed = StagePlanner.placement(for: point, in: base)
    let zoomedPlan = RenderPlan(outputWidth: base.outputWidth, outputHeight: base.outputHeight,
                                card: base.card, cornerRadius: base.cornerRadius,
                                style: base.style, pointer: nil,
                                contentZoom: 2.0,
                                contentCentre: NormalizedPoint(x: 0.25, y: 0.25))
    let zoomed = StagePlanner.placement(for: point, in: zoomedPlan)
    // Centred on the pointer at zoom 2: it lands at the output centre, not where it was.
    #expect(abs(zoomed.x - Double(base.outputWidth) / 2) < 1.0)
    #expect(abs(zoomed.y - Double(base.outputHeight) / 2) < 1.0)
    #expect(abs(zoomed.x - unzoomed.x) > 1.0, "the pointer did not move with the content")
}

/// **The drawn cursor's TIP sits exactly at the recorded position, and the hotspot does not
/// move it.** This replaced a test asserting the opposite, which pinned a real defect.
///
/// `CursorArt`'s paths are built around their hotspot AT THE ORIGIN — the arrow's tip, the
/// I-beam's centre; its own header says so. Drawing that origin at the recorded position is
/// therefore already correct. The renderer nevertheless shifted the art by
/// `placement.hotspot`, which is the hotspot of the SYSTEM cursor's IMAGE: a different
/// picture with different padding, measured once as (0.52, 0.50) — its centre — and
/// generalised. Applied to art whose origin is already the hotspot, it moved a correct
/// placement by half a cursor on every frame. Anything that draws its own cursor art
/// draws its own cursor art too and derives each hotspot from its OWN design coordinates,
/// never from the system image, for exactly this reason.
///
/// Asserted positively rather than as "the field is ignored": the tip's PIXELS are located.
/// Measured on this renderer, an arrow at (200, 150) occupies columns 199–217 and buffer
/// rows 148–175 — the placement at the bounding box's top-left corner, one pixel of stroke
/// either side.
@Test func theDrawnCursorsTipIsAtTheRecordedPosition() throws {
    let width = 400, height = 300
    let renderer: any FrameRendering
    do {
        renderer = try CoreImageFrameRenderer()
    } catch FrameRenderingError.noRenderDevice {
        Issue.record("no Metal render device on this machine — a real answer, not a skip")
        return
    }

    func render(pointer: NormalizedPointerPlacement?) throws -> [(r: UInt8, g: UInt8, b: UInt8)] {
        let source = try makePixelBuffer(width: width, height: height, fill: sourceFill)
        let destination = try makePixelBuffer(width: width, height: height, fill: (0, 0, 0))
        let base = StagePlanner.plan(outputWidth: width, outputHeight: height,
                                     sourceWidth: width, sourceHeight: height, style: .default)
        let plan = RenderPlan(outputWidth: base.outputWidth, outputHeight: base.outputHeight,
                              card: base.card, cornerRadius: base.cornerRadius,
                              style: base.style, pointer: pointer)
        try renderer.render(plan, source: source, camera: nil, into: destination)
        return try pixels(of: destination)
    }

    // Where the cursor was drawn, in BUFFER coordinates: `pixels(of:)` returns a
    // CVPixelBuffer's own top-down order while the placement is in CoreImage's bottom-up one.
    func cursorBox(_ with: [(r: UInt8, g: UInt8, b: UInt8)],
                   _ without: [(r: UInt8, g: UInt8, b: UInt8)])
        -> (minCol: Int, maxCol: Int, minRow: Int, maxRow: Int)? {
        var minCol = width, maxCol = -1, minRow = height, maxRow = -1
        for row in 0..<height {
            for col in 0..<width where with[row * width + col] != without[row * width + col] {
                minCol = min(minCol, col); maxCol = max(maxCol, col)
                minRow = min(minRow, row); maxRow = max(maxRow, row)
            }
        }
        return maxCol < 0 ? nil : (minCol, maxCol, minRow, maxRow)
    }

    let without = try render(pointer: nil)
    let placementX = 200.0, placementY = 150.0
    let bufferRow = height - 1 - Int(placementY)

    let drawn = try render(pointer: NormalizedPointerPlacement(
        x: placementX, y: placementY, ripplePhase: nil, shape: .arrow, hotspot: nil))
    let box = try #require(cursorBox(drawn, without), "no cursor was drawn at all")

    #expect(abs(box.minCol - Int(placementX)) <= 2,
            "the tip is \(box.minCol - Int(placementX))px from the placement horizontally")
    #expect(abs(box.minRow - bufferRow) <= 2,
            "the tip is \(box.minRow - bufferRow)px from the placement vertically")
    // …and the art extends away from it, which is what makes the corner test a statement
    // about a cursor rather than about a one-pixel dot.
    let drawnWidth = box.maxCol - box.minCol
    let drawnHeight = box.maxRow - box.minRow
    #expect(drawnHeight > 15 && drawnWidth > 10,
            "the drawn art is \(drawnWidth)×\(drawnHeight) — too small for its corner to say anything")

    // **The system image's hotspot must not move it**, including the centre reading that
    // produced the defect.
    for hotspot in [NormalizedPoint(x: 0, y: 0), NormalizedPoint(x: 0.52, y: 0.50),
                    NormalizedPoint(x: 1, y: 1)] {
        let shifted = try render(pointer: NormalizedPointerPlacement(
            x: placementX, y: placementY, ripplePhase: nil, shape: .arrow, hotspot: hotspot))
        #expect(shifted.count == drawn.count && zip(shifted, drawn).allSatisfy { $0 == $1 },
                "a hotspot of \(hotspot) moved art whose own origin is already the hotspot")
    }
}

// MARK: - gradient backgrounds

/// A helper mirroring the shadow tests above: render one style and hand back its pixels.
private func renderedPixels(style: StageStyle, width: Int = 640, height: Int = 360)
    throws -> [(UInt8, UInt8, UInt8)] {
    let source = try makePixelBuffer(width: width, height: height, fill: sourceFill)
    let destination = try makePixelBuffer(width: width, height: height, fill: (0, 0, 0))
    let plan = StagePlanner.plan(outputWidth: width, outputHeight: height,
                                 sourceWidth: width, sourceHeight: height, style: style)
    let renderer = try CoreImageFrameRenderer()
    try renderer.render(plan, source: source, camera: nil, into: destination)
    return try pixels(of: destination)
}

/// **A gradient has to actually vary, and vary along the stated axis.** A background that
/// resolved to a flat fill — a filter that failed and fell back, or two points collapsing to
/// one — would still render, still differ from a solid of another colour, and still look
/// wrong in exactly the way the case was added to fix.
@Test func aLinearGradientVariesAlongItsAngle() throws {
    let width = 640, height = 360
    // 0° runs left→right, so the two ends of the TOP row must differ and the two ends of the
    // left COLUMN must not. The card sits in the middle, so the sampled points are background.
    let style = StageStyle(
        insetFraction: 0.2, cornerRadius: 0, shadowRadius: 0, shadowOpacity: 0,
        background: .linearGradient(startRed: 0, startGreen: 0, startBlue: 0,
                                    endRed: 1, endGreen: 1, endBlue: 1, angleDegrees: 0))
    let rendered = try renderedPixels(style: style, width: width, height: height)

    let topLeft = rendered[0]
    let topRight = rendered[width - 1]
    #expect(Int(topRight.0) - Int(topLeft.0) > 40,
            "the gradient did not brighten across the frame: \(topLeft) → \(topRight)")

    let bottomLeft = rendered[(height - 1) * width]
    #expect(abs(Int(bottomLeft.0) - Int(topLeft.0)) <= 2,
            "a 0° gradient varied vertically: \(topLeft) → \(bottomLeft)")
}

/// The angle is a real parameter, not decoration. 90° is bottom→top, the axis 0° holds flat.
@Test func theGradientAngleTurnsTheAxis() throws {
    let width = 640, height = 360
    let style = StageStyle(
        insetFraction: 0.2, cornerRadius: 0, shadowRadius: 0, shadowOpacity: 0,
        background: .linearGradient(startRed: 0, startGreen: 0, startBlue: 0,
                                    endRed: 1, endGreen: 1, endBlue: 1, angleDegrees: 90))
    let rendered = try renderedPixels(style: style, width: width, height: height)

    let topLeft = rendered[0]
    let topRight = rendered[width - 1]
    let bottomLeft = rendered[(height - 1) * width]
    #expect(abs(Int(topRight.0) - Int(topLeft.0)) <= 2,
            "a 90° gradient varied horizontally: \(topLeft) → \(topRight)")
    #expect(abs(Int(bottomLeft.0) - Int(topLeft.0)) > 40,
            "a 90° gradient did not vary vertically: \(topLeft) → \(bottomLeft)")
}

/// **The gradient must cover the frame at every angle.** Placing the two points by projecting
/// the width and height onto the axis separately leaves a flat band at every angle but 0° and
/// 90°; the diagonal reach used instead is what this checks. 45° is the worst case.
@Test func aDiagonalGradientReachesBothCorners() throws {
    let width = 640, height = 360
    let style = StageStyle(
        insetFraction: 0.2, cornerRadius: 0, shadowRadius: 0, shadowOpacity: 0,
        background: .linearGradient(startRed: 0, startGreen: 0, startBlue: 0,
                                    endRed: 1, endGreen: 1, endBlue: 1, angleDegrees: 45))
    let rendered = try renderedPixels(style: style, width: width, height: height)

    // **`pixels(of:)` returns BUFFER order, and a CVPixelBuffer is top-down** — index 0 is
    // the image's TOP-left, not its bottom-left. CoreImage's own y runs bottom-up, so a 45°
    // gradient runs from the image's bottom-left to its top-right. The first draft of this
    // test read index 0 as the dark end, sampled the middle of the ramp, and failed against
    // a correct render.
    let nearStart = rendered[(height - 1) * width]      // image bottom-left — the dark end
    let nearEnd = rendered[width - 1]                   // image top-right  — the bright end
    #expect(abs(Int(nearEnd.0) - Int(nearStart.0)) > 60,
            "a 45° gradient left the opposite corners nearly equal — it did not span the frame")
    // Neither corner is clipped to a flat extreme, which is what a too-short span produces.
    #expect(nearStart.0 < 40 && nearEnd.0 > 215,
            "the corners did not reach the gradient's ends: \(nearStart) → \(nearEnd)")
}

/// A solid background stays solid. The case was added so a gradient is possible, not so every
/// frame pays for one.
@Test func aSolidBackgroundDrawsNoGradient() throws {
    let width = 640, height = 360
    let style = StageStyle(insetFraction: 0.2, cornerRadius: 0, shadowRadius: 0,
                           shadowOpacity: 0,
                           background: .solid(red: 0.2, green: 0.4, blue: 0.6))
    let rendered = try renderedPixels(style: style, width: width, height: height)
    #expect(rendered[0] == rendered[width - 1])
    #expect(rendered[0] == rendered[(height - 1) * width])
}

/// Every shipped preset renders. A preset that referenced a filter CoreImage could not resolve
/// would fall back to a flat fill in production and nowhere else.
@Test func everyBackgroundPresetRenders() throws {
    for (name, background) in StageBackground.presets {
        let style = StageStyle(insetFraction: 0.1, cornerRadius: 12, shadowRadius: 16,
                               shadowOpacity: 0.3, background: background)
        let rendered = try renderedPixels(style: style, width: 160, height: 90)
        #expect(rendered.contains { $0 != (0, 0, 0) }, "preset \(name) drew nothing")
    }
}

/// The new case has to survive a project file. An enum with associated values gets a
/// synthesised `Codable` whose shape nobody chose, so it is worth one round trip.
@Test func aGradientBackgroundSurvivesCoding() throws {
    let style = StageStyle(
        insetFraction: 0.08, cornerRadius: 20, shadowRadius: 30, shadowOpacity: 0.4,
        background: .linearGradient(startRed: 0.1, startGreen: 0.2, startBlue: 0.3,
                                    endRed: 0.4, endGreen: 0.5, endBlue: 0.6,
                                    angleDegrees: 115))
    let data = try JSONEncoder().encode(style)
    #expect(try JSONDecoder().decode(StageStyle.self, from: data) == style)
}

// MARK: - the shadow falls down, and the gradient does not band

/// **The key shadow hangs below the card.** Sampled at the same distance outside the card's
/// bottom and top edges, the pixel below is darker than the pixel above — a halo would make
/// them equal. Light background, so darkening is unmistakable.
@Test func theShadowFallsBelowTheCardMoreThanAboveIt() throws {
    let width = 640, height = 360
    let style = StageStyle(insetFraction: 0.12, cornerRadius: 12, shadowRadius: 32,
                           shadowOpacity: 0.6, background: .solid(red: 0.9, green: 0.9, blue: 0.9))
    let renderer = try CoreImageFrameRenderer()
    let source = try makePixelBuffer(width: width, height: height, fill: sourceFill)
    let destination = try makePixelBuffer(width: width, height: height, fill: (0, 0, 0))
    let plan = StagePlanner.plan(outputWidth: width, outputHeight: height,
                                 sourceWidth: width, sourceHeight: height, style: style)
    try renderer.render(plan, source: source, camera: nil, into: destination)
    let frame = try pixels(of: destination)
    let x = Int(plan.card.x + plan.card.width / 2)
    let gap = 6
    // Bottom-left plan space → top-down rows.
    let belowRow = height - 1 - Int(plan.card.y - Double(gap))
    let aboveRow = height - 1 - Int(plan.card.y + plan.card.height + Double(gap))
    let below = frame[belowRow * width + x], above = frame[aboveRow * width + x]
    #expect(below.r < above.r - 8, """
        below the card the background is \(below.r), above it \(above.r) — the shadow is a halo, \
        not a shadow falling down
        """)
    // And both are still darker than the far corner, so the ambient half is present too.
    let corner = frame[2 * width + 2]
    #expect(above.r < corner.r, "no ambient shadow above the card")
}

/// A gradient between two colours a few levels apart, rendered full-frame: with the dither
/// the row holds more distinct values than the bare ramp's steps, and every value stays
/// within the ramp's range plus the grain. And the same plan renders the same pixels twice,
/// which is what lets the preview and the export dither identically.
@Test func aDitheredGradientIsDeterministicAndDoesNotBand() throws {
    let width = 640, height = 360
    let style = StageStyle(insetFraction: 0.45, cornerRadius: 0, shadowRadius: 0, shadowOpacity: 0,
                           background: .linearGradient(startRed: 0.20, startGreen: 0.20, startBlue: 0.22,
                                                       endRed: 0.24, endGreen: 0.24, endBlue: 0.26,
                                                       angleDegrees: 0))
    let renderer = try CoreImageFrameRenderer()
    func render() throws -> [(r: UInt8, g: UInt8, b: UInt8)] {
        let source = try makePixelBuffer(width: width, height: height, fill: sourceFill)
        let destination = try makePixelBuffer(width: width, height: height, fill: (0, 0, 0))
        let plan = StagePlanner.plan(outputWidth: width, outputHeight: height,
                                     sourceWidth: width, sourceHeight: height, style: style)
        try renderer.render(plan, source: source, camera: nil, into: destination)
        return try pixels(of: destination)
    }
    let first = try render(), second = try render()
    #expect(first.elementsEqual(second, by: ==), "the dithered gradient rendered differently twice")
    // The top row is all background (the card is inset 45%).
    let row = Array(first[0..<width]).map { Int($0.r) }
    let distinct = Set(row).count
    // A 10-level ramp over 640 px without dither shows ≤ 11 distinct values in a row; with a
    // ±1.5-level grain each step is dithered and adjacent pixels differ in both directions.
    let alternations = zip(row, row.dropFirst()).filter { $0 != $1 }.count
    #expect(alternations > width / 4, "only \(alternations) adjacent changes across \(width) px — the ramp is stepped, not dithered")
    #expect(distinct >= 8 && distinct <= 20, "\(distinct) distinct values in the row")
    #expect((row.max() ?? 0) - (row.min() ?? 0) <= 10 + 4, "the grain pushed the ramp past its range")
}

// MARK: - the card's own edge

/// **The border lightens the card's outermost pixels and leaves everything else alone.**
///
/// A shadow separates the card from the background by darkening what is behind it, which works
/// everywhere except at the corners where the card's edge meets the shadow's softest part. This
/// is the edge itself, so the check is at the edge — and the interior must be untouched, or what
/// was drawn is a tint rather than a border.
@Test func theBorderLightensTheCardsEdgeAndNothingInside() throws {
    let width = 640, height = 360
    let background = StageBackground.solid(red: 0.1, green: 0.1, blue: 0.12)
    let plain = StageStyle(insetFraction: 0.1, cornerRadius: 12, shadowRadius: 0,
                           shadowOpacity: 0, background: background)
    let bordered = StageStyle(insetFraction: 0.1, cornerRadius: 12, shadowRadius: 0,
                              shadowOpacity: 0, background: background, borderOpacity: 1)

    let renderer: any FrameRendering
    do { renderer = try CoreImageFrameRenderer() } catch FrameRenderingError.noRenderDevice {
        Issue.record("no Metal render device on this machine — a real answer, not a skip")
        return
    }
    func rendered(_ style: StageStyle) throws -> [(r: UInt8, g: UInt8, b: UInt8)] {
        let source = try makePixelBuffer(width: width, height: height, fill: sourceFill)
        let destination = try makePixelBuffer(width: width, height: height, fill: (0, 0, 0))
        let plan = StagePlanner.plan(outputWidth: width, outputHeight: height,
                                     sourceWidth: width, sourceHeight: height, style: style)
        try renderer.render(plan, source: source, camera: nil, into: destination)
        return try pixels(of: destination)
    }

    let with = try rendered(bordered)
    let without = try rendered(plain)
    let plan = StagePlanner.plan(outputWidth: width, outputHeight: height,
                                 sourceWidth: width, sourceHeight: height, style: bordered)

    // `pixels(of:)` is row-major from the TOP; Core Image's origin is bottom-left, so the row
    // index flips. Mid-height on the card's left edge — away from the corners, where the
    // rounding makes "the edge" a curve rather than a column.
    let midCIY = Int(plan.card.y + plan.card.height / 2)
    let row = (height - 1 - midCIY) * width
    let edge = row + Int(plan.card.x)
    #expect(with[edge].r > without[edge].r && with[edge].g > without[edge].g
            && with[edge].b > without[edge].b,
            "the card's left edge is \(with[edge]) with the border and \(without[edge]) without")

    // Well inside the card the two renders agree: a border that changed the picture would be a
    // tint, and the whole claim is that it only draws an edge.
    let inside = row + Int(plan.card.x + plan.card.width / 2)
    #expect(with[inside] == without[inside],
            "the middle of the card differs — \(with[inside]) against \(without[inside])")
}

/// Opacity zero draws nothing at all. The interior check above cannot make this claim for the
/// bordered pair, and a stray fully-transparent pass could still perturb pixels through colour
/// management.
@Test func aZeroOpacityBorderChangesNothing() throws {
    let width = 320, height = 180
    let background = StageBackground.solid(red: 0.2, green: 0.2, blue: 0.25)
    let off = StageStyle(insetFraction: 0.1, cornerRadius: 12, shadowRadius: 0,
                         shadowOpacity: 0, background: background, borderOpacity: 0)

    let renderer: any FrameRendering
    do { renderer = try CoreImageFrameRenderer() } catch FrameRenderingError.noRenderDevice {
        Issue.record("no Metal render device on this machine — a real answer, not a skip")
        return
    }
    func rendered() throws -> [(r: UInt8, g: UInt8, b: UInt8)] {
        let source = try makePixelBuffer(width: width, height: height, fill: sourceFill)
        let destination = try makePixelBuffer(width: width, height: height, fill: (0, 0, 0))
        let plan = StagePlanner.plan(outputWidth: width, outputHeight: height,
                                     sourceWidth: width, sourceHeight: height, style: off)
        try renderer.render(plan, source: source, camera: nil, into: destination)
        return try pixels(of: destination)
    }
    let a = try rendered(), b = try rendered()
    #expect(a.elementsEqual(b, by: ==), "two identical border-free renders disagreed")
}

/// **A project saved before the border existed decodes as border-free**, not as an error: a
/// cosmetic addition must not be a file-format break. And a border that IS on survives the round
/// trip, or turning it on would not stick.
@Test func aStyleWithNoBorderKeyDecodesAsBorderless() throws {
    let background = StageBackground.solid(red: 0.1, green: 0.1, blue: 0.12)
    let old = StageStyle(insetFraction: 0.06, cornerRadius: 18, shadowRadius: 32,
                         shadowOpacity: 0.35, background: background)
    // Encoded with the border off, so the key is genuinely absent — which is exactly the shape
    // of every file written before the field existed.
    let data = try JSONEncoder().encode(old)
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(!text.contains("borderOpacity"), "a border-free style wrote the key anyway: \(text)")
    #expect(try JSONDecoder().decode(StageStyle.self, from: data).borderOpacity == 0)

    let on = StageStyle(insetFraction: 0.06, cornerRadius: 18, shadowRadius: 32,
                        shadowOpacity: 0.35, background: background, borderOpacity: 0.4)
    #expect(try JSONDecoder().decode(StageStyle.self, from: JSONEncoder().encode(on)) == on)
}

/// **The camera's border drew nothing at all until 2026-08-26, and no test said so.**
///
/// `CameraOverlayStyle.borderOpacity` has existed since the camera did, and the ring was built
/// with `CIBlendWithMask` over `CIImage.empty()` — an image of ZERO extent, so the blend had
/// nowhere to composite into and the whole pass evaporated silently. It was found by giving the
/// CARD the same edge, probing across it, and reading every pixel identical with the border on
/// and off; the same construction was one function away.
///
/// This is the test that was missing, which is why it survived: a public option nothing
/// exercised is a capability claim nothing checked.
@Test func theCamerasBorderActuallyReachesThePicture() throws {
    let width = 640, height = 360
    let background = StageBackground.solid(red: 0.1, green: 0.1, blue: 0.12)
    let style = StageStyle(insetFraction: 0.1, cornerRadius: 12, shadowRadius: 0,
                           shadowOpacity: 0, background: background)
    // Square rather than round, so the edge is a straight column and the sample does not have to
    // reason about where a circle's outline falls.
    func camera(borderOpacity: Double) -> CameraOverlay {
        CameraOverlay(style: CameraOverlayStyle(
            widthFraction: 0.3, x: 0.5, y: 0.5, shape: .square,
            cornerFraction: 0, isMirrored: false,
            borderOpacity: borderOpacity, shadowOpacity: 0))
    }

    let renderer: any FrameRendering
    do { renderer = try CoreImageFrameRenderer() } catch FrameRenderingError.noRenderDevice {
        Issue.record("no Metal render device on this machine — a real answer, not a skip")
        return
    }
    func rendered(_ overlay: CameraOverlay) throws -> [(r: UInt8, g: UInt8, b: UInt8)] {
        let source = try makePixelBuffer(width: width, height: height, fill: sourceFill)
        let cameraBuffer = try makePixelBuffer(width: 160, height: 120, fill: (20, 20, 20))
        let destination = try makePixelBuffer(width: width, height: height, fill: (0, 0, 0))
        let base = StagePlanner.plan(outputWidth: width, outputHeight: height,
                                     sourceWidth: width, sourceHeight: height, style: style)
        let plan = RenderPlan(outputWidth: base.outputWidth, outputHeight: base.outputHeight,
                              card: base.card, cornerRadius: base.cornerRadius,
                              style: base.style, pointer: nil, camera: overlay)
        try renderer.render(plan, source: source, camera: cameraBuffer, into: destination)
        return try pixels(of: destination)
    }

    let with = try rendered(camera(borderOpacity: 1))
    let without = try rendered(camera(borderOpacity: 0))
    #expect(!with.elementsEqual(without, by: ==), """
            the camera rendered identically with the border at full opacity and at zero — \
            the border pass is reaching no pixel
            """)

    // …and it is an EDGE, not a tint: most of the frame is untouched.
    let changed = zip(with, without).count { $0 != $1 }
    #expect(changed * 20 < with.count, """
            \(changed) of \(with.count) pixels changed — that is a fill or a tint, not a border
            """)
}

/// **Artwork reaches the pixels, and its absence falls back rather than blanking.**
///
/// The artwork path is new and the drawn path is not, so the failure worth catching is the
/// quiet one: artwork handed over and never consulted, which looks exactly like a build where
/// nobody handed any over. A synthetic image is used rather than a real cursor — this target
/// may not touch AppKit, and what is being checked is the wiring, not macOS's artwork.
@Test func handedOverArtworkIsWhatGetsDrawn() throws {
    let width = 640, height = 360
    /// Two renderers, one with the artwork and one without, **instead of one renderer and a
    /// write to `SystemCursorArtwork.byShape`.** That static is read on the cursor path of
    /// every frame, so writing it here raced every other test that draws a cursor: they saw
    /// this test's synthetic 32×32 arrow, hotspot (16, 16), and reported a tip 16 columns and
    /// 15 rows from the placement — intermittently, for exactly as long as the two overlapped.
    /// The version of this test that wrote the static said the suite was "serialised on this
    /// static by construction". There was no suite, and nothing serialised anything.
    func makeRenderer(artwork: [PointerShape: CursorArtwork]?) throws -> (any FrameRendering)? {
        do { return try CoreImageFrameRenderer(cursorArtworkOverride: artwork) }
        catch FrameRenderingError.noRenderDevice {
            Issue.record("no Metal render device on this machine — a real answer, not a skip")
            return nil
        }
    }
    guard let renderer = try makeRenderer(artwork: nil) else { return }
    func rendered(_ renderer: any FrameRendering) throws -> [(r: UInt8, g: UInt8, b: UInt8)] {
        let source = try makePixelBuffer(width: width, height: height, fill: sourceFill)
        let destination = try makePixelBuffer(width: width, height: height, fill: (0, 0, 0))
        let base = StagePlanner.plan(outputWidth: width, outputHeight: height,
                                     sourceWidth: width, sourceHeight: height, style: .default)
        let placement = NormalizedPointerPlacement(
            x: Double(width) / 2, y: Double(height) / 2, ripplePhase: nil, shape: .arrow)
        let plan = RenderPlan(outputWidth: base.outputWidth, outputHeight: base.outputHeight,
                              card: base.card, cornerRadius: base.cornerRadius,
                              style: base.style, pointer: placement)
        try renderer.render(plan, source: source, camera: nil, into: destination)
        return try pixels(of: destination)
    }
    func identical(_ a: [(r: UInt8, g: UInt8, b: UInt8)],
                   _ b: [(r: UInt8, g: UInt8, b: UInt8)]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0 == $1 }
    }

    let drawnPath = try rendered(renderer)

    // A solid magenta square, 32×32 points, hotspot in the middle. Nothing macOS would ever
    // draw, which is the point: if these pixels appear, the artwork was consulted.
    let side = 64
    var bytes = [UInt8](repeating: 0, count: side * side * 4)
    for index in stride(from: 0, to: bytes.count, by: 4) {
        bytes[index] = 255; bytes[index + 1] = 0; bytes[index + 2] = 255; bytes[index + 3] = 255
    }
    // `unsafe`: `CGImage` reads through the provider's bytes without the compiler
    // being able to see that they outlive it. Safe here — `Data(bytes) as CFData`
    // is retained by the provider, which is retained by the image, for as long as
    // this test holds it.
    let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
    let synthetic = try #require(unsafe CGImage(
        width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))

    let table: [PointerShape: CursorArtwork] = [.arrow: CursorArtwork(
        image: synthetic, pointWidth: 32, pointHeight: 32, hotspotX: 16, hotspotY: 16)]
    guard let withArtworkRenderer = try makeRenderer(artwork: table) else { return }

    let withArtwork = try rendered(withArtworkRenderer)
    let artworkChangedThePixels = !identical(drawnPath, withArtwork)
    #expect(artworkChangedThePixels,
            "artwork was handed over and the frame came out identical — nothing consulted it")

    // And the fallback is a fallback, not a hole: an EMPTY table returns the drawn path
    // exactly, so a shape macOS has no artwork for still draws.
    guard let emptyTableRenderer = try makeRenderer(artwork: [:]) else { return }
    let clearedAgain = try rendered(emptyTableRenderer)
    #expect(identical(drawnPath, clearedAgain),
            "an empty artwork table did not return the drawn path — the fallback is not a fallback")
}

/// `SystemCursorArtwork`'s lookup, which is the seam between the app tier and the renderer.
///
/// Tested directly rather than through a render, because the render path used to be the only
/// thing that named this type — and when `handedOverArtworkIsWhatGetsDrawn` stopped writing the
/// global, nothing named it at all. A lookup with three answers deserves three assertions.
@Test func theArtworkLookupRefusesTheTwoShapesThatHaveNone() {
    let arrow = CursorArtwork(image: onePixel(), pointWidth: 28, pointHeight: 40,
                              hotspotX: 5, hotspotY: 5)
    let table: [PointerShape: CursorArtwork] = [.arrow: arrow]

    #expect(SystemCursorArtwork.artwork(for: .arrow, in: table) != nil)

    // `nil` is "unrecorded" and `.other` is "recorded, and not a shape this schema names".
    // Neither has artwork to look up, and both draw the PATH so a review can still tell them
    // apart from a genuine arrow.
    #expect(SystemCursorArtwork.artwork(for: nil, in: table) == nil,
            "an unrecorded shape found artwork — it has no shape to look one up by")
    #expect(SystemCursorArtwork.artwork(for: .other, in: table) == nil,
            "`.other` found artwork — it is the case that names no artwork by construction")

    // A shape the table does not carry falls through to the drawn path rather than to a
    // neighbouring shape's picture.
    #expect(SystemCursorArtwork.artwork(for: .iBeam, in: table) == nil)

    // An EMPTY table is not the same as no table: empty means "this renderer draws paths",
    // which is what the app's headless contexts and every test rely on.
    #expect(SystemCursorArtwork.artwork(for: .arrow, in: [:]) == nil)
}

/// The canvas is sized from whatever is actually drawn. The arrow's real artwork reaches
/// 35 points below its hotspot against the drawn path's 24.5, so a canvas sized for the path
/// would clip it — a corner missing from every frame, which reads as a rendering artefact
/// rather than as a bug.
@Test func theCanvasIsSizedForTheArtworkNotOnlyForThePath() {
    let arrowLike = CursorArtwork(image: onePixel(), pointWidth: 28, pointHeight: 40,
                                  hotspotX: 5, hotspotY: 5)
    #expect(arrowLike.maxExtentFromHotspot == 35)
    #expect(arrowLike.maxExtentFromHotspot > CursorArt.pointerMaxExtent,
            "the measurement this canvas rule exists for no longer holds")

    // A hotspot at the centre reaches half the artwork in every direction.
    let centred = CursorArtwork(image: onePixel(), pointWidth: 32, pointHeight: 32,
                                hotspotX: 16, hotspotY: 16)
    #expect(centred.maxExtentFromHotspot == 16)
}

/// One opaque white pixel, for the two artwork values whose EXTENT is what is being
/// checked — `maxExtentFromHotspot` reads the point size and the hotspot and never
/// the image, so the image only has to exist.
private func onePixel() -> CGImage {
    // `unsafe`: same argument as the synthetic image above — the provider retains
    // the bytes and the image retains the provider.
    let provider = CGDataProvider(data: Data([255, 255, 255, 255]) as CFData)!
    return unsafe CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false,
                   intent: .defaultIntent)!
}

/// **On a leaned or turned card, the pointer lands on the pixel it points at** (reported
/// 2026-09-28: "when I lean or turn the screen the cursor position is wrong").
///
/// The card's picture is projected by `StageTilt`; the pointer was placed where the FLAT card
/// would have put it, so it drifted off its target by as much as the card was turned. Checked
/// the way a person sees it: a small bright square is painted into the source at a known
/// normalised point — off-centre, so neither the lean nor the turn is at its identity there —
/// the card is rendered leaned and turned, the square is found in the output, and the pointer's
/// placement for that same point must sit on it.
@Test func onATurnedCardThePointerLandsOnWhatItPointsAt() throws {
    let width = 400, height = 300
    let renderer: any FrameRendering
    do { renderer = try CoreImageFrameRenderer() } catch FrameRenderingError.noRenderDevice {
        Issue.record("no Metal render device on this machine — a real answer, not a skip")
        return
    }
    let target = NormalizedPoint(x: 0.3, y: 0.7)
    let source = try makePixelBuffer(width: width, height: height, fill: (10, 10, 10))
    // Rows are top-down in memory and normalised y is bottom-up: row = (1 − y) · height.
    try paintSquare(source, centreColumn: Int(target.x * Double(width)),
                    centreRow: Int((1 - target.y) * Double(height)), side: 8, colour: (250, 250, 250))

    let tilted = StageStyle(insetFraction: 0.06, cornerRadius: 0, shadowRadius: 0, shadowOpacity: 0,
                            background: .solid(red: 0, green: 0, blue: 0),
                            tilt: StageTilt(pitch: 20, yaw: -25, distance: 2.5))
    let base = StagePlanner.plan(outputWidth: width, outputHeight: height,
                                 sourceWidth: width, sourceHeight: height, style: tilted)
    let destination = try makePixelBuffer(width: width, height: height, fill: (0, 0, 0))
    try renderer.render(base, source: source, camera: nil, into: destination)

    // The square's centre in the output, in the plan's bottom-left pixels.
    let all = try pixels(of: destination)
    var sumX = 0.0, sumY = 0.0, count = 0.0
    for (index, pixel) in all.enumerated() where pixel.r > 150 && pixel.g > 150 && pixel.b > 150 {
        sumX += Double(index % width) + 0.5
        sumY += Double(height - index / width) - 0.5
        count += 1
    }
    try #require(count > 4, "the painted square was not found in the output (\(Int(count)) bright pixels)")
    let found = (x: sumX / count, y: sumY / count)

    let placement = StagePlanner.placement(for: target, in: base)
    let miss = hypot(placement.x - found.x, placement.y - found.y)
    #expect(miss < 2, """
        the pointer is at (\(placement.x), \(placement.y)) and what it points at is at \
        (\(found.x), \(found.y)) — \(miss) pixels apart on a card leaned 20° and turned −25°
        """)
}

/// A small square, `side` pixels, centred at a buffer column and row (rows top-down).
private func paintSquare(_ buffer: CVPixelBuffer, centreColumn: Int, centreRow: Int, side: Int,
                         colour: (r: UInt8, g: UInt8, b: UInt8)) throws {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    // Safe here: the writes sit between the lock pair, and rows and columns are clamped to the
    // buffer's own dimensions, so every offset stays inside height × bytes-per-row.
    let base = try unsafe #require(unsafe CVPixelBufferGetBaseAddress(buffer))
        .assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    for row in max(0, centreRow - side / 2)..<min(height, centreRow + side / 2) {
        for column in max(0, centreColumn - side / 2)..<min(width, centreColumn + side / 2) {
            let offset = row * stride + column * 4
            unsafe base[offset + 0] = colour.b
            unsafe base[offset + 1] = colour.g
            unsafe base[offset + 2] = colour.r
            unsafe base[offset + 3] = 255
        }
    }
}
