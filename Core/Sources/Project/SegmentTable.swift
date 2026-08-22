import Foundation
import Geometry
import Timeline

/// Why a master segment ended. Always stated: a gap with no reason is
/// indistinguishable from a crash.
public enum SegmentBoundary: Hashable, Codable, Sendable {
    case paused
    case displayReconfigured(newRevision: GeometryRevision)
    case stopped
    case failed(reason: String)
}

/// One continuous stretch of master recording, and — through `hostRange` — the
/// authority on what belongs to it.
///
/// THE ATTRIBUTION RULE: a record belongs to a segment iff its `instant` falls
/// inside that segment's `hostRange`. Attribution is decided by time, never by
/// which variable happened to be non-nil when the record arrived. Appending a
/// late record to the closing segment, and buffering an early record into segment
/// 0, are both banned by it; buffering a record whose `instant` is inside is not.
/// A record inside no `hostRange` is outside the recording, not lost.
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

/// The ordered master segments, and the only authority on order — wall clock runs
/// backwards under NTP correction.
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

    /// Non-validating; private because only the empty array can satisfy every
    /// invariant `init(segments:)` checks without being checked. `empty` is the
    /// only sanctioned caller.
    private init(unchecked segments: [MasterSegment]) {
        self.segments = segments
    }

    /// The empty table, for `ProjectSnapshot`'s default. Not `try!`, which would
    /// assert an invariant past a call that could throw.
    public static let empty = SegmentTable(unchecked: [])

    public var contentDuration: Nanoseconds {
        segments.reduce(Nanoseconds(0)) { $0 + $1.hostRange.duration }
    }

    /// Host time to content time. `nil` when the instant falls in a gap or another
    /// epoch — neither has an answer, and a nearest-edge or zero would be a
    /// plausible wrong one. The epoch case is `HostRange.contains`'s guard;
    /// `init(segments:)` already refuses tables spanning two epochs.
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

extension SegmentTable {
    /// Routes decoding through `init(segments:)`, so a table failing its order,
    /// overlap or shared-epoch checks fails to decode; a synthesised `Decodable`
    /// would assign `segments` directly and leave untrusted input unvalidated.
    ///
    /// Encodes as a bare JSON array through a single-value container: synthesis's
    /// keyed container would produce `"segments":{"segments":[...]}` under
    /// `ProjectSnapshot`.
    public init(from decoder: any Decoder) throws {
        let decoded = try decoder.singleValueContainer().decode([MasterSegment].self)
        do {
            try self.init(segments: decoded)
        } catch {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "SegmentTable failed validation: \(error)",
                underlyingError: error))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(segments)
    }
}
