import Foundation
import Geometry
import Project
import Timeline

/// The cursor a viewer sees: the recorded path, followed by a spring.
///
/// `PointerTrack` has the other two queries — `position(at:)` is the review path's truth and
/// `smoothedPosition(at:)` is the lerp between brackets, and both keep every tremor the hand
/// made. This is the presentation path, the only one allowed to be gentle about the shape of
/// the motion: a cardinal spline resampled onto a fixed grid, a spring at damping ratio 0.9
/// following it, idle stabilisation, phase lead, and a stiffer spring into a click. What each
/// stage is for, and the number attached to it, is in `docs/design/how-the-drawn-cursor-behaves.md`.
///
/// **It refuses exactly what `smoothedPosition` refuses**: no spline across a gap wider than
/// `PointerTrack.maxInterpolationGap` and none across a blind interval — across either the
/// target holds, so the cursor follows observation rather than inventing motion nothing saw.
///
/// **Baked once in `init`, queried by binary search**, because the spring's answer at `t`
/// depends on everything before `t` and a per-frame integration would be the O(n²) that
/// `CameraMotion` was. Deterministic across machines and output frame rates — `render-parity`
/// depends on that.
public struct PointerPath: Sendable {
    /// One baked entry. `speed` is the spring's own, in normalised units per second — the
    /// measure a cursor's presentation can key off (rotation, auto-hide) without re-deriving.
    public struct Entry: Hashable, Sendable {
        public let hostTime: Int64
        public let position: NormalizedPoint
        public let speed: Double
        /// The spring's velocity by axis, normalised units per second — what a tilt reads.
        public let velocityX: Double
        public let velocityY: Double
    }

    /// The knobs. **Uncalibrated in this project's sense** — no measurement chose them —
    /// but not arbitrary either: `dampingRatio`, `responseSeconds`, the adaptive pair and the
    /// idle rule are the measured defaults; `clickStiffenWindow` is
    /// `CLICK_SPRING_WINDOW_MS`.
    public struct Tuning: Hashable, Sendable {
        /// ζ. Below 1 overshoots by a hair; 1 never overshoots and looks mechanical.
        public var dampingRatio: Double
        /// Seconds for the spring to close on a step, as `ω = 2π / response`.
        public var responseSeconds: Double
        /// The speed (normalised units/s) at which the response is fully shortened.
        public var adaptiveMaxSpeed: Double
        /// The response at full speed, as a fraction of `responseSeconds`.
        public var adaptiveMinScale: Double
        /// Below this target speed the cursor is treated as resting.
        public var idleSpeed: Double
        /// How fast the idle blend climbs per second, and where it caps.
        public var idleBlendRate: Double
        public var idleBlendCap: Double
        /// How long before a button-down the spring stiffens.
        public var clickStiffenWindow: Nanoseconds
        /// The response inside that window.
        public var clickResponseSeconds: Double
        /// Cardinal-spline tension, 0 = Catmull-Rom, 1 = straight lines.
        public var splineTension: Double
        /// **Drop a reversal inside a short window.** Three
        /// samples inside `shakeWindow` where the middle one reverses direction and both
        /// legs are under `shakeThreshold` are a hand tremor, not a move, and the middle
        /// sample goes. Sold elsewhere as "remove cursor shakes".
        public var removesShakes: Bool
        public var shakeWindow: Nanoseconds
        /// Normalised units.
        public var shakeThreshold: Double

        /// **How much the cursor glides: four named amounts, plus off.**
        ///
        /// One hard-coded response was the defect, and the value it was hard-coded to was the
        /// fastest one anybody ships. Measured against the references: this file's 60 ms is
        /// ω = 2π/0.06 = 105 rad/s, while a shipped cursor spring at `tension 470, mass 3,
        /// friction 70`, converted by its own `omega0 = sqrt(k/m)` — is **12.5 rad/s**, eight
        /// times slower. A spring that settles in 40 ms has reproduced the hand's own path by
        /// the next frame, which is why the result looked like a hand and not like a glide.
        /// A ladder of four named amounts rather than one number, which is the other half of
        /// the answer: how much glide somebody wants is a taste.
        ///
        /// `Default` sits at the value that reads as a glide rather than as a follow.
        /// **Uncalibrated** in this project's sense — the ladder's shape is chosen, and only
        /// its ends are anchored to a measurement.
        public enum Movement: String, Hashable, Codable, Sendable, CaseIterable {
            /// No spring at all: the presented path is the observations, as the lerp gave them.
            case none
            case rapid, quick, standard, slow

