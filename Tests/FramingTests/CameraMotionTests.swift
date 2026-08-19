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
    return ZoomBlock(start: at(seconds: from), end: at(seconds: to),
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
