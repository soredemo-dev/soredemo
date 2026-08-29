import Foundation
import Overlays
import Project

/// Reads the recorder's own idle intervals back out of a package's observation
/// logs.
///
/// A focused reader rather than another case in `StageCompositor`'s dispatch,
/// for `FramingPlanReader`'s reason: the compositor draws frames and has no use
/// for stillness, and a switch that grows a case per consumer is a switch every
/// consumer has to be read to understand.
public enum RecordedStillnessReader {
    /// Whether a recording carries the recorder's own stillness at all, and what
    /// it carries. Three cases, not two: "never still" and "made before the
    /// recorder wrote this down" are different facts, and only the second is a
    /// reason to spend a decode of the whole recording.
    ///
    /// The trailer is what tells them apart. `CaptureSession` declares the
    /// `still` kind unconditionally, so every log written since carries
    /// `still: 0` in `recordCounts` even when nothing was ever still — and a log
    /// written before carries no such key at all. That is exactly the difference
    /// `ObservationWriter.declareRecordKind` exists to preserve.
    public enum Outcome: Sendable, Equatable {
        /// The log carried idle intervals. May still yield no cuttable stretches
        /// — that is `RecordedStillness`'s judgement, not this one's.
        case recorded([StillInterval])
        /// The log declared the kind and held none: the picture never stopped
        /// changing for as long as `StillInterval.shortestWorthRecording`.
        /// A measurement, so decoding would only confirm it.
        case nothingWasEverStill
        /// No log declared the kind. The recording predates the idle timeline and
        /// says nothing either way; only the picture can answer.
        case theRecordingDoesNotCarryIt
    }

    public static func intervals(fromObservationLogAt url: URL) throws -> [StillInterval] {
        let lines = try JSONLReader.linesOfFile(at: url).lines
        var intervals: [StillInterval] = []
        for line in lines where try ObservationLog.kind(of: line) == "still" {
            intervals.append(try ObservationLog.decode(line) as StillInterval)
        }
        // Sorted on the way out for `FramingPlanReader.pointerSamples`' reason: a
        // package with several segments concatenates logs, and a consumer walking
        // an unsorted array gets a wrong answer rather than a slow one.
        return intervals.sorted { $0.interval.start.rawValue < $1.interval.start.rawValue }
    }

    /// Every segment log in a package, merged in segment order.
    ///
    /// One log declaring the kind is enough to call the whole recording
    /// answered: the kind is declared per segment by the same unconditional
    /// line, so a package mixing declared and undeclared logs would have to have
    /// been assembled by hand.
    public static func intervals(fromObservationLogsAt urls: [URL]) throws -> Outcome {
        var all: [StillInterval] = []
        var anyLogDeclaredTheKind = false
        for url in urls {
            let lines = try JSONLReader.linesOfFile(at: url).lines
            for line in lines {
                switch try ObservationLog.kind(of: line) {
                case "still":
                    all.append(try ObservationLog.decode(line) as StillInterval)
                case "logTrailer":
                    let trailer = try ObservationLog.decode(line) as ObservationLogTrailer
                    if trailer.recordCounts["still"] != nil { anyLogDeclaredTheKind = true }
                default:
                    break
                }
            }
        }
        if !all.isEmpty {
            return .recorded(all.sorted { $0.interval.start.rawValue < $1.interval.start.rawValue })
        }
        // A log truncated before its trailer — a crash mid-recording — leaves the
        // kind undeclared even though the build that wrote it declares it. That
        // reads as `theRecordingDoesNotCarryIt`, which sends the caller to the
        // picture. Answering from the picture is the safe direction: it is right
        // either way and only costs time.
        return anyLogDeclaredTheKind ? .nothingWasEverStill : .theRecordingDoesNotCarryIt
    }
}