            public var displayName: String {
                switch self {
                case .none: "None"
                case .rapid: "Rapid"
                case .quick: "Quick"
                case .standard: "Default"
                case .slow: "Slow"
                }
            }

            /// Seconds for the spring to close on a step, before the adaptive shortening.
            public var responseSeconds: Double {
                switch self {
                case .none: 0.001
                case .rapid: 0.10
                case .quick: 0.20
                case .standard: 0.34
                case .slow: 0.52
                }
            }

            /// **How much of the response survives at full speed**, as `Tuning.adaptiveMinScale`.
            ///
            /// **One number for every setting was why "Slow" did not feel slow.** The adaptive
            /// rule shortens the spring as the cursor moves faster, and it shortened every
            /// setting to the same 0.4 — so `slow`'s 0.52 s became 0.208 s the moment the hand
            /// moved, which is exactly when smoothing is the thing you can see. Choosing a
            /// slower cursor and getting the standard one back at speed is a control that does
            /// nothing where it matters.
            ///
            /// Rising with the setting rather than fixed: a person who asked for rapid wants
            /// the cursor under their hand, and a person who asked for slow wants the arc.
            public var adaptiveMinScale: Double {
                switch self {
                case .none: 1
                case .rapid: 0.30
                case .quick: 0.35
                case .standard: 0.40
                case .slow: 0.75
                }
            }

            /// The angular frequency it works out to, for comparing with a reference that
            /// publishes stiffness and mass instead.
            public var angularFrequency: Double { 2 * Double.pi / responseSeconds }
        }

        /// This tuning at `movement`'s response AND its adaptive floor, everything else
        /// unchanged.
        ///
        /// **Both, because setting only the response left the floor at the default** and the
        /// floor is what decides how much of the response survives a fast move. See
        /// `Movement.adaptiveMinScale`.
        public func moving(_ movement: Movement) -> Tuning {
            var updated = self
            updated.responseSeconds = movement.responseSeconds
            updated.adaptiveMinScale = movement.adaptiveMinScale
            return updated
        }

        public static let `default` = Tuning(
            dampingRatio: 0.9, responseSeconds: Movement.standard.responseSeconds,
            adaptiveMaxSpeed: 4.0, adaptiveMinScale: 0.4,
            idleSpeed: 0.3, idleBlendRate: 3.0, idleBlendCap: 0.95,
            clickStiffenWindow: Nanoseconds(175_000_000), clickResponseSeconds: 0.035,
            splineTension: 0.2,
            removesShakes: true, shakeWindow: Nanoseconds(100_000_000), shakeThreshold: 0.015)

        public init(dampingRatio: Double, responseSeconds: Double, adaptiveMaxSpeed: Double,
                    adaptiveMinScale: Double, idleSpeed: Double, idleBlendRate: Double,
                    idleBlendCap: Double, clickStiffenWindow: Nanoseconds,
                    clickResponseSeconds: Double, splineTension: Double,
                    removesShakes: Bool = true,
                    shakeWindow: Nanoseconds = Nanoseconds(100_000_000),
                    shakeThreshold: Double = 0.015) {
            // Clamped, not trapped: a tuning can arrive from a preferences file one day and
            // a spring with a zero or negative response divides by it.
            self.dampingRatio = min(max(dampingRatio, 0.05), 2)
            self.responseSeconds = max(responseSeconds, 0.001)
            self.adaptiveMaxSpeed = max(adaptiveMaxSpeed, 0.001)
            self.adaptiveMinScale = min(max(adaptiveMinScale, 0.05), 1)
            self.idleSpeed = max(idleSpeed, 0)
            self.idleBlendRate = max(idleBlendRate, 0)
            self.idleBlendCap = min(max(idleBlendCap, 0), 0.999)
            self.clickStiffenWindow = Nanoseconds(max(clickStiffenWindow.rawValue, 0))
            self.clickResponseSeconds = max(clickResponseSeconds, 0.001)
            self.splineTension = min(max(splineTension, 0), 1)
            self.removesShakes = removesShakes
            self.shakeWindow = Nanoseconds(max(shakeWindow.rawValue, 0))
            self.shakeThreshold = max(shakeThreshold, 0)
        }

