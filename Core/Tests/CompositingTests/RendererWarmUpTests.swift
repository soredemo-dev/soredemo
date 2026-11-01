import Testing
import Foundation
import CoreVideo
import Render
@testable import Compositing

// `CIContext` compiles its Metal kernels on first use, so without a warm-up the editor paid for
// the whole pipeline on the frame somebody pressed play for — and a frame that arrives while
// shaders are compiling misses AVFoundation's deadline and is dropped as `-12784`.

@Test func warmingAtARealSizeActuallyRenders() throws {
    let renderer = try CoreImageFrameRenderer()
    // The preview's own cap, which is the size the editor actually warms at. Typed explicitly
    // so the outcome is read as the named value it is rather than as a bare `==`.
    let outcome: CoreImageFrameRenderer.WarmUpOutcome =
        renderer.warmUp(outputWidth: 1920, outputHeight: 1080, style: .default)
    #expect(outcome == .warmed)
}

/// **Each refusal is distinguishable from the others**, which is the whole reason this is an
/// enum and not a `Bool`: "it decided not to" and "it tried and the render threw" send somebody
/// to different places.
@Test func everyWarmUpOutcomeIsDistinctFromTheOthers() {
    let all: [CoreImageFrameRenderer.WarmUpOutcome] =
        [.warmed, .sizeUnusable, .noBuffers, .renderFailed("no device")]
    for (i, one) in all.enumerated() {
        for (j, other) in all.enumerated() where i != j {
            #expect(one != other, "\(one) and \(other) are the same value")
        }
    }
    // And a failure carries what was said, rather than collapsing every cause into one case.
    #expect(CoreImageFrameRenderer.WarmUpOutcome.renderFailed("a") != .renderFailed("b"))
}

/// Warming twice is what reopening a project does, and the second one must not be a failure —
/// the context is already built and the render is simply fast.
@Test func warmingTwiceIsStillAWarm() throws {
    let renderer = try CoreImageFrameRenderer()
    #expect(renderer.warmUp(outputWidth: 640, outputHeight: 360, style: .default) == .warmed)
    #expect(renderer.warmUp(outputWidth: 640, outputHeight: 360, style: .default) == .warmed)
}

/// **A named refusal, never a silent return.** Somebody asking why their first frame is still
/// slow needs to be able to tell "it warmed" from "it decided not to".
@Test func aSizeThatIsNotAFrameIsRefusedByName() throws {
    let renderer = try CoreImageFrameRenderer()
    for size in [(0, 1080), (1920, 0), (1, 1), (-4, 720)] {
        #expect(renderer.warmUp(outputWidth: size.0, outputHeight: size.1, style: .default)
                == .sizeUnusable, "\(size) should be refused as unusable, not warmed")
    }
}

/// The warm-up must exercise the SAME path a real frame takes, or it compiles kernels the real
/// frames do not use. Pinned by rendering a real plan through the public renderer afterwards and
/// expecting it to succeed — a warm-up that had left the context broken would show here.
@Test func aRealFrameStillRendersAfterAWarmUp() throws {
    let renderer = try CoreImageFrameRenderer()
    renderer.warmUp(outputWidth: 640, outputHeight: 360, style: .default)
    let plan = StagePlanner.plan(outputWidth: 640, outputHeight: 360,
                                 sourceWidth: 640, sourceHeight: 360, style: .default)
    var source: CVPixelBuffer?
    var destination: CVPixelBuffer?
    _ = unsafe CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, nil, &source)
    _ = unsafe CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, nil, &destination)
    let from = try #require(source)
    let into = try #require(destination)
    #expect(throws: Never.self) { try renderer.render(plan, source: from, camera: nil, into: into) }
}
