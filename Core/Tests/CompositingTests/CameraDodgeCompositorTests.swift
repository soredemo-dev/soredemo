import CoreMedia
import Foundation
import Render
import Testing
import Timeline
@testable import Compositing

/// **The dodge, measured through the compositor against the real recording.** `CameraDodge`'s
/// own tests pin the rules on synthetic paths; this pins the wiring — that the compositor
/// samples the cursor through the same zoomed plan a frame uses, bakes once, and swaps the
/// camera's placement only while the style asks it to.
///
/// **The camera is put where the fixture's cursor actually goes.** Nothing in this test assumes
/// where that is: it asks the compositor for the cursor's place across the take, picks the
/// frame nearest to some corner, and parks the camera there. A test that hard-coded
/// bottom-right would pass or fail on what the person who made the fixture happened to do with
/// their mouse.
extension StageCompositorTests {
    private static let second: Int64 = 1_000_000_000

    private struct Visit {
        let seconds: Double
        /// The cursor's place, in output pixels.
        let x: Double
        let y: Double
    }

    /// **The instant the fixture's cursor is most central**, and where it is.
    ///
    /// The camera will be parked exactly there. A first draft parked a default camera at the
    /// corner the cursor came nearest to and found the fixture never entered any corner's zone;
    /// a second made the camera as large as the style allows, and a 0.6-wide circle on a
    /// 640×360 frame is taller than the frame, so `rect` centred it and all four corners became
    /// the same box — every corner read as taken and the camera had nowhere to go. Home can be
    /// any coordinate, so the robust version puts it under the cursor: the zone contains the
    /// cursor by construction, and the most central instant keeps `rect`'s edge clamp from
    /// shifting the box off it.
    private func mostCentralVisit(_ compositor: StageCompositor, plan: RenderPlan) -> Visit? {
        var best: (clearance: Double, visit: Visit)?
        for frame in 0...(20 * 30) {
            let seconds = Double(frame) / 30
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            let aimed = compositor.cameraPlan(plan, at: time)
            guard let placement = compositor.pointerPlacement(at: time, in: aimed) else { continue }
            let clearance = min(placement.x, Double(plan.outputWidth) - placement.x,
                                placement.y, Double(plan.outputHeight) - placement.y)
            if best == nil || clearance > best!.clearance {
                best = (clearance, Visit(seconds: seconds, x: placement.x, y: placement.y))
            }
        }
        return best?.visit
    }

    @Test func theCameraLeavesItsPlaceWhileTheCursorIsOnItAndOnlyThen() throws {
        let saved = StageCompositor.settings()
        defer { StageCompositor.apply(saved) }
        unsafe StageCompositor.observationLogURL = try recordedObservationLog()
        unsafe StageCompositor.overrides = []
        unsafe StageCompositor.editTimeline = EditTimeline.whole(duration: Nanoseconds(20 * Self.second))
        let plan = stagePlan(pointer: nil)

        let scout = StageCompositor()
        let visit = try #require(mostCentralVisit(scout, plan: plan),
                                 "the fixture drew no cursor in its first 20 s")
        let homeStyle = CameraOverlayStyle.default.changing(
            x: visit.x / Double(plan.outputWidth), y: visit.y / Double(plan.outputHeight))
        // The guard the earlier drafts needed: is the cursor really inside the zone of the
        // camera parked under it? `rect` clamps the box into the frame's margins, so a cursor
        // very near an edge could sit outside the clamped box. The most central instant is
        // chosen to make this hold; the guard says so rather than assuming it.
        let box = homeStyle.rect(inOutputWidth: plan.outputWidth, outputHeight: plan.outputHeight,
                                 sourceAspect: 1)
        let margin = Double(plan.outputWidth) * CameraDodge.approachFraction
        let insideX = visit.x >= box.x - margin && visit.x <= box.x + box.width + margin
        let insideY = visit.y >= box.y - margin && visit.y <= box.y + box.height + margin
        guard insideX && insideY else {
            Issue.record("""
                the camera parked under the cursor at \(visit.seconds) s does not contain it: \
                cursor (\(visit.x), \(visit.y)), box \(box). The fixture's cursor never comes far \
                enough from the frame's edge for a default camera to sit on it.
                """)
            return
        }
        let at = CMTime(seconds: visit.seconds, preferredTimescale: 600)