        /// The longest the spring can trail a target moving at constant speed, in seconds.
        /// At steady state a damped oscillator trails by `2ζ/ω`; the base response is the
        /// slowest the spring ever is, so this is the bound. Public because
        /// `RecordedPointerPositionTests` bounds its expectation with it against the real
        /// recording, and a test that re-derived the number would share the mistake.
        public var worstCaseLagSeconds: Double {
            let omega = 2 * Double.pi / responseSeconds
            return 2 * dampingRatio / omega
        }
    }

    /// Integration step. 4 ms is a quarter of a 60 Hz frame and a third of a 120 Hz one, so
    /// a frame's position is a lerp across a bracket far narrower than its own duration.
    public static let step = Nanoseconds(4_000_000)

    private let byEpoch: [BootEpoch: [Entry]]
    public let tuning: Tuning

    /// `clickInstants` are button-DOWN instants; `.up` has no ripple and no anticipation.
    public init(samples: [PointerSample], blindIntervals: [BlindInterval],
                clickInstants: [HostInstant], tuning: Tuning = .default) {
        self.tuning = tuning
        let grouped = Dictionary(grouping: samples) { $0.instant.epoch }
        let clicksByEpoch = Dictionary(grouping: clickInstants) { $0.epoch }
        var baked: [BootEpoch: [Entry]] = [:]
        for (epoch, group) in grouped {
            let entries = Self.bake(
                samples: group.sorted { $0.instant.hostTime.rawValue < $1.instant.hostTime.rawValue },
                blindIntervals: blindIntervals,
                clicks: (clicksByEpoch[epoch] ?? []).map(\.hostTime.rawValue).sorted(),
                tuning: tuning)
            if !entries.isEmpty { baked[epoch] = entries }
        }
        self.byEpoch = baked
    }

    /// The baked entries for an epoch, for a test that wants the whole path.
    public func entries(in epoch: BootEpoch) -> [Entry] { byEpoch[epoch] ?? [] }

    /// The spring's position at `instant`, or `nil` when the path does not cover it — before
    /// the first sample, after the last, or in an epoch with no samples. **`nil` is a real
    /// answer**, and the caller falls back to the lerp; it is never a position.
    public func position(at instant: HostInstant) -> (position: NormalizedPoint, speed: Double)? {
        guard let entry = entry(at: instant) else { return nil }
        return (entry.position, entry.speed)
    }

    /// The whole interpolated entry at `instant`, or `nil` outside the path.
    public func entry(at instant: HostInstant) -> Entry? {
        guard let entries = byEpoch[instant.epoch], let first = entries.first,
              let last = entries.last else { return nil }
        let time = instant.hostTime.rawValue
        guard time >= first.hostTime, time <= last.hostTime else { return nil }
        // First entry strictly after `time`; the one before it is at or before.
        var low = 0, high = entries.count
        while low < high {
            let mid = low + (high - low) / 2
            if entries[mid].hostTime <= time { low = mid + 1 } else { high = mid }
        }
        guard low < entries.count else { return last }
        let a = entries[low - 1], b = entries[low]
        let span = b.hostTime - a.hostTime
        guard span > 0 else { return a }
        let f = Double(time - a.hostTime) / Double(span)
        return Entry(hostTime: time,
                     position: NormalizedPoint(x: a.position.x + (b.position.x - a.position.x) * f,
                                               y: a.position.y + (b.position.y - a.position.y) * f),
                     speed: a.speed + (b.speed - a.speed) * f,
                     velocityX: a.velocityX + (b.velocityX - a.velocityX) * f,
                     velocityY: a.velocityY + (b.velocityY - a.velocityY) * f)
    }

