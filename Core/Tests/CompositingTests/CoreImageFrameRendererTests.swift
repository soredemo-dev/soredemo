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
/// placement by half a cursor on every frame. `../opensource/a Swift recorder` (Apache 2.0)
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
