import Testing
import Foundation
import CoreVideo
import Headless
import Render

/// **The seam's entry-rule obligation, discharged by the production conformer and
/// not by a double.**
///
/// `FrameRendering` is exempt from construction and not from exercise, and the
/// exercised conforming type may not be a test-only one. A `struct` in this file
/// conforming to `FrameRendering` would satisfy the letter and invert the meaning:
/// the seam would be fully verified through a double while `CoreImageFrameRenderer`
/// — the only thing that ever runs in the app — never executed. That is the exact
/// shape of the defect this whole phase exists to end.
///
/// **`renderer` is typed `any FrameRendering`, not left to infer `CoreImageFrameRenderer`**
/// — the call below goes through the protocol's own dispatch, so this test exercises the
/// SEAM, with the production type behind it, rather than exercising the class directly and
/// leaving the protocol itself untouched by anything but a comment.
///
/// **This test needs a GPU**, which is why `HeadlessTests` is a separate population.
/// On a machine with no Metal device `CoreImageFrameRenderer.init` throws
/// `FrameRenderingError.noRenderDevice`; that is recorded as a real failure below, not
/// silently skipped — `Issue.record` still leaves the test red.
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

    // Not "the call returned" — pixels the renderer actually wrote. The destination
    // started all-black; the stage background is (0.09, 0.09, 0.11) and the card
    // carries the source fill, so a renderer that did nothing leaves this all zero.
    let written = try pixels(of: destination).filter { $0 != (0, 0, 0) }
    #expect(!written.isEmpty, "the destination is still the all-black buffer it started as")
}
