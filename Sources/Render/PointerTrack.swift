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

    public init(samples: [PointerSample], blindIntervals: [BlindInterval],
                overrides: [CursorOverride]) {
        self.samples = samples.sorted { $0.instant.hostTime.rawValue < $1.instant.hostTime.rawValue }
        self.blindIntervals = blindIntervals
        self.overrides = overrides
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
        var latest: PointerSample?
        for sample in samples
        where sample.instant.epoch == instant.epoch
            && sample.instant.hostTime.rawValue <= time.rawValue {
            latest = sample
        }
        guard let latest else { return .noObservationYet }
        return .drawn(latest.position, shape: latest.shape, hotspot: latest.hotspot)
    }

    /// The widest bracket the lerp will cross. A moving pointer at 120 Hz samples ~8 ms
    /// apart; a STATIONARY one emits nothing at all, so a wide gap between brackets means
    /// the pointer sat still and lerping across it would invent a slow drift the user
    /// never made. 50 ms is comfortably above motion cadence and far below any pause a
    /// person would read as stillness. Public because `RecordedPointerPositionTests`
    /// re-derives the rule independently from the fixture's bytes and must agree on the
    /// threshold to disagree meaningfully about anything else.
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
        var before: PointerSample?
        var after: PointerSample?
        for sample in samples where sample.instant.epoch == instant.epoch {
            if sample.instant.hostTime.rawValue <= time.rawValue {
                before = sample
            } else {
                after = sample
                break
            }
        }
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
