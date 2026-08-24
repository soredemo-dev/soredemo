import Foundation
import Geometry
import Project
import Timeline

/// What the pointer track says about one output time. **Four cases, not an optional**, because an
/// optional collapses three different silences into one and a caller cannot tell them apart:
/// a gap that was measured, a reviewer's decision, and time before anything was ever seen.
public enum PointerReading: Hashable, Sendable {
    /// `shape` rides with the position because they are one observation: the shape the
    /// system cursor had AT the sample whose position is being drawn. `nil` is
    /// "unrecorded" (see `PointerShape`); the renderer's fallback for it is the arrow.
    case drawn(NormalizedPoint, shape: PointerShape?, hotspot: NormalizedPoint?)
    case blind(BlindInterval)
    case suppressedByReviewer
    case noObservationYet
}

public struct PointerTrack: Sendable {
    private let samples: [PointerSample]      // sorted by instant
    private let blindIntervals: [BlindInterval]
    private let overrides: [CursorOverride]
    /// The presentation path, baked once from the same samples — see `PointerPath`.
    private let path: PointerPath
    /// Host times, per epoch, of every sample that MOVED — differed from the sample before
    /// it by more than `motionThreshold`. What the idle fade is measured against: a
    /// `PointerSampler` stream of a resting pointer is not motion, and neither is a
    /// sub-pixel wobble.
    private let motionInstants: [BootEpoch: [Int64]]

    /// `clickInstants` are button-DOWN instants and feed only the presentation path, where
    /// the spring stiffens into a click; neither review query reads them. Defaulted so the
    /// two-argument construction every test and the review UI use is unchanged.
    public init(samples: [PointerSample], blindIntervals: [BlindInterval],
                overrides: [CursorOverride], clickInstants: [HostInstant] = [],
                tuning: PointerPath.Tuning = .default) {
        self.samples = samples.sorted { $0.instant.hostTime.rawValue < $1.instant.hostTime.rawValue }
        self.blindIntervals = blindIntervals
        self.overrides = overrides
        self.path = PointerPath(samples: self.samples, blindIntervals: blindIntervals,
                                clickInstants: clickInstants, tuning: tuning)
        var motion: [BootEpoch: [Int64]] = [:]
        var previous: [BootEpoch: NormalizedPoint] = [:]
        for sample in self.samples {
            let epoch = sample.instant.epoch
            defer { previous[epoch] = sample.position }
            guard let last = previous[epoch] else { continue }
            if hypot(sample.position.x - last.x, sample.position.y - last.y) > Self.motionThreshold {
                motion[epoch, default: []].append(sample.instant.hostTime.rawValue)
            }
        }
        self.motionInstants = motion
    }

    /// A move smaller than this is stillness for the idle fade: half a pixel of a 2160-tall
    /// recording, the finest a tap reports on a Retina display.
    public static let motionThreshold: Double = 0.5 / 2160

    /// How long the idle fade takes, out and in. a Rust recorder fades over a similar span; Screen
    /// Studio's is not published. **Uncalibrated.**
    public static let idleFadeSeconds: Double = 0.3

    /// **The cursor's opacity under the idle rule: 1 while it has moved within `hideAfter`,
    /// fading to 0 over `idleFadeSeconds` after that, and back to 1 over the same span BEFORE
    /// the next move** — the look-ahead is a Rust recorder's `CURSOR_IDLE_RESUME_LOOKAHEAD`, and it is
    /// what stops a hidden cursor popping into existence already moving. A track with no
    /// motion at all is drawn: a pointer that never moved is not idle, it is where it is.
    public func idleOpacity(at instant: HostInstant, hideAfter delay: Double) -> Double {
        guard let moves = motionInstants[instant.epoch], !moves.isEmpty else { return 1 }
        let time = instant.hostTime.rawValue
        // First move strictly after `time`.
        var low = 0, high = moves.count
        while low < high {
            let mid = low + (high - low) / 2
            if moves[mid] <= time { low = mid + 1 } else { high = mid }
        }
        let fade = Self.idleFadeSeconds
        var fadeIn = 0.0
        if low < moves.count {
            let untilNext = Double(moves[low] - time) / 1e9
            if untilNext <= fade { fadeIn = 1 - untilNext / fade }
        }
        guard low > 0 else { return 1 }   // before the first move: not yet idle
        let sinceLast = Double(time - moves[low - 1]) / 1e9
        let fadeOut = sinceLast <= delay ? 1.0 : max(0, 1 - (sinceLast - delay) / fade)
        return max(fadeOut, fadeIn)
    }

    /// The presentation path's velocity at `instant`, normalised units per second per axis,
    /// or `nil` where the path has no answer — what the tilt is computed from.
    public func presentedVelocity(at instant: HostInstant) -> (x: Double, y: Double)? {
        guard let entry = path.entry(at: instant) else { return nil }
        return (entry.velocityX, entry.velocityY)
    }

