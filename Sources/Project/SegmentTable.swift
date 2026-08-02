import Foundation
import Geometry
import Timeline

/// Why a master segment ended. A gap with no reason is indistinguishable from a
/// crash, which is the rule this project keeps re-deriving: silence is not a value.
public enum SegmentBoundary: Hashable, Codable, Sendable {
    case paused
    case displayReconfigured(newRevision: GeometryRevision)
    case stopped
    case failed(reason: String)
}

public struct MasterSegment: Hashable, Codable, Sendable {
    public let index: Int
    public let mediaFilename: String        // relative, never absolute
    public let hostRange: HostRange
    public let revision: GeometryRevision
    public let endedBy: SegmentBoundary

    public init(index: Int, mediaFilename: String, hostRange: HostRange,
                revision: GeometryRevision, endedBy: SegmentBoundary) {
        self.index = index
        self.mediaFilename = mediaFilename
        self.hostRange = hostRange
        self.revision = revision
        self.endedBy = endedBy
    }
}

public enum SegmentTableError: Error, Equatable {
    case outOfOrder(Int)
    case overlapping(Int)
    case mixedEpochs
}

/// The ordered master segments. **The only authority on order** — wall clock is
/// not, because it runs backwards under NTP correction (see `EpochAnchor`).
public struct SegmentTable: Hashable, Codable, Sendable {
    public let segments: [MasterSegment]

    public init(segments: [MasterSegment]) throws {
        for (i, s) in segments.enumerated() {
            if s.index != i { throw SegmentTableError.outOfOrder(i) }
            if i > 0 {
                let prev = segments[i - 1]
                if prev.hostRange.epoch != s.hostRange.epoch { throw SegmentTableError.mixedEpochs }
                if s.hostRange.start < prev.hostRange.end { throw SegmentTableError.overlapping(i) }
            }
        }
        self.segments = segments
    }

    /// Non-validating. Private because the empty array is the one segment
    /// list that cannot violate any invariant `init(segments:)` checks: there
    /// is no index to be out of order, no adjacent pair to overlap or to
    /// disagree on epoch. `SegmentTable.empty` is the only sanctioned caller.
    private init(unchecked segments: [MasterSegment]) {
        self.segments = segments
    }

    /// The empty table, for `ProjectSnapshot`'s default. Not `try!
    /// SegmentTable(segments: [])` — a measurement (here, "does this value
    /// satisfy the type's invariants") must not be asserted past a call that
    /// could throw; see `unchecked` above for why the empty case genuinely
    /// cannot fail.
    public static let empty = SegmentTable(unchecked: [])

    public var contentDuration: Nanoseconds {
        segments.reduce(Nanoseconds(0)) { $0 + $1.hostRange.duration }
    }

    /// Host time to content time. `nil` when the instant falls in a gap or in
    /// another epoch — both are questions with no answer, and a nearest-edge or
    /// zero would be a plausible number for one (`AGENTS.md`).
    public func contentTime(of instant: HostInstant) -> Nanoseconds? {
        var offset = Nanoseconds(0)
        for s in segments {
            if s.hostRange.contains(instant) {
                return offset + (instant.hostTime - s.hostRange.start)
            }
            offset = offset + s.hostRange.duration
        }
        return nil
    }
}
