import Testing
import Foundation
import CoreVideo
import Compositing
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
