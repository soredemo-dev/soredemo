import CoreMedia
import Foundation
import Geometry
import Render
import Testing
@testable import Compositing

/// Extends `StageCompositorTests` for its `.serialized`: these write the process-global crop.
extension StageCompositorTests {
    /// **One road for the rendered frame and a guide's box.** `framePlan` is what `startRequest`
    /// renders through; with no log there is no camera, so it is the card fitted to the CROPPED
    /// size. **The crop changes the aspect** — half the width, four fifths of the height — because
    /// a crop that kept 16:9 would fit the same card as no crop at all and decide nothing.
    /// `docs/design/2026-10-25-where-the-element-is-in-the-picture.md`.
    @Test func theFramePlanIsTheCardFittedToTheCroppedRecording() {
        let previousLog = unsafe StageCompositor.observationLogURL
        let previousCrop = unsafe StageCompositor.crop
        defer {
            unsafe StageCompositor.observationLogURL = previousLog
            unsafe StageCompositor.crop = previousCrop
        }
        unsafe StageCompositor.observationLogURL = nil
        unsafe StageCompositor.crop = CropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.8)

        let plan = StageCompositor().framePlan(at: CMTime(value: 1, timescale: 1),
                                               outputWidth: 1280, outputHeight: 720,
                                               sourceWidth: 1920, sourceHeight: 1080)
        let cropped = StagePlanner.plan(outputWidth: 1280, outputHeight: 720,
                                        sourceWidth: 960, sourceHeight: 864,
                                        style: unsafe StageCompositor.style)
        let uncropped = StagePlanner.plan(outputWidth: 1280, outputHeight: 720,
                                          sourceWidth: 1920, sourceHeight: 1080,
                                          style: unsafe StageCompositor.style)
        #expect(cropped.card != uncropped.card, "the fixture's crop must change the card, or this decides nothing")
        #expect(plan.card == cropped.card, "fitted to the cropped 960 × 864")
        #expect(plan.contentZoom == 1, "no log, no camera")
    }
}
