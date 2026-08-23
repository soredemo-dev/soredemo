import Foundation
import Timeline

/// Finding the parts of a recording where nobody is saying anything.
///
/// **The single edit that makes a demo watchable.** A recorded walkthrough is mostly pauses —
/// waiting for a page, finding a menu, thinking of the next sentence — and cutting them by hand
/// means scrubbing the whole thing. an Electron recorder and a native editor both ship this; a native editor calls the
/// result a `WordCutPlanner`, an Electron recorder a dead-air removal.
///
/// **It reads the envelope the waveform is drawn from.** No second analysis: the numbers on
/// screen and the numbers this cuts by are the same numbers, so a person looking at the strip
/// can see why a span was chosen. A separate detector would be a second opinion nobody asked for
/// and could not check.
public enum SilenceFinder {
    /// What counts as quiet, and how quiet a stretch has to be before it is worth removing.
    public struct Settings: Hashable, Sendable, Codable {
        /// Peaks at or below this are silence, 0…1. **Not zero**: a room has a noise floor, a
        /// microphone has a hiss, and a threshold of zero finds nothing on any real recording.
        public var threshold: Double
        /// How long a quiet stretch must last to be cut. **Below about half a second a pause is
        /// speech** — the gap between two words, the breath before a sentence — and removing it
        /// makes narration sound spliced rather than tightened.
        public var minimumSeconds: Double
        /// Kept at each end of a cut, so a word is not clipped by a threshold crossing that
        /// happened a few milliseconds early.
        public var paddingSeconds: Double

        public static let `default` = Settings(threshold: 0.04, minimumSeconds: 0.7,
                                               paddingSeconds: 0.12)

        public init(threshold: Double, minimumSeconds: Double, paddingSeconds: Double) {
            self.threshold = min(max(threshold, 0.005), 0.5)
            self.minimumSeconds = min(max(minimumSeconds, 0.2), 10)
            self.paddingSeconds = min(max(paddingSeconds, 0), 1)
        }
    }

    /// One stretch of silence, in the recording's own time.
    public struct Span: Hashable, Sendable {
        public let start: Nanoseconds
        public let end: Nanoseconds

        public init(start: Nanoseconds, end: Nanoseconds) {
            self.start = start
            self.end = end
        }

        public var duration: Nanoseconds {
            Nanoseconds(max(0, end.rawValue - start.rawValue))
        }
    }

    /// The silent stretches in `peaks`, each slice covering `sliceSeconds`.
    ///
    /// **Padding shrinks a span from both ends and can erase it**, which is the correct outcome:
    /// a stretch only just longer than the minimum, once a tenth of a second is given back at
    /// each end, is not a stretch worth cutting.
    public static func spans(peaks: [Float], sliceSeconds: Double,
                             settings: Settings = .default) -> [Span] {
        guard sliceSeconds > 0, !peaks.isEmpty else { return [] }
        let minimumSlices = Int((settings.minimumSeconds / sliceSeconds).rounded(.up))
        guard minimumSlices > 0 else { return [] }

        var spans: [Span] = []
        var runStart: Int?
        for (index, peak) in peaks.enumerated() {
            if Double(peak) <= settings.threshold {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                append(&spans, from: start, to: index, sliceSeconds: sliceSeconds,
                       minimumSlices: minimumSlices, settings: settings)
                runStart = nil
            }
        }
        // A recording that ends in silence has an open run at the end — the commonest one there
        // is, because a person stops talking before they stop recording.
        if let start = runStart {
            append(&spans, from: start, to: peaks.count, sliceSeconds: sliceSeconds,
                   minimumSlices: minimumSlices, settings: settings)
        }
        return spans
    }

    private static func append(_ spans: inout [Span], from first: Int, to end: Int,
                               sliceSeconds: Double, minimumSlices: Int, settings: Settings) {
        guard end - first >= minimumSlices else { return }
        let startSeconds = Double(first) * sliceSeconds + settings.paddingSeconds
        let endSeconds = Double(end) * sliceSeconds - settings.paddingSeconds
        guard endSeconds > startSeconds else { return }
        spans.append(Span(start: Nanoseconds(Int64(startSeconds * 1_000_000_000)),
                          end: Nanoseconds(Int64(endSeconds * 1_000_000_000))))
    }

    /// `timeline` with every span removed.
    ///
    /// **Removed back to front.** `EditTimeline.removing(sourceRange:)` takes SOURCE times and
    /// the spans are in source time too, so the order would not matter for the ranges — but it
    /// does for the clip identities the timeline mints as it splits, and cutting from the end
    /// leaves the earlier clips' ids untouched. A person's selection survives the operation.
    public static func removing(_ spans: [Span], from timeline: EditTimeline) -> EditTimeline {
        spans.sorted { $0.start.rawValue > $1.start.rawValue }
            .reduce(timeline) { result, span in
                guard span.end.rawValue > span.start.rawValue else { return result }
                return result.removing(sourceRange: span.start.rawValue..<span.end.rawValue)
            }
    }

    /// How much time a set of spans would remove.
    public static func total(_ spans: [Span]) -> Nanoseconds {
        Nanoseconds(spans.reduce(0) { $0 + $1.duration.rawValue })
    }
}
