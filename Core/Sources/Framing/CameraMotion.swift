import Foundation
import Geometry
import Timeline

/// Where the camera is at one instant: the centre of the viewport in normalised
/// coordinates, how far in it is zoomed — and how fast both are changing, for a renderer
/// that draws motion as motion.
public struct CameraState: Hashable, Sendable {
    public let centre: NormalizedPoint
    /// 1.0 is the whole recording; at `z` the viewport is `1/z` of it.
    public let zoom: Double
    /// The centre's velocity, normalised units of the recording per second.
    public let velocityX: Double
    public let velocityY: Double
    /// The zoom's rate of change per second.
    public let zoomVelocity: Double

    public init(centre: NormalizedPoint, zoom: Double,
                velocityX: Double = 0, velocityY: Double = 0, zoomVelocity: Double = 0) {
        self.centre = centre
        self.zoom = zoom
        self.velocityX = velocityX
        self.velocityY = velocityY
        self.zoomVelocity = zoomVelocity
    }

    /// At rest: the whole recording, centred, still.
    public static let rest = CameraState(centre: NormalizedPoint(x: 0.5, y: 0.5), zoom: 1.0)

    public var isMoving: Bool {
        velocityX != 0 || velocityY != 0 || zoomVelocity != 0
    }
}

/// How quickly the camera moves between framings: the spring's natural frequency, with the damping
/// held at 1 so every pace approaches its target from one side and none overshoots.
///
/// **A pace, not an easing curve.** The camera is a spring, and a spring's shape is set by its
/// damping; what a person means by "smoother" or "snappier" is how long it takes. Standard is the
/// ω the camera has always had. See `docs/design/2026-09-27-how-fast-the-camera-moves.md`.
public enum CameraPace: String, Hashable, Codable, Sendable, CaseIterable {
    case gentle, standard, snappy

    public var angularFrequency: Double {
        switch self {
        case .gentle: 6
        case .standard: 10
        case .snappy: 16
        }
    }

    public var displayName: String {
        switch self {
        case .gentle: "Gentle"
        case .standard: "Standard"
        case .snappy: "Snappy"
        }
    }
}

/// The camera, integrated from zoom blocks by a critically damped spring.
///
/// **Fixed timestep, and that is the load-bearing decision.** A spring stepped by whatever
/// interval the caller asks for accumulates differently on a 60 Hz preview and a 24 fps export,
/// and `render-parity`'s claim that one compositor drives both would quietly become false in the
/// one place nobody looks (`theSameInstantAlwaysYieldsTheSameState`).
///
/// **Baked once in `init`, read by binary search**, which is a correctness fix twice over: two
/// earlier drafts re-integrated per query and per frame, and the second was the stutter a long
/// recording showed on every zoom.
///
/// **Critically damped is ζ = 1, derived not tuned**; ω is the one free knob, set so a move
/// settles within 2% in ~0.9 s — slower than `ZoomBlock.preRoll`, so the camera is still moving
/// when the click lands and reads as following rather than anticipating.
///
/// Why the camera follows the cursor only inside `followMargin`'s band, and why the aim is
/// low-passed before the spring sees it: `docs/design/how-deep-the-camera-goes.md`.
public struct CameraMotion: Sendable {
    /// Where the presented cursor is at an instant, or `nil` where it is not drawn. The
    /// cursor lives in `Render` and this module does not depend on it, so it arrives as a
    /// function; the compositor, which has both, is what closes the loop. `@Sendable`
    /// because it is kept for a re-bake under another ceiling.
    public typealias CursorSource = @Sendable (HostInstant) -> NormalizedPoint?

    /// Integration step. 8 ms is ~2× finer than a 60 Hz frame, so a frame's state never
    /// depends on where its instant falls between steps.
    public static let timestep: Double = 0.008

    /// **The share of the zoomed viewport, on each side, that the cursor may not enter
    /// without the camera moving.** Inside the remaining middle the camera holds still —
    /// a camera that tracked the cursor's every move would never let a viewer read what
    /// it framed; at the band the aim shifts by exactly enough to bring the cursor back
    /// to the band's edge, so the picture pans no further than the cursor pushed it.
    /// The dead-zone follow
    /// calls this `snapToEdgesRatio` and ships 0.25 for both auto and manual zooms; the
    /// value is theirs. **Uncalibrated** here, like every constant in this module.
    public static let followMargin: Double = 0.25