    // MARK: - baking

    private static func bake(samples: [PointerSample], blindIntervals: [BlindInterval],
                             clicks: [Int64], tuning: Tuning) -> [Entry] {
        // Duplicate instants collapse to the LAST written — the same "most recent wins"
        // rule `PointerTrack.lastSample` applies, so the two queries cannot disagree about
        // which of two same-instant samples is the observation.
        var unique: [PointerSample] = []
        unique.reserveCapacity(samples.count)
        for sample in samples {
            if let previous = unique.last,
               previous.instant.hostTime.rawValue == sample.instant.hostTime.rawValue {
                unique[unique.count - 1] = sample
            } else {
                unique.append(sample)
            }
        }
        if tuning.removesShakes {
            unique = Self.withoutShakes(unique, window: tuning.shakeWindow.rawValue,
                                        threshold: tuning.shakeThreshold)
        }
        guard unique.count >= 2, let first = unique.first, let last = unique.last else {
            return []
        }
        let start = first.instant.hostTime.rawValue
        let end = last.instant.hostTime.rawValue
        let stepNanos = step.rawValue
        guard end - start >= stepNanos else { return [] }

        let target = SplineTarget(samples: unique, blindIntervals: blindIntervals,
                                  tension: tuning.splineTension)
        let dt = Double(stepNanos) / 1_000_000_000

        var x = first.position.x, y = first.position.y
        var vx = 0.0, vy = 0.0
        var idleBlend = 0.0
        var lead = 0.0
        var clickIndex = 0

        var entries: [Entry] = []
        entries.reserveCapacity(Int((end - start) / stepNanos) + 3)
        entries.append(Entry(hostTime: start, position: first.position, speed: 0,
                             velocityX: 0, velocityY: 0))

        // The grid runs to the first step AT OR PAST the last sample, so the path covers
        // the last sample's own instant: a grid that stopped short left the final few
        // milliseconds — where a click usually is — to the lerp.
        let lastGrid = start + ((end - start + stepNanos - 1) / stepNanos) * stepNanos
        var time = start + stepNanos
        while time <= lastGrid {
            // The response for THIS step: shortened by speed, and shortened harder inside
            // the window before a click.
            let speed = (vx * vx + vy * vy).squareRoot()
            let normalisedSpeed = min(speed / tuning.adaptiveMaxSpeed, 1)
            var response = tuning.responseSeconds
                * (1 - (1 - tuning.adaptiveMinScale) * normalisedSpeed)
            while clickIndex < clicks.count, clicks[clickIndex] < time { clickIndex += 1 }
            if clickIndex < clicks.count,
               clicks[clickIndex] - time <= tuning.clickStiffenWindow.rawValue {
                response = min(response, tuning.clickResponseSeconds)
            }
            let omega = 2 * Double.pi / response
            let zeta = tuning.dampingRatio

            // Phase lead, eased with a one-pole so a profile switch does not pop the target.
            // **Confined to the connected chain the instant sits in**: a lead that reached
            // across a held gap would move the cursor toward a position BEFORE it was
            // observed — 17 ms of invented anticipation, which on a jump after a silence
            // measured 28 px on the real recording. Inside a chain every position the lead
            // reads was observed; the lead only decides which observed position is drawn.
            let steadyLead = 2 * zeta / omega
            lead += (steadyLead - lead) * 0.12
            let aimed = target.position(at: time, lead: Int64(lead * 1_000_000_000))

            // Idle stabilisation on the RAW target's speed relative to the spring, so a
            // target that stopped lets the spring finish and then holds it there.
            let rawSpeed = ((aimed.x - x) * (aimed.x - x) + (aimed.y - y) * (aimed.y - y))
                .squareRoot() / dt
            if rawSpeed < tuning.idleSpeed {
                idleBlend = min(idleBlend + dt * tuning.idleBlendRate, tuning.idleBlendCap)
            } else {
                idleBlend = 0
            }
            let tx = aimed.x * (1 - idleBlend) + x * idleBlend
            let ty = aimed.y * (1 - idleBlend) + y * idleBlend

            (x, vx) = Spring.step(position: x, velocity: vx, target: tx,
                                  omega: omega, zeta: zeta, dt: dt)
            (y, vy) = Spring.step(position: y, velocity: vy, target: ty,
                                  omega: omega, zeta: zeta, dt: dt)
            // The spring may overshoot the frame by a hair; a cursor drawn off the card is
            // a cursor the person never had.
            x = min(max(x, 0), 1)
            y = min(max(y, 0), 1)
            entries.append(Entry(hostTime: time, position: NormalizedPoint(x: x, y: y),
                                 speed: (vx * vx + vy * vy).squareRoot(),
                                 velocityX: vx, velocityY: vy))
            time += stepNanos
        }
        return entries
    }
}

