import Testing
import Foundation
import CoreImage
import CoreVideo
import Metal
import Framing
import Geometry
import Project
import Render
@testable import Compositing

// The smear: derived by the compositor from the camera's velocities, drawn by the renderer.

private let card = StageRect(x: 100, y: 60, width: 1720, height: 960)

// MARK: - deriving the smear

/// A still camera smears nothing, so a still frame costs no filter.
@Test func aStillCameraProducesNoBlur() {
    #expect(StageCompositor.motionBlur(for: .rest, card: card, outputHeight: 1080,
                                       frameSeconds: 1.0 / 60) == nil)
}

/// A pan at speed smears along its direction by the 180° shutter's share of the frame's
/// travel: `v × zoom × card × frame / 2`, halved again for the radius.
@Test func aPanSmearsAlongItsDirectionByHalfTheExposure() throws {
    let state = CameraState(centre: NormalizedPoint(x: 0.5, y: 0.5), zoom: 2.0,
                            velocityX: 0.5, velocityY: 0, zoomVelocity: 0)
    let blur = try #require(StageCompositor.motionBlur(for: state, card: card, outputHeight: 1080,
                                                       frameSeconds: 1.0 / 60))
    // 0.5 × 2 × 1720 px/s × (1/60 × 0.5) s = 14.33 px of travel → radius 7.17.
    let travel = 0.5 * 2.0 * 1720 * (1.0 / 60) * StageCompositor.shutterFraction
    #expect(abs(blur.panRadius - travel / 2) < 0.01)
    #expect(abs(blur.panAngle) < 1e-9, "a +x pan should blur along +x")
    #expect(blur.zoomAmount == 0)
}

/// A slow drift under the threshold is not worth a filter — the cost of a blur that shows
/// nothing is a softer frame.
@Test func aSmearUnderThePixelThresholdIsSkipped() {
    let state = CameraState(centre: NormalizedPoint(x: 0.5, y: 0.5), zoom: 1.5,
                            velocityX: 0.02, velocityY: 0.01, zoomVelocity: 0)
    #expect(StageCompositor.motionBlur(for: state, card: card, outputHeight: 1080,
                                       frameSeconds: 1.0 / 60) == nil)
}

/// A whip pan is capped, so the picture stays legible for the frames it lasts.
@Test func aWhipPanIsCappedToTheMaximumFraction() throws {
    let state = CameraState(centre: NormalizedPoint(x: 0.5, y: 0.5), zoom: 3.0,
                            velocityX: 40, velocityY: 0, zoomVelocity: 0)
    let blur = try #require(StageCompositor.motionBlur(for: state, card: card, outputHeight: 1080,
                                                       frameSeconds: 1.0 / 60))
    #expect(blur.panRadius <= 1080 * StageCompositor.maximumBlurFraction / 2 + 1e-9)
}

/// A zoom smears radially about the card's centre, scaled by the edge's travel.
@Test func aZoomSmearsRadiallyAboutTheCardCentre() throws {
    let state = CameraState(centre: NormalizedPoint(x: 0.5, y: 0.5), zoom: 1.5,
                            velocityX: 0, velocityY: 0, zoomVelocity: 3.0)
    let blur = try #require(StageCompositor.motionBlur(for: state, card: card, outputHeight: 1080,
                                                       frameSeconds: 1.0 / 30))
    #expect(blur.zoomAmount > 0)
    #expect(blur.panRadius == 0)
    #expect(blur.centreX == card.x + card.width / 2 && blur.centreY == card.y + card.height / 2)
}

/// The exposure comes from the frame duration: at 30 fps the same motion smears twice as
/// far as at 60. A blur that ignored the frame rate would draw a 30 fps export half as
/// smeared as the motion it stands for.
@Test func theSmearScalesWithTheFrameDuration() throws {
    let state = CameraState(centre: NormalizedPoint(x: 0.5, y: 0.5), zoom: 1.5,
                            velocityX: 0.3, velocityY: 0.2, zoomVelocity: 0)
    let at60 = try #require(StageCompositor.motionBlur(for: state, card: card, outputHeight: 1080,
                                                       frameSeconds: 1.0 / 60))
    let at30 = try #require(StageCompositor.motionBlur(for: state, card: card, outputHeight: 1080,
                                                       frameSeconds: 1.0 / 30))
    #expect(abs(at30.panRadius - at60.panRadius * 2) < 1e-6)
}