    /// ζ = 1. Named rather than inlined so the "no overshoot" claim is legible as a
    /// parameter rather than a hope.
    public static let dampingRatio: Double = 1.0

    /// Natural frequency, rad/s. Settling to 2% takes ~0.9 s at ζ = 1.
    public static let angularFrequency: Double = 10.0

    /// The time constant of the easing the aim passes through, seconds — two first-order
    /// stages of half this each, so the eased aim is C1: its VELOCITY starts at zero too,
    /// and the spring's acceleration grows from nothing rather than jumping to a value at
    /// the block boundary (`theAccelerationRampsInsteadOfJumpingAtABlockStart` measures the
    /// first step against the peak). A single stage rounds the step but still kinks. 120 ms
    /// in total: short enough that the camera still arrives inside the block's pre-roll.
    /// **Uncalibrated**, like every constant in this module.
    public static let targetTimeConstant: Double = 0.12

    /// Movement below this is not worth making. Without it the camera chases the few-pixel
    /// difference between consecutive AX frames for what is visually the same control, and
    /// the footage shimmers. **Uncalibrated**, like every constant in this module.
    public static let safeZone: Double = 0.01

    /// The zoom at or below which the centre is free to move instantly. At 1.002
    /// the viewport is 99.8% of the frame, so any centre jump displaces the card
    /// by at most 0.2% of it — sub-pixel on any real output, which is what makes
    /// an instant move safe rather than merely cheap. **Uncalibrated.**
    public static let identityZoomBound: Double = 1.002

    /// How long after the last block the camera is treated as having settled back to rest.
    /// At ω = 10 a move is within 2% in ~0.9 s; 3 s is comfortably past that and is what
    /// bounds the integration on the far side.
    private static let settleMargin: Double = 3.0

    private let blocks: [ZoomBlock]
    /// The deepest zoom any block is allowed to aim for — `FramingDepth.zoomCeiling` for the
    /// recording's pixels on this output's card, or `.infinity` when the caller has no output
    /// yet. **Applied to the AIM, not to the state**: clamping the integrated zoom would flatten
    /// the top of the curve while the spring's velocity kept winding against the clamp, and a
    /// renderer reading that velocity would smear a picture that had stopped.
    public let zoomCeiling: Double
    /// The cursor the camera follows inside a zoom, or `nil` for a camera that frames the
    /// click's target and holds — see `followMargin`.
    private let cursor: CursorSource?
    /// One baked path per boot epoch. Two boots produce overlapping host times, so a path
    /// spanning both would be a duration computed across two clocks.
    private let paths: [BootEpoch: BakedPath]

    /// The blocks as sorted and grouped. Exposed so a test can assert its own fixture did NOT
    /// merge before asserting anything about the gap between two of them — a fixture that
    /// merged would pass a gap test vacuously.
    public var blocksForTesting: [ZoomBlock] { blocks }

    /// How fast it moves. Carried so a re-bake under another ceiling keeps it.
    public let pace: CameraPace

    public init(blocks: [ZoomBlock], zoomCeiling: Double = .infinity,
                cursor: CursorSource? = nil, pace: CameraPace = .standard) {
        self.pace = pace
        let sorted = blocks.sorted { $0.start.hostTime.rawValue < $1.start.hostTime.rawValue }
        self.blocks = sorted
        // A ceiling below 1 is "no zoom", never "zoom out"; NaN is treated as no ceiling.
        let ceiling = zoomCeiling.isNaN ? .infinity : max(zoomCeiling, 1.0)
        self.zoomCeiling = ceiling
        self.cursor = cursor
        var paths: [BootEpoch: BakedPath] = [:]
        for (epoch, group) in Dictionary(grouping: sorted, by: { $0.start.epoch }) {
            paths[epoch] = Integrator(blocks: group, zoomCeiling: ceiling, epoch: epoch,
                                      cursor: cursor, angularFrequency: pace.angularFrequency).bake()
        }
        self.paths = paths
    }

