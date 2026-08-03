import Foundation
import Geometry
import Project
import Timeline

/// What the pointer track says about one output time. **Four cases, not an optional**, because an
/// optional collapses three different silences into one and a caller cannot tell them apart:
/// a gap that was measured, a reviewer's decision, and time before anything was ever seen.
public enum PointerReading: Hashable, Sendable {
    case drawn(NormalizedPoint)
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
    /// `time`. **No interpolation and no hold-last-known across a gap**: both produce footage that
    /// looks fine, and looking fine is what deletes the signal saying someone should look.
    public func position(at time: Nanoseconds) -> PointerReading {
        if overrides.contains(where: { $0.contains(time) }) { return .suppressedByReviewer }
        if let interval = blindIntervals.first(where: { $0.contains(time) }) {
            return .blind(interval)
        }
        var latest: PointerSample?
        for sample in samples where sample.instant.hostTime.rawValue <= time.rawValue {
            latest = sample
        }
        guard let latest else { return .noObservationYet }
        return .drawn(latest.position)
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