// MARK: - drawing the smear and the resample

/// A CIContext over Metal, or a recorded failure — the same terms as the renderer tests.
private func renderContext() throws -> CIContext {
    let device = try #require(MTLCreateSystemDefaultDevice(), "no Metal device — a real answer, not a skip")
    return CIContext(mtlDevice: device, options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    ])
}

/// The rendered luminance of `image` over `width × height` at the origin, row-major from the top.
private func luminance(of image: CIImage, width: Int, height: Int) throws -> [Double] {
    let destination = try makePixelBuffer(width: width, height: height, fill: (0, 0, 0))
    try renderContext().render(image, to: destination,
                               bounds: HeadlessGeometryBridge.outputCanvas(width: width, height: height),
                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    return try pixels(of: destination).map { (Double($0.r) + Double($0.g) + Double($0.b)) / 3 }
}

/// **A horizontal smear spreads a vertical edge and leaves a horizontal one alone.** The
/// source is white on the left half and black on the right, so a horizontal blur makes a
/// ramp across the middle; the same blur on a top/bottom split changes nothing, because
/// every pixel it averages along +x is the same as its neighbour.
@Test func thePanSmearIsDirectional() throws {
    let size = 64
    let leftRight = try makePixelBuffer(width: size, height: size, fill: (255, 255, 255))
    // Paint the right half black by cropping a white image and compositing over black.
    let white = CIImage(cvPixelBuffer: leftRight)
    let vertical = white.cropped(to: HeadlessGeometryBridge.rect(x: 0, y: 0, width: 32, height: 64))
        .composited(over: CIImage(color: CIColor.black)
            .cropped(to: HeadlessGeometryBridge.outputCanvas(width: size, height: size)))
    let horizontal = white.cropped(to: HeadlessGeometryBridge.rect(x: 0, y: 0, width: 64, height: 32))
        .composited(over: CIImage(color: CIColor.black)
            .cropped(to: HeadlessGeometryBridge.outputCanvas(width: size, height: size)))
    let blur = MotionBlur(panRadius: 6, panAngle: 0, zoomAmount: 0, centreX: 32, centreY: 32)

    let smearedVertical = try luminance(of: CoreImageFrameRenderer.smeared(vertical, by: blur),
                                        width: size, height: size)
    let sharpVertical = try luminance(of: vertical, width: size, height: size)
    // Row 32, columns 28…36: sharp has one step, smeared has a ramp with several intermediate values.
    let row = 32 * size
    let intermediate = (26..<38).filter { smearedVertical[row + $0] > 20 && smearedVertical[row + $0] < 235 }
    let sharpIntermediate = (26..<38).filter { sharpVertical[row + $0] > 20 && sharpVertical[row + $0] < 235 }
    #expect(intermediate.count >= 4, "a 6 px horizontal smear left \(intermediate.count) ramp pixels")
    #expect(sharpIntermediate.count <= 1, "the unsmeared edge was not sharp to begin with")

    let smearedHorizontal = try luminance(of: CoreImageFrameRenderer.smeared(horizontal, by: blur),
                                          width: size, height: size)
    let sharpHorizontal = try luminance(of: horizontal, width: size, height: size)
    let changed = zip(smearedHorizontal, sharpHorizontal).filter { abs($0 - $1) > 4 }.count
    #expect(changed == 0, "a horizontal smear changed \(changed) pixels of a horizontal edge")
}

/// **Lanczos does not alias where the affine sampler does.** A 1 px stripe pattern — the
/// finest a screen holds, and what a hairline rule or a pixel font's stems are — scaled by
/// 0.45 is far past the sampler's Nyquist: bilinear reads two source pixels per output pixel
/// and skips the rest, so the output beats between light and dark across the frame (moiré).
/// Lanczos integrates every source pixel under its kernel and gives a near-uniform grey.
/// The discriminator is the spread of output luminance: the aliased result spreads across
/// most of the range, the filtered one across a sliver of it.
@Test func theResampleDoesNotAliasAStripePattern() throws {
    let size = 200
    let buffer = try makePixelBuffer(width: size, height: size, fill: (0, 0, 0))
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = try unsafe #require(unsafe CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    for row in 0..<size {
        for column in 0..<size where column % 2 == 0 {
            let offset = row * stride + column * 4
            unsafe base[offset] = 255; unsafe base[offset + 1] = 255; unsafe base[offset + 2] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    let source = CIImage(cvPixelBuffer: buffer)
    let scale = 0.45
    let out = Int(Double(size) * scale)

    let lanczos = try luminance(of: CoreImageFrameRenderer.resampled(source, scaleX: scale, scaleY: scale),
                                width: out, height: out)
    let bilinear = try luminance(of: source.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
                                 width: out, height: out)
    func spread(_ values: [Double]) -> Double {
        // The middle row, away from the edge where the clamp and the crop differ.
        let row = Array(values[(out / 2) * out ..< (out / 2 + 1) * out])
        return (row.max() ?? 0) - (row.min() ?? 0)
    }
    let aliased = spread(bilinear), filtered = spread(lanczos)
    #expect(aliased > 60, "the bilinear control did not alias (spread \(aliased)); the fixture proves nothing")
    #expect(filtered < aliased / 3, """
        Lanczos spread \(filtered) against bilinear's \(aliased) — the resample is still aliasing
        """)
}

/// A scale of exactly 1 is the identity and returns the image untouched — no clamp, no
/// crop, no kernel — so a 1:1 export pays nothing for the filter it does not need.
@Test func aUnitScaleIsTheIdentity() throws {
    let source = CIImage(cvPixelBuffer: try makePixelBuffer(width: 8, height: 8, fill: sourceFill))
    let same = CoreImageFrameRenderer.resampled(source, scaleX: 1, scaleY: 1)
    #expect(same === source)
}

// MARK: - the cursor's opacity and lean reach the pixels

/// A placement at opacity 0 draws nothing — the frame equals the pointerless one — and a
/// leaned placement draws a different silhouette from an upright one. Both through the
/// production renderer.
@Test func opacityAndTiltChangeWhatIsDrawn() throws {
    let width = 320, height = 180
    let plan = StagePlanner.plan(outputWidth: width, outputHeight: height,
                                 sourceWidth: width, sourceHeight: height, style: .default)
    let renderer = try CoreImageFrameRenderer()
    func frame(_ pointer: NormalizedPointerPlacement?) throws -> [(r: UInt8, g: UInt8, b: UInt8)] {
        let source = try makePixelBuffer(width: width, height: height, fill: sourceFill)
        let destination = try makePixelBuffer(width: width, height: height, fill: (0, 0, 0))
        let planned = RenderPlan(outputWidth: width, outputHeight: height, card: plan.card,
                                 cornerRadius: plan.cornerRadius, style: plan.style, pointer: pointer)
        try renderer.render(planned, source: source, camera: nil, into: destination)
        return try pixels(of: destination)
    }
    let none = try frame(nil)
    let upright = try frame(NormalizedPointerPlacement(x: 160, y: 90, ripplePhase: nil))
    let hidden = try frame(NormalizedPointerPlacement(x: 160, y: 90, ripplePhase: nil, opacity: 0))
    let leaned = try frame(NormalizedPointerPlacement(x: 160, y: 90, ripplePhase: nil, tiltDegrees: 10))
    let half = try frame(NormalizedPointerPlacement(x: 160, y: 90, ripplePhase: nil, opacity: 0.5))

    #expect(zip(upright, none).contains { $0 != $1 }, "the upright cursor drew nothing")
    #expect(!zip(hidden, none).contains { $0 != $1 }, "a cursor at opacity 0 still drew")
    #expect(zip(leaned, upright).contains { $0 != $1 }, "a 10° lean drew the same pixels as upright")
    // Half opacity: over the blue source the white fill lands between the two.
    let brightest = { (f: [(r: UInt8, g: UInt8, b: UInt8)]) in f.map { Int($0.r) }.max() ?? 0 }
    #expect(brightest(half) < brightest(upright) && brightest(half) > brightest(none),
            "half opacity did not land between hidden and drawn")
}

// MARK: - the keystroke badge reaches the pixels

/// A plan carrying a badge draws pixels a badge-less plan does not, near the bottom of the
/// frame where the style puts it, and a badge at opacity 0 draws nothing.
@Test func aKeystrokeBadgeIsDrawnWhereTheStylePutsIt() throws {
    let width = 640, height = 360
    let base = StagePlanner.plan(outputWidth: width, outputHeight: height,
                                 sourceWidth: width, sourceHeight: height, style: .default)
    let renderer = try CoreImageFrameRenderer()
    func frame(_ badge: KeystrokeBadge?) throws -> [(r: UInt8, g: UInt8, b: UInt8)] {
        let source = try makePixelBuffer(width: width, height: height, fill: sourceFill)
        let destination = try makePixelBuffer(width: width, height: height, fill: (0, 0, 0))
        let plan = RenderPlan(outputWidth: width, outputHeight: height, card: base.card,
                              cornerRadius: base.cornerRadius, style: base.style, pointer: nil,
                              keystroke: badge)
        try renderer.render(plan, source: source, camera: nil, into: destination)
        return try pixels(of: destination)
    }
    let without = try frame(nil)
    let with = try frame(KeystrokeBadge(text: "⌘⇧Z", opacity: 1))
    let faded = try frame(KeystrokeBadge(text: "⌘⇧Z", opacity: 0))

    let changed = zip(with, without).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
    #expect(!changed.isEmpty, "the badge drew nothing")
    // Rows are top-down in the buffer; the badge sits `bottomFraction` up from the bottom.
    let rows = changed.map { $0 / width }
    let expectedRow = height - Int(Double(height) * KeystrokeBadgeStyle.bottomFraction)
    let centreRow = (rows.min()! + rows.max()!) / 2
    #expect(abs(centreRow - expectedRow) < Int(Double(height) * KeystrokeBadgeStyle.heightFraction) * 2, """
        the badge's rows centre on \(centreRow); the style puts its baseline near \(expectedRow)
        """)
    #expect(!zip(faded, without).contains { $0 != $1 }, "a badge at opacity 0 still drew")
}

// MARK: - every recorded shape draws its own silhouette (design audit item 5)

/// **The pixels, pairwise.** Until 2026-08-25 `.pointingHand`, `.crosshair` and both resize
/// shapes were drawn as the arrow: the shape was recorded, carried through the reading, the
/// placement and the plan, and then thrown away at the last switch. Composing each shape and
/// comparing every pair is what would have caught that, and it is what would catch a fifth
/// shape added to the enum and forgotten in the renderer.
@Test func everyPointerShapeDrawsItsOwnSilhouette() throws {
    let width = 240, height = 160
    let plan = StagePlanner.plan(outputWidth: width, outputHeight: height,
                                 sourceWidth: width, sourceHeight: height, style: .default)
    let renderer = try CoreImageFrameRenderer()
    func frame(_ shape: PointerShape?) throws -> [(r: UInt8, g: UInt8, b: UInt8)] {
        let source = try makePixelBuffer(width: width, height: height, fill: sourceFill)
        let destination = try makePixelBuffer(width: width, height: height, fill: (0, 0, 0))
        let pointer = NormalizedPointerPlacement(x: Double(width) / 2, y: Double(height) / 2,
                                                 ripplePhase: nil, shape: shape)
        let planned = RenderPlan(outputWidth: width, outputHeight: height, card: plan.card,
                                 cornerRadius: plan.cornerRadius, style: plan.style, pointer: pointer)
        try renderer.render(planned, source: source, camera: nil, into: destination)
        return try pixels(of: destination)
    }
    let shapes: [PointerShape] = [.arrow, .iBeam, .pointingHand, .crosshair,
                                  .resizeLeftRight, .resizeUpDown]
    let drawn = try shapes.map { try ($0, frame($0)) }
    let blank = try frame(nil as PointerShape?)   // `nil` is unrecorded and draws the arrow

    for (shape, frame) in drawn {
        #expect(zip(frame, blank).contains { $0 != $1 } || shape == .arrow,
                "\(shape) drew nothing distinguishable from the arrow-for-unrecorded frame")
    }
    for (indexA, (shapeA, frameA)) in drawn.enumerated() {
        for (shapeB, frameB) in drawn.dropFirst(indexA + 1) {
            #expect(frameA.elementsEqual(frameB, by: ==) == false,
                    "\(shapeA) and \(shapeB) composed identical frames — one falls back to the other")
        }
    }
    // And `.other`/unrecorded really are the arrow, which is the documented fallback rather
    // than an oversight: a change that gave them art of their own reddens here.
    let other = try frame(PointerShape.other)
    let arrow = try #require(drawn.first { $0.0 == .arrow }?.1)
    #expect(other.elementsEqual(arrow, by: ==), ".other stopped drawing the arrow")
    #expect(blank.elementsEqual(arrow, by: ==), "an unrecorded shape stopped drawing the arrow")
}

// MARK: - the cursor smears under the same shutter as the card (design audit item 6)

/// The plan every cursor-smear case is measured against: a 1920×1080 stage over a 16:9
/// source, so the card is 1690 × 950 after the pixel snap.
private func smearPlan(contentZoom: Double = 1, cardBlur: MotionBlur? = nil) -> RenderPlan {
    let base = StagePlanner.plan(outputWidth: 1920, outputHeight: 1080,
                                 sourceWidth: 1920, sourceHeight: 1080, style: .default)
    return RenderPlan(outputWidth: 1920, outputHeight: 1080, card: base.card,
                      cornerRadius: base.cornerRadius, style: base.style, pointer: nil,
                      contentZoom: contentZoom, motionBlur: cardBlur)
}

/// A still cursor over a still camera smears nothing, so a still frame costs no filter.
@Test func aStillCursorSmearsNothing() {
    #expect(StageCompositor.cursorSmear(velocity: (x: 0, y: 0), plan: smearPlan(),
                                        frameSeconds: 1.0 / 60) == nil)
}

/// A cursor crossing the card at one width per second smears along +x by half its travel
/// during the exposure: `1 × 1690 px/s × (1/60 × 0.5) s = 14.08 px`, radius 7.04.
@Test func aMovingCursorSmearsAlongItsDirectionByHalfItsTravel() throws {
    let plan = smearPlan()
    let smear = try #require(StageCompositor.cursorSmear(velocity: (x: 1, y: 0), plan: plan,
                                                          frameSeconds: 1.0 / 60))
    let travel = 1.0 * plan.card.width * (1.0 / 60) * StageCompositor.shutterFraction
    #expect(abs(smear.radius - travel / 2) < 0.01, "smeared \(smear.radius) for a travel of \(travel)")
    #expect(abs(smear.angle) < 1e-9, "a +x move should smear along +x")
}

/// **Zoom is part of the travel.** The same source-space velocity crosses twice as many
/// output pixels at zoom 2, so it smears twice as far — a smear computed from normalised
/// units alone would draw a zoomed-in flick as gently as a zoomed-out one.
///
/// **Half a card-width per second, not a whole one**, and the first draft's choice of a whole
/// one is why: at zoom 2 that travels 28 px in an exposure, past the 21.6 px cap, so the
/// doubling this test is about was measured against a capped value and came out 3.28 short.
/// A fixture that lands on a clamp cannot measure what happens before it.
@Test func theCursorSmearScalesWithTheContentZoom() throws {
    let atOne = try #require(StageCompositor.cursorSmear(velocity: (x: 0.5, y: 0),
                                                          plan: smearPlan(contentZoom: 1),
                                                          frameSeconds: 1.0 / 60))
    let atTwo = try #require(StageCompositor.cursorSmear(velocity: (x: 0.5, y: 0),
                                                          plan: smearPlan(contentZoom: 2),
                                                          frameSeconds: 1.0 / 60))
    let cap = 1080 * StageCompositor.maximumBlurFraction / 2
    try #require(atTwo.radius < cap, "the deeper case is capped; this fixture measures the clamp")
    #expect(abs(atTwo.radius - atOne.radius * 2) < 0.01)
}

/// **A cursor held still while the camera pans is still travelling across the frame**, and
/// smears for it. Without the card's contribution a pan would blur the picture and leave a
/// razor-sharp cursor sitting on top of it, which is the tell of a compositing mistake.
@Test func aStillCursorOverAPanningCameraStillSmears() throws {
    let pan = MotionBlur(panRadius: 10, panAngle: 0, zoomAmount: 0, centreX: 960, centreY: 540)
    let smear = try #require(StageCompositor.cursorSmear(velocity: (x: 0, y: 0),
                                                          plan: smearPlan(cardBlur: pan),
                                                          frameSeconds: 1.0 / 60))
    // The card's whole travel is twice its radius; the cursor's own is zero.
    #expect(abs(smear.radius - pan.panRadius) < 0.01,
            "a \(pan.panRadius * 2) px card pan smeared the cursor by \(smear.radius * 2)")
}

/// A drift under the threshold is not worth a filter, and a flick is capped, exactly as the
/// card's blur is — the two share `motionBlurThreshold` and `maximumBlurFraction` because a
/// second set of numbers for the same exposure would be a second answer to one question.
@Test func theCursorSmearSharesTheCardsThresholdAndCap() throws {
    #expect(StageCompositor.cursorSmear(velocity: (x: 0.01, y: 0), plan: smearPlan(),
                                        frameSeconds: 1.0 / 60) == nil)
    let flick = try #require(StageCompositor.cursorSmear(velocity: (x: 40, y: 0), plan: smearPlan(),
                                                          frameSeconds: 1.0 / 60))
    #expect(flick.radius <= 1080 * StageCompositor.maximumBlurFraction / 2 + 1e-9)
}

/// **The smear reaches the pixels, and it reaches along its own axis.** A cursor smeared
/// horizontally spreads further in x than the same cursor unsmeared, and no further in y —
/// which a radial blur, or a smear applied on the wrong axis, would fail.
@Test func theCursorSmearIsDrawnAndIsDirectional() throws {
    let width = 320, height = 200
    let base = StagePlanner.plan(outputWidth: width, outputHeight: height,
                                 sourceWidth: width, sourceHeight: height, style: .default)
    let renderer = try CoreImageFrameRenderer()
    func drawnColumnsAndRows(smearRadius: Double, angle: Double) throws -> (x: Int, y: Int) {
        let source = try makePixelBuffer(width: width, height: height, fill: sourceFill)
        let destination = try makePixelBuffer(width: width, height: height, fill: (0, 0, 0))
        let reference = try makePixelBuffer(width: width, height: height, fill: (0, 0, 0))
        let pointer = NormalizedPointerPlacement(x: Double(width) / 2, y: Double(height) / 2,
                                                 ripplePhase: nil, smearRadius: smearRadius,
                                                 smearAngle: angle)
        func render(_ placement: NormalizedPointerPlacement?, into buffer: CVPixelBuffer) throws {
            let plan = RenderPlan(outputWidth: width, outputHeight: height, card: base.card,
                                  cornerRadius: base.cornerRadius, style: base.style,
                                  pointer: placement)
            try renderer.render(plan, source: source, camera: nil, into: buffer)
        }
        try render(pointer, into: destination)
        try render(nil, into: reference)
        let changed = zip(try pixels(of: destination), try pixels(of: reference))
            .enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        let columns = Set(changed.map { $0 % width }), rows = Set(changed.map { $0 / width })
        return (x: columns.count, y: rows.count)
    }
    let sharp = try drawnColumnsAndRows(smearRadius: 0, angle: 0)
    let smeared = try drawnColumnsAndRows(smearRadius: 12, angle: 0)
    #expect(sharp.x > 0 && sharp.y > 0, "the unsmeared cursor drew nothing; the comparison is vacuous")
    #expect(smeared.x > sharp.x + 8, """
        a 12 px horizontal smear widened the cursor from \(sharp.x) to \(smeared.x) columns
        """)
    #expect(smeared.y <= sharp.y + 2, """
        a horizontal smear grew the cursor's height from \(sharp.y) to \(smeared.y) rows — \
        it is not directional
        """)
}