    /// The same blocks under another ceiling — what the compositor asks for once it knows
    /// the output's card, which the log alone does not say. A re-bake, not a clamp.
    public func limited(toZoomCeiling ceiling: Double) -> CameraMotion {
        CameraMotion(blocks: blocks, zoomCeiling: ceiling, cursor: cursor, pace: pace)
    }

    /// The same blocks at another pace — a re-bake, for the same reason `limited` is one.
    public func pacing(_ pace: CameraPace) -> CameraMotion {
        CameraMotion(blocks: blocks, zoomCeiling: zoomCeiling, cursor: cursor, pace: pace)
    }

    /// The camera at `instant`. At rest before the first block and past the last plus
    /// `settleMargin`; in between, the baked state at the first integration step at or past
    /// the instant — the same step a per-query `while time < end` integration stopped at,
    /// so the bake changes where the work happens and not which step answers.
    public func state(at instant: HostInstant) -> CameraState {
        guard let path = paths[instant.epoch] else { return .rest }
        let now = Double(instant.hostTime.rawValue) / 1_000_000_000
        guard now > path.begin, now <= path.stop else { return .rest }
        let elapsed = now - path.begin
        // Lower bound: the first stored time that is `>= elapsed`. The integration loop
        // ran `while time < end`, so it stopped at exactly this step.
        var low = 0, high = path.times.count
        while low < high {
            let mid = low + (high - low) / 2
            if path.times[mid] < elapsed { low = mid + 1 } else { high = mid }
        }
        return low < path.states.count ? path.states[low] : path.states[path.states.count - 1]
    }

    /// The whole baked path for one epoch as (seconds after the first block, state) pairs,
    /// for a test or a timeline that wants the curve rather than one point on it.
    public func bakedPath(in epoch: BootEpoch) -> [(seconds: Double, state: CameraState)] {
        guard let path = paths[epoch] else { return [] }
        return Array(zip(path.times, path.states)).map { (seconds: $0.0, state: $0.1) }
    }

    /// Keeps the viewport inside the recording: at zoom `z` it is `1/z` wide, so the centre
    /// lives in the inset region. A target at the very edge pulls the centre to the edge of
    /// that region and no further, or the export shows blank where the recording ends.
    static func confine(_ point: NormalizedPoint, zoom: Double) -> NormalizedPoint {
        let half = 0.5 / zoom
        let lo = min(half, 0.5), hi = max(1 - half, 0.5)
        return NormalizedPoint(x: min(max(point.x, lo), hi), y: min(max(point.y, lo), hi))
    }

    // MARK: - the bake

    private struct BakedPath: Sendable {
        /// Absolute seconds of the first block's start and of rest on the far side.
        let begin: Double
        let stop: Double
        /// `times[k]` is the accumulated integration time after `k` steps; `states[k]` the
        /// state then. `times[0] == 0` is the rest state at `begin`.
        let times: [Double]
        let states: [CameraState]
    }

    private struct Integrator {
        let blocks: [ZoomBlock]     // one epoch, sorted by start
        let zoomCeiling: Double
        let epoch: BootEpoch
        let cursor: CursorSource?
        /// The pace's ω. `CameraMotion.angularFrequency` is the standard pace's, kept as the
        /// named default the settling arithmetic in the headers above is written against.
        let angularFrequency: Double

        /// **The follow's memory: which block the camera is inside and where its centre has
        /// been pushed to.** Persistent across steps, because the rule is "hold until the
        /// cursor leaves the band, then move by the excess" — a centre recomputed from the
        /// cursor every step would be a tracking camera, which is the thing the band exists
        /// to prevent. Reset when the block changes, so each zoom starts on its target.
        struct Follow {
            var origin: HostInstant?
            var centre: NormalizedPoint
        }

