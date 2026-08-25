import Foundation
import Framing
import Project
import Timeline

/// Reads one observation log into a `FramingPlan` — every framing decision the gate made,
/// accepted and refused alike, without building a composition first.
///
/// **Why this is separate from `StageCompositor.buildTracks`.** That function runs inside
/// AVFoundation's compositor, on AVFoundation's schedule, and produces a camera. A review
/// surface needs the same decisions before anything is played or exported, and asking it to
/// stand up a compositor to find out why a click was refused would make the explanation
/// depend on the machinery it is explaining. The rule that turns a chain into a decision
/// still has exactly one owner — `FramingGate.decide(for:)` — which is the part that must
/// not be duplicated; the loop that finds the lines is not.
public enum FramingPlanReader {
    /// Every `axChain` record in the log, decided.
    ///
    /// A log with no chains yields an empty plan, which is a real answer: it means the
    /// recording observed no clicks with accessibility available, not that reading failed.
    /// Read failures throw.
    public static func plan(fromObservationLogAt url: URL) throws -> FramingPlan {
        let lines = try JSONLReader.linesOfFile(at: url).lines
        var entries: [FramingPlan.Entry] = []
        for line in lines where try ObservationLog.kind(of: line) == "axChain" {
            let record = try ObservationLog.decode(line) as AXChainRecord
            entries.append(FramingPlan.Entry(instant: record.instant,
                                             decision: FramingGate.decide(for: record),
                                             clickPosition: record.clickPosition,
                                             clickRevision: record.clickRevision))
        }
        return FramingPlan(entries: entries)
    }

    /// The recording's epoch anchor — the `logHeader`'s, which is how an absolute host
    /// instant becomes an offset a person can read as a time in the video.
    ///
    /// Separate from `plan` rather than returned with it: a caller that only wants the
    /// decisions should not have to care whether a header was present, and one that wants
    /// times needs to distinguish "no header" from "offset zero". `nil` is the former.
    public static func anchor(fromObservationLogAt url: URL) throws -> EpochAnchor? {
        let lines = try JSONLReader.linesOfFile(at: url).lines
        for line in lines where try ObservationLog.kind(of: line) == "logHeader" {
            return (try ObservationLog.decode(line) as ObservationLogHeader).anchor
        }
        return nil
    }

    /// How far into the recording an instant falls, or `nil` when it is in another boot
    /// session — the same epoch check every other consumer of an absolute instant makes,
    /// rather than a subtraction that would silently produce a plausible number.
    public static func offset(of instant: HostInstant, from anchor: EpochAnchor) -> Nanoseconds? {
        guard instant.epoch == anchor.epoch else { return nil }
        return Nanoseconds(instant.hostTime.rawValue - anchor.hostTime.rawValue)
    }

    /// **Every pointer sample in the log, oldest first.**
    ///
    /// For placing a zoom that a person adds where no click happened: the pointer is where
    /// the action is during a demo, which is the same argument `pointerFallbackExtent` is
    /// built on. Read here rather than in the app tier because `ObservationLog`'s decoding
    /// belongs to one place, and read as a whole array rather than one query at a time
    /// because the alternative is reopening the file per placement.
    ///
    /// Sorted on the way out: the writer appends in observation order, but a package with
    /// several segments concatenates them, and a binary search over an unsorted array is a
    /// wrong answer rather than a slow one.
    public static func pointerSamples(fromObservationLogAt url: URL) throws -> [PointerSample] {
        let lines = try JSONLReader.linesOfFile(at: url).lines
        var samples: [PointerSample] = []
        for line in lines where try ObservationLog.kind(of: line) == "pointer" {
            samples.append(try ObservationLog.decode(line) as PointerSample)
        }
        return samples.sorted { $0.instant.hostTime.rawValue < $1.instant.hostTime.rawValue }
    }

    /// The same, for every segment log in a recording package, merged in segment order.
    /// A recording paused and resumed has one log per segment and one timeline; a reviewer
    /// reads the timeline.
    public static func plan(fromObservationLogsAt urls: [URL]) throws -> FramingPlan {
        var entries: [FramingPlan.Entry] = []
        for url in urls {
            entries.append(contentsOf: try plan(fromObservationLogAt: url).entries)
        }
        // `FramingPlan.init` sorts by instant, so segment order only decides tie-breaking.
        return FramingPlan(entries: entries)
    }
}