    /// The reviewer's decision wins, then a measured gap, then the most recent sample at or before
    /// `instant`. **No interpolation here, ever** — this is the REVIEW path's truth, and footage
    /// that looks fine is what deletes the signal saying someone should look. The rendering path
    /// smooths through `smoothedPosition(at:)` below, and the split of one track into two queries
    /// IS the resolution of that tension (recorder-parity design, 2026-08-19): presentation and
    /// diagnosis are different outputs, and only presentation may be gentle.
    ///
    /// `HostInstant`, not a bare `Nanoseconds` — the argument's type is what makes `1a98402`'s
    /// class (querying an absolute-clock track with a composition-relative number) a compile
    /// error rather than a silent every-frame miss. `BlindInterval` carries no epoch yet, so the
    /// blind comparison is by `hostTime` alone — a persisted-format change deferred on its own
    /// migration argument; see `docs/design/2026-08-12-clock-domain-types.md`.
    public func position(at instant: HostInstant) -> PointerReading {
        let time = instant.hostTime
        // Epoch first, then interval: two boots produce overlapping host times, so an
        // override or sample from another session would otherwise match by coincidence.
        if overrides.contains(where: { $0.epoch == instant.epoch && $0.contains(time) }) {
            return .suppressedByReviewer
        }
        if let interval = blindIntervals.first(where: { $0.contains(time) }) {
            return .blind(interval)
        }
        guard let latest = lastSample(atOrBefore: time, epoch: instant.epoch)
        else { return .noObservationYet }
        return .drawn(latest.position, shape: latest.shape, hotspot: latest.hotspot)
    }

    /// **Why this is a binary search and not the `for … where` it replaced.** `samples` is
    /// sorted in `init`, and both queries below run once per rendered frame. The linear
    /// version had no `break`, so it walked the WHOLE array every call, and
    /// `smoothedPosition` walked it twice — once itself and once through `position(at:)`.
    /// A three-minute recording sampled at 120 Hz is ~21,600 samples; exported at 60 fps
    /// that is 10,800 frames, so ~470 million iterations for one export. That cost is
    /// invisible in the tests, whose tracks hold a handful of samples, and is exactly the
    /// stutter a real recording shows. The array is sorted, so the scan was never needed.
    ///
    /// `upperBound` is the count of samples whose host time is `<= time`; the last one is
    /// at `upperBound - 1`. The walk back from there exists only because two boots produce
    /// overlapping host times: sorting is by host time alone, so a matching-epoch sample
    /// can sit behind one from another session. In a single-session recording — every real
    /// one — the first candidate matches and the walk does not run.
    private func lastSample(atOrBefore time: Nanoseconds, epoch: BootEpoch) -> PointerSample? {
        var index = upperBound(time)
        while index > 0 {
            index -= 1
            if samples[index].instant.epoch == epoch { return samples[index] }
        }
        return nil
    }

    /// The first sample strictly after `time` in `epoch`. The forward twin of the above,
    /// and it skips foreign epochs for the same reason.
    private func firstSample(after time: Nanoseconds, epoch: BootEpoch) -> PointerSample? {
        var index = upperBound(time)
        while index < samples.count {
            if samples[index].instant.epoch == epoch { return samples[index] }
            index += 1
        }
        return nil
    }