        func bake() -> BakedPath {
            guard let first = blocks.first,
                  let lastEnd = blocks.map(\.end.hostTime.rawValue).max() else {
                return BakedPath(begin: 0, stop: 0, times: [0], states: [.rest])
            }
            let begin = Double(first.start.hostTime.rawValue) / 1_000_000_000
            let stop = Double(lastEnd) / 1_000_000_000 + CameraMotion.settleMargin
            let horizon = stop - begin

            let dt = CameraMotion.timestep
            let k = angularFrequency * angularFrequency
            let c = 2 * CameraMotion.dampingRatio * angularFrequency
            // Each stage's per-step gain, exact for a held input.
            let ease = 1 - exp(-dt / (CameraMotion.targetTimeConstant / 2))

            var centre = NormalizedPoint(x: 0.5, y: 0.5)
            var zoom = 1.0
            var velocityX = 0.0, velocityY = 0.0, velocityZoom = 0.0
            // The aim the camera is currently converging on, held across steps so a target
            // inside the safe zone leaves it unchanged rather than being re-decided per step.
            var aim = CameraState.rest
            var follow = Follow(origin: nil, centre: NormalizedPoint(x: 0.5, y: 0.5))
            // The EASED aim, in two stages: the first rounds the step, the second rounds the
            // first's kink. The second is what the spring chases.
            var stageX = 0.5, stageY = 0.5, stageZoom = 1.0
            var targetX = 0.5, targetY = 0.5, targetZoom = 1.0

            var times: [Double] = [0]
            var states: [CameraState] = [.rest]
            let expected = Int(horizon / dt) + 2
            times.reserveCapacity(expected)
            states.reserveCapacity(expected)

            var time = 0.0
            while time < horizon {
                // `aim` is asked in ABSOLUTE seconds; the loop counts from the first block.
                aim = self.aim(at: begin + time, previous: aim, follow: &follow)
                stageX += (aim.centre.x - stageX) * ease
                stageY += (aim.centre.y - stageY) * ease
                stageZoom += (aim.zoom - stageZoom) * ease
                targetX += (stageX - targetX) * ease
                targetY += (stageY - targetY) * ease
                targetZoom += (stageZoom - targetZoom) * ease

                // Semi-implicit Euler: velocity first, then position. Stable at this step
                // for the frequencies here, and the ordering is what keeps it so.
                velocityX += (-k * (centre.x - targetX) - c * velocityX) * dt
                velocityY += (-k * (centre.y - targetY) - c * velocityY) * dt
                velocityZoom += (-k * (zoom - targetZoom) - c * velocityZoom) * dt
                zoom += velocityZoom * dt
                // Zoom cannot go below 1: a spring undershooting past rest would show more
                // than the recording contains.
                if zoom < 1.0 { zoom = 1.0; velocityZoom = max(velocityZoom, 0) }
                if zoom <= CameraMotion.identityZoomBound {
                    // **While the viewport still covers the whole frame, the centre snaps.**
                    // At zoom 1 the centre changes nothing that is visible, so springing it
                    // wastes the only moment it is free: the camera arrives at the next
                    // zoom's focus already aimed, and scales STRAIGHT toward it instead of
                    // drifting sideways as it goes in.
                    // whose bound is chosen on the same argument.
                    centre = CameraMotion.confine(NormalizedPoint(x: targetX, y: targetY),
                                                  zoom: zoom)
                    velocityX = 0
                    velocityY = 0
                } else {
                    let free = NormalizedPoint(x: centre.x + velocityX * dt,
                                               y: centre.y + velocityY * dt)
                    centre = CameraMotion.confine(free, zoom: zoom)
                    // **The edge of the recording is a wall, and a wall stops the camera.**
                    // A target past the confined region — a control at the screen's edge —
                    // would otherwise wind the spring's velocity up against a position that
                    // cannot move, and a renderer reading that velocity would smear a
                    // picture that is standing still. Zeroed per axis, on the axis that hit.
                    if centre.x != free.x { velocityX = 0 }
                    if centre.y != free.y { velocityY = 0 }
                }
                time += dt
                times.append(time)
                states.append(CameraState(centre: centre, zoom: zoom,
                                          velocityX: velocityX, velocityY: velocityY,
                                          zoomVelocity: velocityZoom))
            }
            return BakedPath(begin: begin, stop: stop, times: times, states: states)
        }

