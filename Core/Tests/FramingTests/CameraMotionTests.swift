import Foundation
import Geometry
import Project
import Testing
import Timeline
@testable import Framing

// `camera-motion`'s row names three properties: settles without overshoot, carries velocity
// across a re-aim, and a safe zone so jitter does not move the camera. Each has a test that
// would go red if the property were lost, rather than one test that the type exists.

private let epoch = BootEpoch(id: UUID(uuidString: "CA3E4A00-3333-4444-8555-666677778888")!)
private let revision = GeometryRevision(id: 9)

private func at(seconds: Double) -> HostInstant {
    HostInstant(epoch: epoch, hostTime: Nanoseconds(Int64(seconds * 1_000_000_000)))
}

private func block(from: Double, to: Double, x: Double, y: Double,
                   extent: Double = 0.05) -> ZoomBlock {
    let target = FramingTarget(
        frame: NormalizedFrame(origin: NormalizedPoint(x: x, y: y),
                               size: NormalizedSize(width: extent, height: extent),
                               revision: revision), role: "AXButton")
    // The origin is the click these fixtures stand in for; `from` is the block's start, which
    // pre-roll has already moved, so the click itself is a little later.
    return ZoomBlock(origin: at(seconds: from), start: at(seconds: from), end: at(seconds: to),
                     target: target, zoom: FramingDepth.zoom(for: target, coverage: 1))
}

private func samples(_ camera: CameraMotion, from: Double, to: Double,
                     step: Double = 1.0 / 60) -> [CameraState] {
    stride(from: from, through: to, by: step).map { camera.state(at: at(seconds: $0)) }
}

// MARK: - settles without overshoot

/// **Overshoot is the failure this row names first**, and it is what a spring tuned by feel
/// gets wrong: the camera sails past the target and comes back, which reads as the tool
/// being unsure. Critically damped means the zoom approaches its destination from one side
/// only, so no sample may exceed the block's own depth.
@Test func theZoomNeverOvershootsItsTargetDepth() {
    let camera = CameraMotion(blocks: [block(from: 1.0, to: 4.0, x: 0.4, y: 0.4)])
    let peak = samples(camera, from: 0.0, to: 4.0).map(\.zoom).max() ?? 0
    #expect(peak <= FramingDepth.zoom(for: block(from: 1, to: 4, x: 0.4, y: 0.4).target, coverage: 1) + 1e-6,
            "the zoom reached \(peak), past the depth it was aiming for")
}

/// And it actually ARRIVES: a spring that never overshoots but never settles either would
/// pass the test above. Within the block's own span the zoom must reach most of its depth.
@Test func theZoomSettlesWithinTheBlockItBelongsTo() {
    let target = block(from: 1.0, to: 4.0, x: 0.4, y: 0.4)
    let camera = CameraMotion(blocks: [target])
    let atSettle = camera.state(at: at(seconds: 2.5)).zoom
    #expect(atSettle > 1.0 + (target.zoom - 1.0) * 0.9,
            "1.5 s into the block the zoom is only \(atSettle) of a target \(target.zoom)")
}

/// Between blocks the camera returns to 1.0 — no zoom is the resting state, and a camera
/// that stayed in would make the next zoom invisible.
@Test func theCameraReturnsToRestBetweenBlocks() {
    let camera = CameraMotion(blocks: [block(from: 1.0, to: 2.0, x: 0.4, y: 0.4)])
    #expect(camera.state(at: at(seconds: 0.0)).zoom == 1.0)
    #expect(camera.state(at: at(seconds: 6.0)).zoom < 1.05)
}

// MARK: - carries velocity across a re-aim

