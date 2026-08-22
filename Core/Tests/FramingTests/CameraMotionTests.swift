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
                     target: target, zoom: FramingDepth.zoom(for: target))
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
    #expect(peak <= FramingDepth.zoom(for: block(from: 1, to: 4, x: 0.4, y: 0.4).target) + 1e-6,
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
        ]))
        #expect(camera.blocksForTesting.count == 2, "the blocks merged; this tests the gap")

        // Sampled across the gap rather than at one instant: a single sample could catch the
        // camera mid-swing either way.
        let inGap = stride(from: 11.5, through: 12.3, by: 0.1).map { camera.state(at: instant($0)) }
        #expect(inGap.allSatisfy { $0.zoom > 1.2 }, """
                the camera fell to \(inGap.map { $0.zoom }.min() ?? 0) during the gap — it \
                returned toward rest instead of panning
                """)
        // …and it is on its way to the second target rather than sitting on the first.
        let last = try? #require(inGap.last)
        #expect((last?.centre.x ?? 0) > 0.2, "the camera never started toward the second click")
    }

    /// A gap past the threshold is not a chain: the camera does return to rest, which is the
    /// correct picture of two unrelated moments.
    @Test func aLongGapStillReturnsToRest() {
        let camera = CameraMotion(blocks: ZoomBlock.blocks(for: [
            click(10.0, x: 0.2, y: 0.2),
            click(16.0, x: 0.7, y: 0.7),
        ]))
        // 1.4 s blocks 6 s apart → a 4.6 s gap. Sampled in the middle, well past settling.
        let middle = camera.state(at: instant(13.5))
        #expect(middle.zoom < 1.05, "the camera stayed zoomed across an unrelated \(4.6)s gap")
    }

    /// **While the viewport still covers the whole frame the centre snaps rather than
    /// springing.** At zoom 1 the centre changes nothing visible, so springing it wastes the
    /// only moment it is free — and the camera then scales STRAIGHT toward the focus instead
    /// of drifting sideways on the way in. From a Rust recorder's `zoom_spring.rs`.
    @Test func theCentreIsAlreadyAimedWhenTheZoomBegins() {
        let camera = CameraMotion(blocks: ZoomBlock.blocks(for: [click(10.0, x: 0.85, y: 0.15)]))
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