        /// The block covering `time`, as an aim — or rest between blocks. A new aim inside
        /// the safe zone of the previous one keeps the previous one exactly, which is what
        /// stops the camera chasing jitter; the zoom is compared on its own scale.
        private func aim(at time: Double, previous: CameraState,
                         follow: inout Follow) -> CameraState {
            let nanos = Int64(time * 1_000_000_000)
            let active = blocks.first {
                $0.start.hostTime.rawValue <= nanos && nanos < $0.end.hostTime.rawValue
            }
            let proposed: CameraState
            if let active {
                proposed = followed(aim(of: active), in: active, at: nanos, follow: &follow)
            } else if let chained = chainedNeighbour(at: nanos) {
                // **In a short gap the camera pans to the next block instead of returning to
                // rest.** Blocks merge only on overlap — for the reason `ZoomBlock.blocks`
                // gives — so two clicks 2.5 s apart leave a 1.1 s gap, which at ω = 10 is
                // long enough to make most of the way back to zoom 1 and then go out again.
                // Every block is individually correct and the result still reads as a
                // mistake. Sometimes called a chained zoom.
                proposed = aim(of: chained)
            } else {
                proposed = .rest
            }
            let moved = hypot(proposed.centre.x - previous.centre.x,
                              proposed.centre.y - previous.centre.y)
            if moved < CameraMotion.safeZone
                && abs(proposed.zoom - previous.zoom) < CameraMotion.safeZone {
                return previous
            }
            return proposed
        }

        /// A block as an aim: its target's centre, at its own depth — or at the ceiling,
        /// when the recording's pixels cannot carry the depth on this output.
        private func aim(of block: ZoomBlock) -> CameraState {
            let frame = block.target.frame
            return CameraState(centre: NormalizedPoint(x: frame.minX + frame.size.width / 2,
                                                       y: frame.minY + frame.size.height / 2),
                               zoom: min(block.zoom, zoomCeiling))
        }

        /// `base` with its centre pushed by the cursor, per `followMargin`.
        ///
        /// The band is measured in the block's OWN viewport — `1 / base.zoom` of the
        /// recording — rather than the camera's current one: while the zoom is still
        /// arriving the current viewport is wider than the block's, and a band drawn on it
        /// would let the cursor sit somewhere that is off-screen a moment later. A block
        /// whose depth is 1 has no viewport to leave and follows nothing.
        private func followed(_ base: CameraState, in block: ZoomBlock, at nanos: Int64,
                              follow: inout Follow) -> CameraState {
            guard let cursor, base.zoom > CameraMotion.identityZoomBound else { return base }
            if follow.origin != block.origin {
                follow = Follow(origin: block.origin, centre: base.centre)
            }
            let instant = HostInstant(epoch: epoch, hostTime: Nanoseconds(nanos))
            guard let pointer = cursor(instant) else {
                return CameraState(centre: follow.centre, zoom: base.zoom)
            }
            // The band's half-width: the viewport's half, less the margin on that side.
            let half = 0.5 / base.zoom
            let reach = half * (1 - 2 * CameraMotion.followMargin)
            var centre = follow.centre
            if pointer.x > centre.x + reach { centre = NormalizedPoint(x: pointer.x - reach, y: centre.y) }
            if pointer.x < centre.x - reach { centre = NormalizedPoint(x: pointer.x + reach, y: centre.y) }
            if pointer.y > centre.y + reach { centre = NormalizedPoint(x: centre.x, y: pointer.y - reach) }
            if pointer.y < centre.y - reach { centre = NormalizedPoint(x: centre.x, y: pointer.y + reach) }
            follow.centre = CameraMotion.confine(centre, zoom: base.zoom)
            return CameraState(centre: follow.centre, zoom: base.zoom)
        }

        /// The block to pan toward while `nanos` sits in a gap short enough to chain, or
        /// `nil` when the gap is long enough that returning to rest is the right answer.
        ///
        /// Both sides are required: a gap before the FIRST block is not a chain — there is
        /// nothing to hold a zoom from — and neither is one after the last.
        private func chainedNeighbour(at nanos: Int64) -> ZoomBlock? {
            guard let previous = blocks.last(where: { $0.end.hostTime.rawValue <= nanos }),
                  let next = blocks.first(where: { $0.start.hostTime.rawValue > nanos })
            else { return nil }
            let gap = next.start.hostTime.rawValue - previous.end.hostTime.rawValue
            guard gap > 0, gap < ZoomBlock.chainedPanGap.rawValue else { return nil }
            return next
        }
    }
}
