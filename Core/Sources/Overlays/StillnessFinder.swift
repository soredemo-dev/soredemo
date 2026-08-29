import Foundation
import Timeline

/// Where the picture does not change — the visual half of what `SilenceFinder` does for sound.
///
/// A screen recording that holds the same frame for eight seconds is dead air, and finding those
/// stretches by scrubbing is the job this removes. `spans(changes:sliceSeconds:settings:)` takes
/// one number per slice — how much of the frame changed — and returns the stretches worth cutting;
/// `removing(_:from:)` cuts them.
///
/// **This owns "where is nothing happening" and nothing else.** It does not decide what changed,
/// where, or whether it mattered: the caller measures and this reads the series. That is the same
/// division `SilenceFinder` has with the waveform, and for the same reason — one owner per
/// question.
///
/// See `docs/design/finding-dead-air.md` for what was measured: why a frame difference and not
/// optical flow, what the threshold has to sit between, and why the number turns out not to be a
/// sensitive one.
public enum StillnessFinder {
    public struct Settings: Hashable, Sendable, Codable {
        /// The fraction of the frame that must change for a slice to count as moving, 0…1.
        ///
        /// **0.0005 — five hundredths of one per cent — and it sits between two measured
        /// numbers.** A still frame measures 0.000%: on 269 slices of a genuinely idle recording
        /// not one pixel changed by more than 8/255. A cursor moving across a 1512×982 frame
        /// changes about 0.15% of it. The threshold has to be below the cursor, or a recording
        /// where the only thing happening is somebody moving the pointer would be cut — and the
        /// cut would make the pointer jump.
        public var changeThreshold: Double

        /// How long a still stretch must be before it is worth cutting.
        ///
        /// **Two seconds, which is longer than the sound equivalent and deliberately so.** A
        /// second of silence is a pause; a second of a held picture is somebody reading, and it
        /// is the normal state of a demo rather than a fault. Dead air starts where a viewer
        /// begins to wonder whether the video has stopped.
        public var minimumSeconds: Double

        /// How much of each end of a still stretch is given back.
        ///
        /// **Larger than the sound equivalent, for a reason that is about the eye.** A cut that
        /// lands on the exact frame where motion resumes clips the start of the motion, and the
        /// result reads as a dropped frame rather than as an edit. Sound has no equivalent
        /// problem because a waveform's onset is audible before it is loud.
        public var paddingSeconds: Double

        public static let `default` = Settings(changeThreshold: 0.0005, minimumSeconds: 2,
                                               paddingSeconds: 0.3)

        public init(changeThreshold: Double, minimumSeconds: Double, paddingSeconds: Double) {
            // Clamped rather than trapped: these reach here from sliders and from decoders.
            self.changeThreshold = min(max(changeThreshold.isFinite ? changeThreshold : 0.0005,
                                           0), 1)
            self.minimumSeconds = max(minimumSeconds.isFinite ? minimumSeconds : 2, 0)
            self.paddingSeconds = max(paddingSeconds.isFinite ? paddingSeconds : 0.3, 0)
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                changeThreshold: try container.decodeIfPresent(Double.self,
                                                               forKey: .changeThreshold) ?? 0.0005,
                minimumSeconds: try container.decodeIfPresent(Double.self,
                                                              forKey: .minimumSeconds) ?? 2,
                paddingSeconds: try container.decodeIfPresent(Double.self,
                                                              forKey: .paddingSeconds) ?? 0.3)
        }

        private enum CodingKeys: String, CodingKey {
            case changeThreshold, minimumSeconds, paddingSeconds
        }
    }

    /// A stretch of the recording where nothing moved, in the recording's own time.
    public struct Span: Hashable, Sendable {
        public let start: Nanoseconds
        public let end: Nanoseconds

        public init(start: Nanoseconds, end: Nanoseconds) {
            self.start = start
            self.end = end
        }

        public var duration: Nanoseconds {
            Nanoseconds(max(end.rawValue - start.rawValue, 0))
        }
    }

    /// The stretches worth cutting, from one change measure per slice.
    ///
    /// `changes[i]` is the fraction of the frame that changed during slice `i`.
    ///
    /// **Padding shrinks a span from both ends and can erase it**, which is the correct outcome: a
    /// stretch only just longer than the minimum, once three tenths of a second is given back at
    /// each end, is not a stretch worth cutting.
    public static func spans(changes: [Double], sliceSeconds: Double,
                             settings: Settings = .default) -> [Span] {
        guard sliceSeconds > 0, !changes.isEmpty else { return [] }
        let minimumSlices = Int((settings.minimumSeconds / sliceSeconds).rounded(.up))
        guard minimumSlices > 0 else { return [] }

        var spans: [Span] = []
        var runStart: Int?
        for (index, change) in changes.enumerated() {
            if change.isFinite, change <= settings.changeThreshold {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                append(&spans, from: start, to: index, sliceSeconds: sliceSeconds,
                       minimumSlices: minimumSlices, settings: settings)
                runStart = nil
            }
        }
        // **A recording that ends still has an open run**, and it is the commonest one there is:
        // people stop moving before they stop recording, because stopping is done from a menu.
        if let start = runStart {
            append(&spans, from: start, to: changes.count, sliceSeconds: sliceSeconds,
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
    /// **Removed back to front**, for `SilenceFinder.removing`'s reason: the ranges are in source
    /// time so their order would not matter, but the clip identities the timeline mints as it
    /// splits do, and cutting from the end leaves the earlier clips' ids untouched. A person's
    /// selection survives the operation.
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
