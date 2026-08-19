import Foundation
import Geometry
import Timeline

/// Where the camera is at one instant: the centre of the viewport in normalised
/// coordinates, and how far in it is zoomed.
public struct CameraState: Hashable, Sendable {
    public let centre: NormalizedPoint
    /// 1.0 is the whole recording; at `z` the viewport is `1/z` of it.
    public let zoom: Double

    public init(centre: NormalizedPoint, zoom: Double) {
        self.centre = centre
        self.zoom = zoom
    }
}

/// The camera, integrated from zoom blocks by a critically damped spring.
///
/// **Fixed timestep, and that is the load-bearing decision.** A spring stepped by whatever
/// interval the caller happens to ask for accumulates differently on a 60 Hz preview and a
/// 24 fps export — the same recording would produce two different camera paths, and
/// `render-parity`'s claim that one compositor drives both would quietly become false in
/// the one place nobody thinks to look. Every query integrates from zero at a fixed
/// `timestep`, so the answer is a function of the instant alone
/// (`theSameInstantAlwaysYieldsTheSameState`).
///
/// **Critically damped, not tuned by feel.** `camera-motion`'s row says "settles without
/// overshoot", and for a spring-mass-damper that is exactly ζ = 1 — not a value found by
/// watching footage. The one free knob left is ω, chosen so the move settles to within 2%
/// in ~0.9 s: slower than `ZoomBlock.preRoll`, so the camera is still moving when the click
/// lands, which is what makes the motion read as following the action rather than
/// anticipating it.
public struct CameraMotion: Sendable {
    /// Integration step. 8 ms is ~2× finer than a 60 Hz frame, so a frame's state never
    /// depends on where its instant falls between steps.
    public static let timestep: Double = 0.008

    /// ζ = 1. Named rather than inlined so the "no overshoot" claim is legible as a
    /// parameter rather than a hope.
    public static let dampingRatio: Double = 1.0

    /// Natural frequency, rad/s. Settling to 2% takes ~0.9 s at ζ = 1.
    public static let angularFrequency: Double = 10.0

    /// Movement below this is not worth making. Without it the camera chases the few-pixel
    /// difference between consecutive AX frames for what is visually the same control, and
    /// the footage shimmers. **Uncalibrated**, like every constant in this module.
    public static let safeZone: Double = 0.01

    private let blocks: [ZoomBlock]

    public init(blocks: [ZoomBlock]) {
        self.blocks = blocks.sorted { $0.start.hostTime.rawValue < $1.start.hostTime.rawValue }
    }

    /// How long after the last block the camera is treated as having settled back to rest.
    /// At ω = 10 a move is within 2% in ~0.9 s; 3 s is comfortably past that and is what
    /// bounds the integration on the far side.
    private static let settleMargin: Double = 3.0

    /// The camera at `instant`, integrated from rest.
    ///
    /// **Integration starts at the first block, not at zero, and that is a correctness fix
    /// rather than an optimisation.** Host instants are `mach_absolute_time` — on the order
    /// of 10¹⁴ ns — so integrating from absolute zero at an 8 ms step is ~12 million steps
    /// PER QUERY, and a 30 Hz sample of six seconds of a real recording never finished.
    /// Found by the end-to-end test against the row-14 recording, which is what a fixture
    /// made of real data is for. The camera is provably at rest before its first block, so
    /// starting there changes no answer; past the last block plus `settleMargin` it is at
    /// rest again, which bounds the far side.
    public func state(at instant: HostInstant) -> CameraState {
        let rest = CameraState(centre: NormalizedPoint(x: 0.5, y: 0.5), zoom: 1.0)
        guard let firstBlock = blocks.first(where: { $0.start.epoch == instant.epoch }),
              let lastEnd = blocks.filter({ $0.start.epoch == instant.epoch })
                  .map(\.end.hostTime.rawValue).max()
        else { return rest }

        let now = Double(instant.hostTime.rawValue) / 1_000_000_000
        let begin = Double(firstBlock.start.hostTime.rawValue) / 1_000_000_000
        guard now > begin else { return rest }
        guard now <= Double(lastEnd) / 1_000_000_000 + Self.settleMargin else { return rest }

        let end = now - begin
        var centre = NormalizedPoint(x: 0.5, y: 0.5)
        var zoom = 1.0
        var velocityX = 0.0, velocityY = 0.0, velocityZoom = 0.0
        // The aim the camera is currently converging on, held across steps so a target
        // inside the safe zone leaves it unchanged rather than being re-decided per step.
        var aim = CameraState(centre: NormalizedPoint(x: 0.5, y: 0.5), zoom: 1.0)

        var time = 0.0
        while time < end {
            // `aim` is asked in ABSOLUTE seconds; the loop counts from the first block.
            aim = self.aim(at: begin + time, previous: aim)
            let dt = Self.timestep
            let k = Self.angularFrequency * Self.angularFrequency
            let c = 2 * Self.dampingRatio * Self.angularFrequency

            // Semi-implicit Euler: velocity first, then position. Stable at this step for
            // the frequencies here, and the ordering is what keeps it so.
            velocityX += (-k * (centre.x - aim.centre.x) - c * velocityX) * dt
            velocityY += (-k * (centre.y - aim.centre.y) - c * velocityY) * dt
            velocityZoom += (-k * (zoom - aim.zoom) - c * velocityZoom) * dt
            zoom += velocityZoom * dt
            // Zoom cannot go below 1: a spring undershooting past rest would show more than
            // the recording contains.
            zoom = max(1.0, zoom)
            centre = Self.confine(
                NormalizedPoint(x: centre.x + velocityX * dt, y: centre.y + velocityY * dt),
                zoom: zoom)
            time += dt
        }
        return CameraState(centre: centre, zoom: zoom)
    }

    /// The block covering `time`, as an aim — or rest between blocks. A new aim inside the
    /// safe zone of the previous one keeps the previous one exactly, which is what stops
    /// the camera chasing jitter; the zoom is compared on its own scale.
    private func aim(at time: Double, previous: CameraState) -> CameraState {
        let nanos = Int64(time * 1_000_000_000)
        let active = blocks.first {
            $0.start.hostTime.rawValue <= nanos && nanos < $0.end.hostTime.rawValue
        }
        let proposed: CameraState
        if let active {
            let frame = active.target.frame
            proposed = CameraState(
                centre: NormalizedPoint(x: frame.minX + frame.size.width / 2,
                                        y: frame.minY + frame.size.height / 2),
                zoom: active.zoom)
        } else {
            proposed = CameraState(centre: NormalizedPoint(x: 0.5, y: 0.5), zoom: 1.0)
        }
        let moved = hypot(proposed.centre.x - previous.centre.x,
                          proposed.centre.y - previous.centre.y)
        if moved < Self.safeZone && abs(proposed.zoom - previous.zoom) < Self.safeZone {
            return previous
        }
        return proposed
    }

    /// Keeps the viewport inside the recording: at zoom `z` it is `1/z` wide, so the centre
    /// lives in the inset region. A target at the very edge pulls the centre to the edge of
    /// that region and no further, or the export shows blank where the recording ends.
    private static func confine(_ point: NormalizedPoint, zoom: Double) -> NormalizedPoint {
        let half = 0.5 / zoom
        let lo = min(half, 0.5), hi = max(1 - half, 0.5)
        return NormalizedPoint(x: min(max(point.x, lo), hi), y: min(max(point.y, lo), hi))
    }
}