    /// Number of samples with host time `<= time`. Half-open `[low, high)`, so `low`
    /// lands on the first sample strictly after `time` and is the count of those at or
    /// before it. `low + (high - low) / 2` rather than `(low + high) / 2`: the operands are
    /// `Int` and the sum of two large indices is the classic overflow in this loop.
    private func upperBound(_ time: Nanoseconds) -> Int {
        var low = 0
        var high = samples.count
        while low < high {
            let mid = low + (high - low) / 2
            if samples[mid].instant.hostTime.rawValue <= time.rawValue {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    /// The widest bracket the lerp will cross. 50 ms is comfortably above motion cadence
    /// and far below any pause a person would read as stillness. Public because
    /// `RecordedPointerPositionTests` re-derives the rule independently from the fixture's
    /// bytes and must agree on the threshold to disagree meaningfully about anything else.
    ///
    /// **What a wide gap means changed when `PointerSampler` was added, and the threshold
    /// did not.** It used to mean "the pointer sat still", because the tap emitted only on
    /// motion; lerping across such a gap would have invented a slow drift the user never
    /// made. The capture side now puts a 60 Hz floor under the track, so a still pointer
    /// emits repeated identical positions and a gap wider than 50 ms no longer means
    /// stillness — it means the recorder itself was not sampling. That is a stronger reason
    /// to refuse, not a weaker one, so the rule stands: interpolating across a span nothing
    /// observed is exactly the invented motion this refuses. Tracks recorded before the
    /// sampler existed keep their old meaning and the same correct treatment.
    public static let maxInterpolationGap = Nanoseconds(50_000_000)

    /// The RENDERING path's position: linearly interpolated between the bracketing samples,
    /// so a 24 fps composition of a 120 Hz track does not stutter — with three refusals,
    /// each of which falls back to the stepwise reading rather than inventing motion:
    ///
    /// * **a bracket gap past `maxInterpolationGap`** — the pointer sat still, and a lerp
    ///   would drift it;
    /// * **a blind interval anywhere between the brackets** — motion invented across a span
    ///   the tap could not see is the "looks fine" the review path's rule refuses, and the
    ///   rendering path does not get to reintroduce it;
    /// * **no bracket on one side** — the track's edges have nothing to interpolate toward.
    ///
    /// Overrides and blindness AT the instant keep exactly `position(at:)`'s precedence.
    /// The shape is the earlier bracket's: shapes are identities and do not blend.
    public func smoothedPosition(at instant: HostInstant) -> PointerReading {
        let stepwise = position(at: instant)
        guard case .drawn(let heldPosition, let heldShape, let heldHotspot) = stepwise
        else { return stepwise }

        let time = instant.hostTime
        let before = lastSample(atOrBefore: time, epoch: instant.epoch)
        let after = firstSample(after: time, epoch: instant.epoch)
        guard let a = before, let b = after else {
            return .drawn(heldPosition, shape: heldShape, hotspot: heldHotspot)
        }
        let span = b.instant.hostTime.rawValue - a.instant.hostTime.rawValue
        guard span > 0, span <= Self.maxInterpolationGap.rawValue else {
            return .drawn(heldPosition, shape: heldShape, hotspot: heldHotspot)
        }
        let crossesBlindness = blindIntervals.contains {
            $0.start.rawValue < b.instant.hostTime.rawValue
                && $0.end.rawValue > a.instant.hostTime.rawValue
        }
        guard !crossesBlindness else {
            return .drawn(heldPosition, shape: heldShape, hotspot: heldHotspot)
        }

        let fraction = Double(time.rawValue - a.instant.hostTime.rawValue) / Double(span)
        return .drawn(NormalizedPoint(x: a.position.x + (b.position.x - a.position.x) * fraction,
                                      y: a.position.y + (b.position.y - a.position.y) * fraction),
                      shape: a.shape, hotspot: a.hotspot)
    }

    /// **The PRESENTATION path's position: the spring-followed cursor, with the lerp as its
    /// floor.** Three queries now, one per consumer, and the order is the design:
    ///
    /// * `position(at:)` — the review path. Stepwise, never gentle, so a gap stays visible.
    /// * `smoothedPosition(at:)` — the lerp between brackets: the geometric truth between two
    ///   observations, with three named refusals.
    /// * this — what a viewer sees. `PointerPath` resamples the observations through a spline
    ///   and follows them with a spring, which is what removes the hand from the motion
    ///   without removing the motion. Wherever the path has no answer — before its first
    ///   sample, after its last, a track too short to bake — the lerp answers instead, so
    ///   the presentation is never LESS than the lerp was.
    ///
    /// Overrides and blindness AT the instant keep exactly `position(at:)`'s precedence: the
    /// spring is consulted only once the stepwise reading is `.drawn`. Shape and hotspot are
    /// the stepwise sample's — identities, and they do not blend.
    public func presentedPosition(at instant: HostInstant) -> PointerReading {
        let smoothed = smoothedPosition(at: instant)
        guard case .drawn(_, let shape, let hotspot) = smoothed,
              let followed = path.position(at: instant) else { return smoothed }
        return .drawn(followed.position, shape: shape, hotspot: hotspot)
    }

    /// The presentation path's own speed at `instant`, normalised units per second, or `nil`
    /// where it has no answer. For a renderer that keys an effect off motion.
    public func presentedSpeed(at instant: HostInstant) -> Double? {
        path.position(at: instant)?.speed
    }

    /// The share of `span` covered by blind intervals. Clamped to the span, so an interval that
    /// starts before it or ends after it contributes only its overlap.
    public func blindFraction(over span: Range<Nanoseconds>) -> Double {
        let total = Double(span.upperBound.rawValue - span.lowerBound.rawValue)
        guard total > 0 else { return 0 }
        var blind = 0.0
        for interval in blindIntervals {
            let lower = max(interval.start.rawValue, span.lowerBound.rawValue)
            let upper = min(interval.end.rawValue, span.upperBound.rawValue)
            if upper > lower { blind += Double(upper - lower) }
        }
        return blind / total
    }

    /// Every interval, for the review UI. **All of them, unconditionally** — the threshold at which
    /// a recording is marked has to be chosen against a real recording, and until that number
    /// exists "no threshold yet" must not become "no behaviour yet". Ship loud, tune down later.
    public var intervalsToSurface: [BlindInterval] { blindIntervals }
}
