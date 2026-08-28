import AVFoundation
import CoreMedia
import Foundation
import Framing
import Geometry
import Testing
import Timeline
@testable import Compositing

/// **The compositor zooms from motion clicks, and this is the seam that was missing entirely.**
///
/// The timeline drew zoom blocks the editor had computed from the picture while `StageCompositor`
/// built its camera from `observationLogURL` alone — which a phone recording does not have. Zooms
/// on the lane, none in the video, and nothing wrong at either end: each half was correct about
/// its own inputs and they were different inputs.
///
/// No amount of testing `MotionActivity` or the timeline model could have caught that. This is
/// the only check that the two ends are joined.
extension StageCompositorTests {
    /// A click at `seconds` into a recording, framing a small region at `(x, y)`.
    private func motionClick(_ seconds: Double, x: Double, y: Double,
                             epoch: BootEpoch) -> FramedClick {
        let side = MotionActivity.minimumTargetFraction
        return FramedClick(
            instant: HostInstant(epoch: epoch, hostTime: Nanoseconds(Int64(seconds * 1e9))),
            target: FramingTarget(
                frame: NormalizedFrame(origin: NormalizedPoint(x: x - side / 2, y: y - side / 2),
                                       size: NormalizedSize(width: side, height: side),
                                       revision: GeometryRevision(id: 1)),
                role: nil))
    }

    @Test func theCameraZoomsFromMotionClicksWhenThereIsNoObservationLog() {
        let saved = StageCompositor.settings()
        defer { StageCompositor.apply(saved) }
        let epoch = BootEpoch(id: UUID(uuidString: "2D4E6F80-91A2-4B3C-8D5E-60718293A4B5")!)

        unsafe StageCompositor.observationLogURL = nil
        unsafe StageCompositor.overrides = []
        unsafe StageCompositor.editTimeline = EditTimeline.whole(
            duration: Nanoseconds(Int64(10 * 1e9)))
        unsafe StageCompositor.motionClicks = [motionClick(3, x: 0.3, y: 0.3, epoch: epoch)]
        unsafe StageCompositor.motionAnchor = EpochAnchor(epoch: epoch, hostTime: Nanoseconds(0),
                                                          wallClockUnixNanos: 0)

        let compositor = StageCompositor()
        let plan = stagePlan(pointer: nil)
        // Inside the block, which spans [t − 0.4, t + 1.0] and eases in over its first moments.
        let inside = compositor.cameraPlan(plan, at: CMTime(seconds: 3.5, preferredTimescale: 600))
        #expect(inside.contentZoom > 1.05, """
            the composed frame at 3.5 s is at \(inside.contentZoom)× — the timeline would show a \
            zoom block over a picture that does not move, which is the state this test exists \
            for. `StageCompositor.motionClicks` is probably not reaching `loadedTracks`.
            """)
        // And it frames roughly where the click was, not the middle.
        #expect(inside.contentCentre.x < 0.5)
        #expect(inside.contentCentre.y < 0.5)

        // Well outside it, the picture is whole again.
        let outside = compositor.cameraPlan(plan, at: CMTime(seconds: 8, preferredTimescale: 600))
        #expect(outside.contentZoom < 1.01,
                "the frame at 8 s is still at \(outside.contentZoom)× with no block anywhere near")
    }

    /// **Observations win.** A Mac recording knows what was clicked and on which control; motion
    /// knows only that something changed. Both together would put a second set of zooms on top
    /// of the ones derived from what was actually pressed.
    @Test func motionClicksAreIgnoredWhenTheRecordingHasItsOwnObservations() throws {
        let saved = StageCompositor.settings()
        defer { StageCompositor.apply(saved) }
        unsafe StageCompositor.observationLogURL = try recordedObservationLog()
        unsafe StageCompositor.overrides = []
        unsafe StageCompositor.editTimeline = EditTimeline.whole(
            duration: Nanoseconds(20 * 1_000_000_000))

        let plan = stagePlan(pointer: nil)
        let withoutMotion = StageCompositor()
        let baseline = stride(from: 0.0, through: 19.0, by: 0.5).map {
            withoutMotion.cameraPlan(plan, at: CMTime(seconds: $0, preferredTimescale: 600))
                .contentZoom
        }

        // The same recording, plus motion clicks at instants of another epoch entirely.
        let stranger = BootEpoch(id: UUID(uuidString: "5A6B7C8D-9E0F-4A1B-8C2D-3E4F5A6B7C8D")!)
        unsafe StageCompositor.motionClicks = (1...10).map {
            motionClick(Double($0), x: 0.8, y: 0.8, epoch: stranger)
        }
        unsafe StageCompositor.motionAnchor = EpochAnchor(epoch: stranger,
                                                          hostTime: Nanoseconds(0),
                                                          wallClockUnixNanos: 0)
        let withMotion = StageCompositor()
        let after = stride(from: 0.0, through: 19.0, by: 0.5).map {
            withMotion.cameraPlan(plan, at: CMTime(seconds: $0, preferredTimescale: 600))
                .contentZoom
        }

        #expect(baseline == after, """
            motion clicks changed a recording that has its own observations. A click knows what \
            was pressed; motion knows something moved. The better answer must win.
            """)
    }

    /// Nothing to derive from and nothing derived: a recording with neither a log nor motion
    /// clicks composes at 1× rather than at some default the camera invented.
    @Test func aRecordingWithNeitherALogNorMotionClicksDoesNotZoom() {
        let saved = StageCompositor.settings()
        defer { StageCompositor.apply(saved) }
        unsafe StageCompositor.observationLogURL = nil
        unsafe StageCompositor.motionClicks = []
        unsafe StageCompositor.motionAnchor = nil
        unsafe StageCompositor.editTimeline = EditTimeline.whole(
            duration: Nanoseconds(Int64(5 * 1e9)))

        let compositor = StageCompositor()
        let plan = stagePlan(pointer: nil)
        for seconds in stride(from: 0.0, through: 4.5, by: 0.5) {
            let composed = compositor.cameraPlan(plan, at: CMTime(seconds: seconds,
                                                                  preferredTimescale: 600))
            #expect(composed.contentZoom == plan.contentZoom,
                    "a recording with nothing to derive from zoomed to \(composed.contentZoom)×")
        }
    }
}
