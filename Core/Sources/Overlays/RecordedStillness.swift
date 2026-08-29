import Foundation
import Project
import Timeline

/// Stillness read from what the recorder already knew, instead of decoded back
/// out of the finished file.
///
/// `StillnessReader` answers the same question by decoding every frame and
/// differencing it — correct, and it costs a pass over the whole recording.
/// `StillInterval` is ScreenCaptureKit's own statement that it drew nothing,
/// written down at capture time where reading it costs nothing at all. This
/// turns those statements into the same `StillnessFinder.Span`s the pixel path
/// produces, so everything downstream is unchanged.
///
/// The two signals do not always agree, and the direction of the disagreement is
/// what makes this one safe to prefer. A one-pixel change redraws the frame, so
/// ScreenCaptureKit calls it `.complete` where the pixel rule — which asks
/// whether five hundredths of one per cent of the frame moved — still calls the
/// picture still. This path therefore finds *fewer* stretches than the decode,
/// never different ones: it can miss a cut, and cannot invent one.
public enum RecordedStillness {
    /// Why a recorded interval produced no span. A value rather than an absence,
    /// so a caller can say which of these happened instead of reporting that
    /// nothing was found.
    public enum Refusal: Hashable, Sendable {
        /// Neither edge could be placed in the recording's content: the interval
        /// falls in a gap between segments, or in another boot epoch.
        case itDoesNotLandInTheContent
        /// The callbacks are too sparse to be stillness. Carries the measured
        /// rate so the judgement is checkable against the number that produced it.
        case theStreamHadStalled(callbacksPerSecond: Double)
        /// Shorter than `Settings.minimumSeconds`, or erased by the padding given
        /// back at each end. Carries what was measured before the refusal.
        case tooShortToCut(Nanoseconds)
    }

    /// The spans, and every interval that produced none. Both, because a caller
    /// showing "no dead air found" over four refusals of a stalled stream is
    /// showing the wrong sentence.
    public struct Outcome: Sendable {
        public let spans: [StillnessFinder.Span]
        public let refused: [(interval: StillInterval, refusal: Refusal)]

        public init(spans: [StillnessFinder.Span],
                    refused: [(interval: StillInterval, refusal: Refusal)]) {
            self.spans = spans
            self.refused = refused
        }
    }

    /// Below this many idle callbacks a second, the run is a stream that stopped
    /// delivering rather than a picture that stopped changing.
    ///
    /// **Ten, which is a third of the slowest rate this app records at.** The
    /// three offered rates are 30, 60 and 120 fps, and ScreenCaptureKit delivers
    /// idle callbacks at the configured rate — measured, a static window gave
    /// 1210 idle callbacks over twenty seconds against a 60 fps configuration.
    /// A floor of ten therefore sits far below anything a working stream
    /// produces and far above a stalled one, and it needs no knowledge of which
    /// rate a given recording used — which this module could not have anyway,
    /// since `CaptureFrameRate` lives in a target it does not depend on.
    public static let slowestCallbackRateThatIsStillness = 10.0

    /// The stretches worth cutting, from the recorder's own idle intervals.
    ///
    /// The order of the tests mirrors `StillnessFinder.spans(changes:...)`
    /// exactly — minimum length first, then padding, which may erase the span —
    /// because two paths answering the same question with different rules would
    /// give a person two different answers for one recording.
    public static func spans(recorded intervals: [StillInterval], in table: SegmentTable,
                             settings: StillnessFinder.Settings = .default) -> Outcome {
        var spans: [StillnessFinder.Span] = []
        var refused: [(interval: StillInterval, refusal: Refusal)] = []

        for interval in intervals {
            let range = interval.interval
            let startInstant = HostInstant(epoch: range.epoch, hostTime: range.start)
            // The end is half-open, so the instant one nanosecond inside it is
            // what has to land in the content; the end itself may be exactly a
            // segment's boundary, which `HostRange.contains` correctly excludes.
            let lastInstant = HostInstant(epoch: range.epoch,
                                          hostTime: Nanoseconds(max(range.start.rawValue,
                                                                    range.end.rawValue - 1)))
            // Both edges must land in the SAME segment. The recorder closes an
            // open run when a segment closes, so an interval spanning a pause is
            // one it cannot have produced — the log was edited, or something
            // upstream is wrong. Mapped through `contentTime` it would still
            // yield a plausible range, because a pause occupies no content at
            // all, and cutting on that range would cut across a boundary nothing
            // measured. A refusal is the honest answer to a record that should
            // not exist.
            guard let segment = table.segments.first(where: { $0.hostRange.contains(startInstant) }),
                  segment.hostRange.contains(lastInstant),
                  let contentStart = table.contentTime(of: startInstant),
                  let contentLast = table.contentTime(of: lastInstant),
                  contentLast.rawValue >= contentStart.rawValue else {
                refused.append((interval, .itDoesNotLandInTheContent))
                continue
            }

            let seconds = Double(range.duration.rawValue) / 1_000_000_000
            let rate = seconds > 0 ? Double(interval.idleFrames) / seconds : .infinity
            guard rate >= slowestCallbackRateThatIsStillness else {
                refused.append((interval, .theStreamHadStalled(callbacksPerSecond: rate)))
                continue
            }

            // Measured in CONTENT time rather than from the interval's own
            // duration. With the same-segment guard above the two agree today,
            // and they are still not the same quantity: one is a span of the
            // wall clock, the other a span of the finished picture, and the cut
            // is made on the picture.
            let contentEnd = contentLast + Nanoseconds(1)
            let length = Nanoseconds(contentEnd.rawValue - contentStart.rawValue)
            guard Double(length.rawValue) / 1_000_000_000 >= settings.minimumSeconds else {
                refused.append((interval, .tooShortToCut(length)))
                continue
            }

            let padding = Int64(settings.paddingSeconds * 1_000_000_000)
            let paddedStart = contentStart.rawValue + padding
            let paddedEnd = contentEnd.rawValue - padding
            guard paddedEnd > paddedStart else {
                refused.append((interval, .tooShortToCut(length)))
                continue
            }
            spans.append(StillnessFinder.Span(start: Nanoseconds(paddedStart),
                                              end: Nanoseconds(paddedEnd)))
        }
        return Outcome(spans: spans.sorted { $0.start.rawValue < $1.start.rawValue },
                       refused: refused)
    }
}