extension PointerPath {
    /// Walk the samples keeping the last
    /// KEPT one as `prev`; a middle sample whose legs to `prev` and to `next` reverse
    /// direction (negative dot product), both shorter than `threshold`, inside `window`
    /// from `prev` to `next`, is dropped. First and last samples always survive. Blind
    /// intervals are not consulted: a tremor across a blind edge is still a tremor, and
    /// the spline refuses the blind span on its own.
    static func withoutShakes(_ samples: [PointerSample], window: Int64,
                              threshold: Double) -> [PointerSample] {
        guard samples.count >= 3 else { return samples }
        var kept: [PointerSample] = [samples[0]]
        kept.reserveCapacity(samples.count)
        var i = 1
        while i < samples.count - 1 {
            let prev = kept[kept.count - 1], current = samples[i], next = samples[i + 1]
            let span = next.instant.hostTime.rawValue - prev.instant.hostTime.rawValue
            if span <= window {
                let toCurrent = (current.position.x - prev.position.x, current.position.y - prev.position.y)
                let toNext = (next.position.x - current.position.x, next.position.y - current.position.y)
                let reversal = toCurrent.0 * toNext.0 + toCurrent.1 * toNext.1 < 0
                let small = hypot(toCurrent.0, toCurrent.1) < threshold
                    && hypot(toNext.0, toNext.1) < threshold
                if reversal && small { i += 1; continue }
            }
            kept.append(current)
            i += 1
        }
        kept.append(samples[samples.count - 1])
        return kept
    }
}

// MARK: - the spline the spring follows

/// The recorded samples as a continuous target: a time-parameterised cardinal spline between
/// connected neighbours, and a HOLD across anything the lerp would also refuse to cross.
private struct SplineTarget {
    private let samples: [PointerSample]
    private let times: [Int64]
    /// `connected[i]` is whether the span `i → i+1` may be interpolated: narrow enough, and
    /// no blind interval inside it.
    private let connected: [Bool]
    /// `chainEnd[i]` is the host time of the last sample reachable from span `i` through
    /// connected spans — the furthest a phase lead may read. For a span that is itself
    /// held it is the span's own start, so the lead there is nothing.
    private let chainEnd: [Int64]
    private let tension: Double

    init(samples: [PointerSample], blindIntervals: [BlindInterval], tension: Double) {
        self.samples = samples
        self.times = samples.map(\.instant.hostTime.rawValue)
        self.tension = tension
        var connected: [Bool] = []
        connected.reserveCapacity(max(samples.count - 1, 0))
        for i in 0..<max(samples.count - 1, 0) {
            let a = times[i], b = times[i + 1]
            let span = b - a
            var ok = span > 0 && span <= PointerTrack.maxInterpolationGap.rawValue
            if ok {
                ok = !blindIntervals.contains { $0.start.rawValue < b && $0.end.rawValue > a }
            }
            connected.append(ok)
        }
        self.connected = connected
        // Walked backwards so each span reads its successor's answer: O(n) once, rather
        // than a forward walk per integration step.
        var chainEnd = [Int64](repeating: 0, count: connected.count)
        for i in stride(from: connected.count - 1, through: 0, by: -1) {
            if !connected[i] {
                chainEnd[i] = times[i]
            } else if i + 1 < connected.count, connected[i + 1] {
                chainEnd[i] = chainEnd[i + 1]
            } else {
                chainEnd[i] = times[i + 1]
            }
        }
        self.chainEnd = chainEnd
    }

