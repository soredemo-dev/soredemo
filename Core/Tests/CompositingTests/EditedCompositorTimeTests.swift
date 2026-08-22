import AVFoundation
import Foundation
import Testing
import Render
import Timeline
@testable import Compositing

/// **The seam a cut breaks, tested before a cut can reach a user.**
///
/// `startRequest` is handed OUTPUT times. Every observation record is stamped in SOURCE time.
/// With no edits the two are equal — which is exactly why nothing catches a confusion between
/// them until the first cut, and why every case below edits.
extension StageCompositorTests {
    private static func ns(_ value: Int64) -> Nanoseconds { Nanoseconds(value) }

    @Test func withNoEditOutputTimeIsSourceTime() {
        unsafe StageCompositor.editTimeline = nil
        defer { unsafe StageCompositor.editTimeline = nil }
        #expect(StageCompositor.sourceOffset(forOutput: Nanoseconds(4_000)) == Nanoseconds(4_000))
    }

    /// After a cut, a frame's output time and the recording position it came from differ by
    /// everything removed before it. A compositor that skipped this conversion would draw the
    /// cursor and aim the camera at whatever the recording was doing three seconds earlier.
    @Test func afterACutTheCompositorLooksUpTheSourcePosition() {
        unsafe StageCompositor.editTimeline = EditTimeline
            .whole(duration: Nanoseconds(10_000))
            .removing(sourceRange: 2_000..<5_000)
        defer { unsafe StageCompositor.editTimeline = nil }

        // Before the cut the two still agree…
        #expect(StageCompositor.sourceOffset(forOutput: Nanoseconds(1_000)) == Nanoseconds(1_000))
        // …and after it they are exactly the removed span apart.
        #expect(StageCompositor.sourceOffset(forOutput: Nanoseconds(2_000)) == Nanoseconds(5_000))
        #expect(StageCompositor.sourceOffset(forOutput: Nanoseconds(6_999)) == Nanoseconds(9_999))
    }

    /// Past the end of the edited video there is no source position. `nil` and not the last
    /// frame: the caller draws no pointer and applies no camera, rather than repeating the
    /// final answer for every frame past the end.
    @Test func pastTheEndOfTheEditThereIsNoSourcePosition() {
        unsafe StageCompositor.editTimeline = EditTimeline
            .whole(duration: Nanoseconds(10_000))
            .removing(sourceRange: 2_000..<5_000)
        defer { unsafe StageCompositor.editTimeline = nil }
        #expect(StageCompositor.sourceOffset(forOutput: Nanoseconds(7_000)) == nil)
    }

    /// **The pointer and the camera must use the SAME conversion.** A camera aimed in source
    /// time while the pointer was placed in output time would draw the cursor outside the
    /// region the camera framed — on every frame after the first cut. Driven through the two
    /// public seams rather than through the private helper, so the test fails if either call
    /// site stops using it.
    @Test func thePointerAndTheCameraAgreeAfterACut() throws {
        unsafe StageCompositor.renderer = try CoreImageFrameRenderer()
        unsafe StageCompositor.style = .default
        unsafe StageCompositor.observationLogURL = nil
        unsafe StageCompositor.overrides = []
        unsafe StageCompositor.editTimeline = EditTimeline
            .whole(duration: Nanoseconds(10_000_000_000))
            .removing(sourceRange: 2_000_000_000..<5_000_000_000)
        defer { unsafe StageCompositor.editTimeline = nil }

        let compositor = StageCompositor()
        let plan = StagePlanner.plan(outputWidth: 320, outputHeight: 180,
                                     sourceWidth: 320, sourceHeight: 180, style: .default)
        // Past the end of the edited video: 8s of output from a 7s edit.
        let past = CMTime(value: 8, timescale: 1)
        #expect(compositor.pointerPlacement(at: past, in: plan) == nil,
                "a frame past the edit's end has no pointer")
        #expect(compositor.cameraPlan(plan, at: past) == plan,
                "a frame past the edit's end applies no camera")
    }
}