        // — off: the camera is where the style says —
        unsafe StageCompositor.cameraStyle = homeStyle
        let off = StageCompositor()
        let stillThere = try #require(off.cameraOverlay(at: at, basePlan: plan,
                                                        sourcePixelWidth: nil, cameraAspect: 1))
        let offIsHome = stillThere.style.x == homeStyle.x && stillThere.style.y == homeStyle.y
        #expect(offIsHome)

        // — on: the camera is somewhere else once it has had time to move —
        //
        // **One transition after the visit, not at it.** A segment begins AT the sample that
        // saw the cursor arrive, and the glide's progress there is 0 — so the camera is, by
        // design, exactly home at that instant and away one `transitionSeconds` later.
        unsafe StageCompositor.cameraStyle = homeStyle.changing(avoidsCursor: true)
        let on = StageCompositor()
        let moved = CMTime(seconds: visit.seconds + CameraDodge.transitionSeconds,
                           preferredTimescale: 600)
        let dodged = try #require(on.cameraOverlay(at: moved, basePlan: plan,
                                                   sourcePixelWidth: nil, cameraAspect: 1))
        let dodgedIsHome = dodged.style.x == homeStyle.x && dodged.style.y == homeStyle.y
        #expect(!dodgedIsHome, """
            with the dodge on, the camera one transition after \(visit.seconds) s is still at \
            (\(homeStyle.x), \(homeStyle.y)), though the cursor was at (\(visit.x), \(visit.y)), \
            inside its zone
            """)
        // And it went to a corner, not somewhere in between.
        let isCorner = (dodged.style.x == 0 || dodged.style.x == 1)
            && (dodged.style.y == 0 || dodged.style.y == 1)
        #expect(isCorner, "settled at (\(dodged.style.x), \(dodged.style.y)), which is not a corner")
    }

    /// The schedule is baked once: asking twice returns the same placements, and a compositor
    /// asked out of order — the scrubbing case — answers the same as one asked in order.
    @Test func theDodgeAnswersTheSameWhateverOrderFramesAreAskedIn() throws {
        let saved = StageCompositor.settings()
        defer { StageCompositor.apply(saved) }
        unsafe StageCompositor.observationLogURL = try recordedObservationLog()
        unsafe StageCompositor.overrides = []
        unsafe StageCompositor.editTimeline = EditTimeline.whole(duration: Nanoseconds(20 * Self.second))
        unsafe StageCompositor.cameraStyle = CameraOverlayStyle.default
            .placed(at: .bottomRight).changing(avoidsCursor: true)
        let plan = stagePlan(pointer: nil)

        let forward = StageCompositor()
        let backward = StageCompositor()
        let instants = stride(from: 0.0, through: 19.5, by: 0.5).map {
            CMTime(seconds: $0, preferredTimescale: 600)
        }
        var inOrder: [(Double, Double)] = []
        for time in instants {
            let overlay = try #require(forward.cameraOverlay(at: time, basePlan: plan,
                                                             sourcePixelWidth: nil, cameraAspect: 1))
            inOrder.append((overlay.style.x, overlay.style.y))
        }
        var reversed: [(Double, Double)] = []
        for time in instants.reversed() {
            let overlay = try #require(backward.cameraOverlay(at: time, basePlan: plan,
                                                              sourcePixelWidth: nil, cameraAspect: 1))
            reversed.append((overlay.style.x, overlay.style.y))
        }
        for (a, b) in zip(inOrder, reversed.reversed()) {
            let same = a.0 == b.0 && a.1 == b.1
            #expect(same, "order of asking changed the camera's place")
        }
    }
}