    /// The position `lead` nanoseconds after `time`, never read past the end of the
    /// connected chain `time` sits in — see `chainEnd`.
    func position(at time: Int64, lead: Int64) -> NormalizedPoint {
        let i = spanIndex(atOrBefore: time)
        guard i >= 0, i < chainEnd.count else { return position(at: time) }
        return position(at: min(time + max(lead, 0), max(chainEnd[i], time)))
    }

    /// Index of the last sample at or before `time`, or −1 before the first.
    private func spanIndex(atOrBefore time: Int64) -> Int {
        var low = 0, high = times.count
        while low < high {
            let mid = low + (high - low) / 2
            if times[mid] <= time { low = mid + 1 } else { high = mid }
        }
        return low - 1
    }

    func position(at time: Int64) -> NormalizedPoint {
        let i = spanIndex(atOrBefore: time)
        guard i >= 0 else { return samples[0].position }
        guard i + 1 < samples.count, connected[i] else { return samples[i].position }

        let p1 = samples[i].position, p2 = samples[i + 1].position
        let t1 = Double(times[i]), t2 = Double(times[i + 1])
        let u = (Double(time) - t1) / (t2 - t1)
        // Finite-difference tangents in TIME. A neighbour that is not connected to its
        // span is reflected instead of read, so a held gap does not bend the arc toward a
        // position the cursor was not travelling from.
        let m1 = tangent(at: i)
        let m2 = tangent(at: i + 1)
        let h = t2 - t1
        return hermite(p1: p1, m1: (m1.x * h, m1.y * h), p2: p2, m2: (m2.x * h, m2.y * h), u: u)
    }

    /// Velocity (normalised units per nanosecond) at sample `k`, from its connected
    /// neighbours; one-sided when only one side is connected, zero when neither is.
    private func tangent(at k: Int) -> (x: Double, y: Double) {
        let scale = 1 - tension
        let p = samples[k].position
        let t = Double(times[k])
        let hasPrevious = k > 0 && connected[k - 1]
        let hasNext = k + 1 < samples.count && connected[k]
        switch (hasPrevious, hasNext) {
        case (true, true):
            let a = samples[k - 1].position, b = samples[k + 1].position
            let span = Double(times[k + 1]) - Double(times[k - 1])
            return ((b.x - a.x) / span * scale, (b.y - a.y) / span * scale)
        case (true, false):
            let a = samples[k - 1].position
            let span = t - Double(times[k - 1])
            return ((p.x - a.x) / span * scale, (p.y - a.y) / span * scale)
        case (false, true):
            let b = samples[k + 1].position
            let span = Double(times[k + 1]) - t
            return ((b.x - p.x) / span * scale, (b.y - p.y) / span * scale)
        case (false, false):
            return (0, 0)
        }
    }

    private func hermite(p1: NormalizedPoint, m1: (x: Double, y: Double),
                         p2: NormalizedPoint, m2: (x: Double, y: Double),
                         u: Double) -> NormalizedPoint {
        let u2 = u * u, u3 = u2 * u
        let h00 = 2 * u3 - 3 * u2 + 1
        let h10 = u3 - 2 * u2 + u
        let h01 = -2 * u3 + 3 * u2
        let h11 = u3 - u2
        return NormalizedPoint(
            x: h00 * p1.x + h10 * m1.x + h01 * p2.x + h11 * m2.x,
            y: h00 * p1.y + h10 * m1.y + h01 * p2.y + h11 * m2.y)
    }
}

// MARK: - the spring

/// One analytic step of a damped harmonic oscillator with the target held constant across the
/// step. **Analytic, not Euler**, because the closed form is exact at any `dt` and cannot
/// blow up when a stiff click profile meets a coarse step.
enum Spring {
    // Removed from the published history: this step followed another program's code line for
    // line. The present one was written from the differential equation.
    static func step(position x0: Double, velocity v0: Double, target: Double,
                     omega: Double, zeta: Double, dt: Double) -> (Double, Double) {
        fatalError("removed from the published history")
    }
}