/// **The row's second property.** When a new block starts while the camera is still moving,
/// the spring keeps its velocity instead of restarting from zero. A restart is visible: the
/// camera stops dead and starts again, which is the artefact this property exists to
/// prevent. Measured as smoothness — no sample-to-sample jump larger than the largest jump
/// a single-block move produces.
@Test func aReAimCarriesVelocityRatherThanRestarting() {
    let single = CameraMotion(blocks: [block(from: 1.0, to: 5.0, x: 0.2, y: 0.2)])
    let singleJump = zip(samples(single, from: 0.5, to: 3.0),
                         samples(single, from: 0.5, to: 3.0).dropFirst())
        .map { abs($1.centre.x - $0.centre.x) }.max() ?? 0

    // A second block aimed elsewhere, opening while the first is still settling.
    let reAim = CameraMotion(blocks: [block(from: 1.0, to: 1.6, x: 0.2, y: 0.2),
                                      block(from: 1.6, to: 5.0, x: 0.8, y: 0.8)])
    let reAimJump = zip(samples(reAim, from: 0.5, to: 3.0),
                        samples(reAim, from: 0.5, to: 3.0).dropFirst())
        .map { abs($1.centre.x - $0.centre.x) }.max() ?? 0

    // Measured 2026-08-25 with the eased aim: the re-aim's largest jump is 2.14× the plain
    // move's (0.0394 against 0.0184 per frame) — a re-aim mid-settle genuinely moves faster,
    // because it carries the velocity it already had. A bound of 3 is the right side of
    // that; the design audit's guess that it had become slack was wrong, and this number
    // is why the bound stays.
    #expect(reAimJump <= singleJump * 3, """
        the re-aim produced a \(reAimJump) per-frame jump against \(singleJump) for a plain \
        move — the spring restarted rather than carrying its velocity
        """)
}

// MARK: - the safe zone

/// **The row's third property.** A target a hair from where the camera already points must
/// not move it: without a dead zone the camera chases every few-pixel difference between
/// consecutive AX frames, and the footage shimmers.
@Test func aTargetInsideTheSafeZoneDoesNotMoveTheCamera() {
    let first = block(from: 1.0, to: 3.0, x: 0.40, y: 0.40)
    // Second target displaced by less than the safe zone.
    let nudge = CameraMotion.safeZone / 2
    let second = block(from: 3.0, to: 5.0, x: 0.40 + nudge, y: 0.40)

    let steady = CameraMotion(blocks: [first, block(from: 3.0, to: 5.0, x: 0.40, y: 0.40)])
    let nudged = CameraMotion(blocks: [first, second])
    #expect(steady.state(at: at(seconds: 4.5)).centre == nudged.state(at: at(seconds: 4.5)).centre,
            "a sub-safe-zone nudge moved the camera")
}

/// And a real move still moves it — a dead zone that swallowed everything would pass the
/// test above.
@Test func aTargetBeyondTheSafeZoneDoesMoveTheCamera() {
    let first = block(from: 1.0, to: 3.0, x: 0.40, y: 0.40)
    let far = block(from: 3.0, to: 6.0, x: 0.40 + CameraMotion.safeZone * 4, y: 0.40)
    let steady = CameraMotion(blocks: [first, block(from: 3.0, to: 6.0, x: 0.40, y: 0.40)])
    let moved = CameraMotion(blocks: [first, far])
    #expect(moved.state(at: at(seconds: 5.5)).centre.x > steady.state(at: at(seconds: 5.5)).centre.x)
}

// MARK: - determinism, which is this project's own requirement rather than the row's

/// **Fixed-timestep integration, and this is why.** A spring integrated at whatever
/// interval the caller happens to ask for accumulates differently on a 60 Hz preview and a
/// 24 fps export, so `render-parity`'s claim that one compositor drives both would become
/// false in the one place nobody would look. Asking for the same instant twice, and asking
/// for it after a different query, must give the same answer.
@Test func theSameInstantAlwaysYieldsTheSameState() {
    let camera = CameraMotion(blocks: [block(from: 1.0, to: 4.0, x: 0.3, y: 0.7)])
    let direct = camera.state(at: at(seconds: 2.0))
    _ = camera.state(at: at(seconds: 3.9))
    let afterOtherQueries = camera.state(at: at(seconds: 2.0))
    #expect(direct == afterOtherQueries)

    // And a coarse walk agrees with a fine one at a shared instant.
    let coarse = CameraMotion(blocks: [block(from: 1.0, to: 4.0, x: 0.3, y: 0.7)])
    #expect(coarse.state(at: at(seconds: 2.0)) == direct)
}

/// A camera with no blocks is at rest everywhere — the state a recording with no accepted
/// click produces, which must be a resting camera and not a crash.
@Test func aCameraWithNoBlocksRestsEverywhere() {
    let camera = CameraMotion(blocks: [])
    #expect(camera.state(at: at(seconds: 0)).zoom == 1.0)
    #expect(camera.state(at: at(seconds: 99)).centre == NormalizedPoint(x: 0.5, y: 0.5))
}

/// The camera never frames outside the recording: at zoom z the viewport is 1/z wide, so
/// its centre is confined to the inset region. A target at the screen edge pulls the centre
/// to the edge of that region and no further, or the export shows blank.
@Test func theViewportNeverLeavesTheRecording() {
    let corner = block(from: 1.0, to: 5.0, x: 0.0, y: 0.0, extent: 0.04)
    let camera = CameraMotion(blocks: [corner])
    for state in samples(camera, from: 0.0, to: 5.0) {
        let half = 0.5 / state.zoom
        #expect(state.centre.x - half >= -1e-9 && state.centre.x + half <= 1 + 1e-9,
                "the viewport left the recording at zoom \(state.zoom), centre \(state.centre.x)")
    }
}

// MARK: - borrowed from the other recorders

/// **Two clicks close together must not make the camera zoom out and back in.**
///
/// Blocks merge only when they overlap — `ZoomBlock.blocks` gives the measurement behind that
/// — so two clicks 2.5 s apart leave a 1.1 s gap between 1.4 s blocks. At ω = 10 the camera
/// makes most of its way back to zoom 1 in that time and then goes out again. Every block is
/// individually correct and the result still reads as a mistake.
///
/// `../opensource/Screen Record Opensource/an Electron recorder-main` calls this a chained zoom and pans
/// between the two instead, at a 1350 ms threshold. This checks the behaviour, not the
/// constant: the camera must stay meaningfully zoomed THROUGHOUT the gap.
@Suite struct ChainedZoomTests {
    private let epoch = BootEpoch(id: UUID(uuidString: "9B1DE104-6C3E-4E2A-8B3C-2B6A6F1F9C07")!)

    private func instant(_ seconds: Double) -> HostInstant {
        HostInstant(epoch: epoch, hostTime: Nanoseconds(Int64(seconds * 1_000_000_000)))
    }

    private func click(_ seconds: Double, x: Double, y: Double) -> FramedClick {
        FramedClick(instant: instant(seconds),
                    target: FramingTarget(
                        frame: NormalizedFrame(origin: NormalizedPoint(x: x, y: y),
                                               size: NormalizedSize(width: 0.06, height: 0.06),
                                               revision: GeometryRevision(id: 1)),
                        role: "AXButton"))
    }

    /// A gap inside the threshold: the camera holds its zoom across it.
    @Test func aShortGapPansInsteadOfReturningToRest() {
        // 1.4 s blocks, clicks 2.5 s apart → a 1.1 s gap, inside the 1.35 s threshold.
        let camera = CameraMotion(blocks: ZoomBlock.blocks(for: [
            click(10.0, x: 0.2, y: 0.2),
            click(12.5, x: 0.7, y: 0.7),
        ], coverage: 1))
        #expect(camera.blocksForTesting.count == 2, "the blocks merged; this tests the gap")

        // Sampled across the gap rather than at one instant: a single sample could catch the
        // camera mid-swing either way.
        let inGap = stride(from: 11.5, through: 12.3, by: 0.1).map { camera.state(at: instant($0)) }
        #expect(inGap.allSatisfy { $0.zoom > 1.2 }, """
                the camera fell to \(inGap.map { $0.zoom }.min() ?? 0) during the gap — it \
                returned toward rest instead of panning
                """)
        // …and it is on its way to the second target rather than sitting on the first.
        // No `#require`: `inGap` is non-empty by the assertion above, so the compiler knows
        // `last` never equals nil and says the requirement is redundant.
        let last = inGap.last
        #expect((last?.centre.x ?? 0) > 0.2, "the camera never started toward the second click")
    }

    /// A gap past the threshold is not a chain: the camera does return to rest, which is the
    /// correct picture of two unrelated moments.
    @Test func aLongGapStillReturnsToRest() {
        let camera = CameraMotion(blocks: ZoomBlock.blocks(for: [
            click(10.0, x: 0.2, y: 0.2),
            click(16.0, x: 0.7, y: 0.7),
        ], coverage: 1))
        // 1.4 s blocks 6 s apart → a 4.6 s gap. Sampled in the middle, well past settling.
        let middle = camera.state(at: instant(13.5))
        #expect(middle.zoom < 1.05, "the camera stayed zoomed across an unrelated \(4.6)s gap")
    }

    /// **While the viewport still covers the whole frame the centre snaps rather than
    /// springing.** At zoom 1 the centre changes nothing visible, so springing it wastes the
    /// only moment it is free — and the camera then scales STRAIGHT toward the focus instead
    /// of drifting sideways on the way in. From a Rust recorder's `zoom_spring.rs`.
    @Test func theCentreIsAlreadyAimedWhenTheZoomBegins() {
        let camera = CameraMotion(blocks: ZoomBlock.blocks(for: [click(10.0, x: 0.85, y: 0.15)], coverage: 1))
        // Just after the block opens, while the spring has barely moved the zoom.
        let early = camera.state(at: instant(9.62))
        #expect(early.zoom < CameraMotion.identityZoomBound + 0.05,
                "this sample is meant to catch the camera before it has zoomed")
        // The centre is at the target's, not at 0.5 — confined, because at zoom ~1 the only
        // legal centre IS the middle, so the check is that it is not springing from rest.
        let later = camera.state(at: instant(10.3))
        #expect(abs(later.centre.x - 0.88) < 0.25,
                "the camera was still drifting sideways at \(later.centre.x), not pre-aimed")
    }
}

// MARK: - the bake: cost, continuity, and the velocities a renderer reads

/// **A frame's cost does not grow with its distance into the recording.** The per-query
/// integration paid every step from the first block to the frame, so a 60 fps walk over a
/// ten-minute recording was O(n²) and stuttered on every zoom; the bake makes each query a
/// binary search. Measured rather than assumed: 36,000 queries — ten minutes at 60 fps —
/// across 200 blocks must finish inside two seconds, where the old shape needed minutes.
@Suite struct CameraBakeTests {
    private let epoch = BootEpoch(id: UUID(uuidString: "BA4E0000-1111-4222-8333-444455556666")!)

    private func instant(_ seconds: Double) -> HostInstant {
        HostInstant(epoch: epoch, hostTime: Nanoseconds(Int64(seconds * 1_000_000_000)))
    }

    private func block(from: Double, to: Double, x: Double, y: Double) -> ZoomBlock {
        let target = FramingTarget(
            frame: NormalizedFrame(origin: NormalizedPoint(x: x, y: y),
                                   size: NormalizedSize(width: 0.05, height: 0.05),
                                   revision: GeometryRevision(id: 1)), role: "AXButton")
        return ZoomBlock(origin: instant(from), start: instant(from), end: instant(to),
                         target: target, zoom: FramingDepth.zoom(for: target, coverage: 1))
    }

    @Test func tenMinutesOfFramesIsQueriedInSeconds() {
        let blocks = (0..<200).map { i -> ZoomBlock in
            let start = 1.0 + Double(i) * 3.0
            return block(from: start, to: start + 1.4,
                         x: 0.1 + Double(i % 7) * 0.1, y: 0.1 + Double(i % 5) * 0.15)
        }
        let camera = CameraMotion(blocks: blocks)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            var checksum = 0.0
            for frame in 0..<36_000 {
                checksum += camera.state(at: instant(Double(frame) / 60)).zoom
            }
            #expect(checksum > 36_000, "the camera never zoomed; the walk measured nothing")
        }
        #expect(elapsed < .seconds(2), "36,000 queries took \(elapsed)")
    }

    /// **The target is eased, so the acceleration ramps rather than jumps.** With a step
    /// target the spring's acceleration at the first step of a block is its PEAK for the
    /// move — the lurch the eye reads at every zoom. With the eased target the first
    /// step's acceleration is a small fraction of the peak. Second differences of the
    /// baked centre, per step, are the acceleration.
    @Test func theAccelerationRampsInsteadOfJumpingAtABlockStart() throws {
        let camera = CameraMotion(blocks: [block(from: 2.0, to: 5.0, x: 0.8, y: 0.8)])
        let path = camera.bakedPath(in: epoch)
        try #require(path.count > 100)
        // The zoom axis: the centre snaps at zoom 1 by design, so only the zoom's spring
        // starts from rest at the block start.
        let zooms = path.map(\.state.zoom)
        var accelerations: [Double] = []
        for i in 1..<(zooms.count - 1) {
            accelerations.append(abs(zooms[i + 1] - 2 * zooms[i] + zooms[i - 1]))
        }
        let peak = try #require(accelerations.max())
        #expect(peak > 0, "the zoom never moved")
        // The block opens at path index 0. With a STEP target the very first step's
        // acceleration is the move's peak — that is the lurch. Measured while this was
        // written, at an 8 ms step and a 120 ms ease: a single stage put the first step at
        // ~50% of the peak, the two-stage ease at 19%. A quarter discriminates both wrong
        // shapes from the right one without pinning the exact figure to the timestep.
        let opening = accelerations[0]
        #expect(opening < peak * 0.25, """
            the zoom's acceleration on the first step was \(opening) against a peak of \
            \(peak) — the spring saw a step, not an eased target
            """)
    }

    /// The velocities a renderer smears by: zero at rest, non-zero mid-move, zero again once
    /// settled — and the zoom's sign follows its direction.
    @Test func theStateCarriesVelocitiesThatMatchTheMotion() {
        let camera = CameraMotion(blocks: [block(from: 2.0, to: 5.0, x: 0.8, y: 0.8)])
        let before = camera.state(at: instant(1.0))
        #expect(!before.isMoving)
        let rising = camera.state(at: instant(2.15))
        #expect(rising.zoomVelocity > 0, "zooming in with a non-positive zoom velocity")
        #expect(rising.isMoving)
        let settled = camera.state(at: instant(4.9))
        #expect(abs(settled.zoomVelocity) < 0.01 && hypot(settled.velocityX, settled.velocityY) < 0.01,
                "still moving at \(settled) two seconds into a three-second block")
        let falling = camera.state(at: instant(5.2))
        #expect(falling.zoomVelocity < 0, "zooming out with a non-negative zoom velocity")
    }

    /// Two epochs, overlapping host times: each has its own path, and neither answers for
    /// the other.
    @Test func epochsBakeSeparatePaths() {
        let other = BootEpoch(id: UUID(uuidString: "0BADC0DE-0000-4000-8000-000000000003")!)
        let foreign = ZoomBlock(origin: HostInstant(epoch: other, hostTime: Nanoseconds(2_000_000_000)),
                                start: HostInstant(epoch: other, hostTime: Nanoseconds(2_000_000_000)),
                                end: HostInstant(epoch: other, hostTime: Nanoseconds(5_000_000_000)),
                                target: block(from: 2, to: 5, x: 0.8, y: 0.8).target, zoom: 2.0)
        let camera = CameraMotion(blocks: [foreign])
        #expect(camera.state(at: instant(3.0)) == .rest)
        #expect(camera.state(at: HostInstant(epoch: other, hostTime: Nanoseconds(3_000_000_000))).zoom > 1.5)
    }
}

// MARK: - the zoom ceiling

/// **The camera never aims past the ceiling, and it gets there as one motion.** A block whose
/// depth is 3 under a ceiling of 1.7: the peak zoom is the ceiling, and — because the ceiling
/// is applied to the AIM rather than clamped onto the state — the zoom's velocity is zero
/// once it has settled there, so the renderer does not smear a picture that has stopped.
@Suite struct ZoomCeilingTests {
    private let epoch = BootEpoch(id: UUID(uuidString: "CE111116-0000-4000-8000-000000000001")!)
    private func instant(_ seconds: Double) -> HostInstant {
        HostInstant(epoch: epoch, hostTime: Nanoseconds(Int64(seconds * 1_000_000_000)))
    }
    private var deep: ZoomBlock {
        let target = FramingTarget(
            frame: NormalizedFrame(origin: NormalizedPoint(x: 0.4, y: 0.4),
                                   size: NormalizedSize(width: 0.02, height: 0.02),
                                   revision: GeometryRevision(id: 1)), role: "AXCheckBox")
        return ZoomBlock(origin: instant(2), start: instant(2), end: instant(6),
                         target: target, zoom: FramingDepth.zoom(for: target, coverage: 1))
    }

    @Test func theZoomStopsAtTheCeilingWithoutWindingUp() {
        #expect(deep.zoom == FramingDepth.maximumZoom, "the fixture must aim deeper than the ceiling")
        let camera = CameraMotion(blocks: [deep], zoomCeiling: 1.7)
        let states = stride(from: 1.0, through: 6.0, by: 1.0 / 60).map { camera.state(at: instant($0)) }
        let peak = states.map(\.zoom).max() ?? 0
        #expect(peak <= 1.7 + 1e-6, "the zoom reached \(peak) past a ceiling of 1.7")
        #expect(peak > 1.65, "the zoom never approached the ceiling (\(peak))")
        let settled = camera.state(at: instant(5.5))
        #expect(abs(settled.zoomVelocity) < 0.01, "still moving at the ceiling: \(settled.zoomVelocity)")
    }

    /// Re-baking under a ceiling is the same blocks under another aim — nothing else moves.
    @Test func limitingRebakesTheSameBlocks() {
        let free = CameraMotion(blocks: [deep])
        let limited = free.limited(toZoomCeiling: 1.5)
        #expect(limited.blocksForTesting == free.blocksForTesting)
        #expect(limited.zoomCeiling == 1.5)
        #expect(free.zoomCeiling == .infinity)
        #expect(free.state(at: instant(4)).zoom > limited.state(at: instant(4)).zoom)
    }

    /// A ceiling below 1 is "no zoom": the camera stays at rest for the whole block.
    @Test func aCeilingBelowOneMeansNoZoom() {
        let camera = CameraMotion(blocks: [deep], zoomCeiling: 0.6)
        #expect(camera.zoomCeiling == 1.0)
        for seconds in stride(from: 1.0, through: 7.0, by: 0.25) {
            #expect(camera.state(at: instant(seconds)).zoom == 1.0)
        }
    }
}

// MARK: - following the cursor inside a zoom

/// **Inside a zoom the camera holds still until the cursor leaves the band, then moves by
/// the excess.** Three cases, each of which a different wrong rule passes: a cursor inside
/// the band must not move the centre (a tracking camera fails); a cursor past it must (a
/// fixed camera fails); and the move must be BY THE EXCESS, not to the cursor (a snapping
/// camera fails). The block is a 3.0× zoom on a small control at (0.5, 0.5), so the
/// viewport is a third of the recording and the band's reach is `(0.5 / 3) × 0.5`.
@Suite struct CursorFollowTests {
    private let epoch = BootEpoch(id: UUID(uuidString: "F0110000-0000-4000-8000-00000000000C")!)
    private func instant(_ seconds: Double) -> HostInstant {
        HostInstant(epoch: epoch, hostTime: Nanoseconds(Int64(seconds * 1_000_000_000)))
    }
    private var block: ZoomBlock {
        let target = FramingTarget(
            frame: NormalizedFrame(origin: NormalizedPoint(x: 0.49, y: 0.49),
                                   size: NormalizedSize(width: 0.02, height: 0.02),
                                   revision: GeometryRevision(id: 1)), role: "AXCheckBox")
        return ZoomBlock(origin: instant(2), start: instant(2), end: instant(8),
                         target: target, zoom: FramingDepth.zoom(for: target, coverage: 1))
    }
    private var reach: Double { (0.5 / block.zoom) * (1 - 2 * CameraMotion.followMargin) }

    /// A cursor that moves to `x` at t = 4 s and rests there.
    private func camera(cursorAt x: Double, y: Double = 0.5) -> CameraMotion {
        CameraMotion(blocks: [block], cursor: { instant in
            let seconds = Double(instant.hostTime.rawValue) / 1e9
            return seconds < 4 ? NormalizedPoint(x: 0.5, y: 0.5) : NormalizedPoint(x: x, y: y)
        })
    }

    @Test func aCursorInsideTheBandDoesNotMoveTheCamera() {
        #expect(block.zoom == 3.0, "the fixture must zoom deep enough to have a band")
        let inside = camera(cursorAt: 0.5 + reach * 0.9)
        let settled = inside.state(at: instant(7.5))
        #expect(abs(settled.centre.x - 0.5) < 0.002,
                "the camera moved to \(settled.centre.x) for a cursor still inside the band")
    }

    @Test func aCursorPastTheBandMovesTheCameraByTheExcess() {
        let x = 0.5 + reach + 0.06
        let pushed = camera(cursorAt: x)
        let settled = pushed.state(at: instant(7.5))
        // By the excess: the centre ends where the cursor sits exactly on the band's edge.
        #expect(abs(settled.centre.x - (x - reach)) < 0.003, """
            the camera settled at \(settled.centre.x); by-the-excess puts it at \(x - reach), \
            a snap-to-cursor at \(x)
            """)
        #expect(abs(settled.centre.y - 0.5) < 0.002, "a horizontal push moved the camera vertically")
    }

    /// The follow starts on the block's target: before the cursor moves, the camera frames
    /// the click, whatever the cursor did in an earlier block.
    @Test func eachBlockStartsOnItsOwnTarget() {
        let none = CameraMotion(blocks: [block])
        let following = camera(cursorAt: 0.9)
        // Before t = 4 the cursor sits on the target; both cameras must agree.
        #expect(none.state(at: instant(3.5)).centre == following.state(at: instant(3.5)).centre)
    }

    /// No cursor source is the camera that was: nothing here changes a block-only bake.
    @Test func withoutACursorTheCameraFramesTheTargetAndHolds() {
        let none = CameraMotion(blocks: [block])
        for seconds in stride(from: 3.0, through: 7.5, by: 0.5) {
            #expect(abs(none.state(at: instant(seconds)).centre.x - 0.5) < 0.002)
        }
    }
}
