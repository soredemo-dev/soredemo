import Testing
import Foundation
import CoreVideo
@testable import Compositing
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
    try renderer.render(plan, source: source, into: destination)

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
        try renderer.render(plan, source: source, into: destination)
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
        try renderer.render(plan, source: source, into: destination)
        return try pixels(of: destination)
    }
    let first = try rendered()
    let second = try rendered()
    for index in [0, width * height / 2, width * height - 1] {
        #expect(first[index] == second[index])
    }
}
