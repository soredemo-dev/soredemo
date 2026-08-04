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

/// One continuous stretch of master recording, and — through `hostRange` — the
/// authority on what belongs to it.
///
/// **THE ATTRIBUTION RULE. A record belongs to a segment if and only if its
/// `instant` falls inside that segment's `hostRange`. Attribution is decided by
/// TIME, never by which variable happened to be non-nil when the record
/// arrived.**
///
/// It is written on this type because this type owns `hostRange`, and because
/// the rule was derived three times before anyone wrote it down — each time
/// from a different symptom, each time at the cost of a review round:
///
///   * a late AX chain answering after its segment closed. Attributing it by
///     when the ANSWER arrived puts a click's evidence in the next segment;
///     attributing by the click's own `instant` is D2-12, and the code already
///     did the right thing for a reason nobody had generalised.
///   * observations arriving while a segment finalises. Their `instant` is
///     inside the closing segment's `hostRange`, so they are members and their
///     loss is a loss — which is why it is counted rather than shrugged at.
///   * observations arriving before any segment exists. Their `instant` is
///     inside NO `hostRange`, past or future, so they are not lost; they are
///     outside the recording. A counter that called them "dropped" was
///     conflating a classification with a defect.
///
/// **Two symmetric forbidden routes follow from it, and both look like
/// tidiness.** Appending a late record into the segment that is closing, and
/// buffering an early record to flush into segment 0, are the same move in
/// opposite directions: each writes a record into a segment whose `hostRange`
/// does not contain its `instant`. Buffering is not banned — for a record whose
/// `instant` IS inside, flushing it later is exactly right. What is banned is
/// the mismatch.
///
/// **It is cheap to enforce where it matters.** `assert(hostRange.contains(record.instant))`
/// before an append turns any future attribution mistake into a test failure
/// instead of a comment nobody re-reads. `CaptureSession` pins the ordering it
/// depends on with a static test rather than a per-record assert on the tap
/// callback's hot path — the cheap equivalent, with its own blind spot written
/// beside it.
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
    /// zero would be a plausible number for one (`AGENTS.md`). This method has
    /// no epoch logic of its own for the "another epoch" case: it delegates
    /// entirely to `HostRange.contains`'s own guard (`isComparable(with:)`),
    /// which is Task 1's code, not this type's. The epoch guard THIS type
    /// does own is `init(segments:)`'s `mixedEpochs` check, below — refusing
    /// to construct a table that spans two epochs in the first place, so
    /// `contentTime` never has to ask the question per-call.
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
    /// Hand-written for two reasons, the first load-bearing. Synthesised
    /// `Decodable` for a single-stored-property struct assigns `segments`
    /// directly and never calls `init(segments:)` — every invariant that
    /// initialiser checks (order, overlap, shared epoch) would go
    /// completely unenforced on the one path that carries untrusted input,
    /// `ProjectUpgrade.load` → `JSONDecoder().decode(ProjectSnapshot.self,
    /// …)`. And it would not fail loudly: `contentDuration` would over- or
    /// under-count, and `contentTime(of:)` would compute an offset from
    /// overlapping ranges — a plausible number, inside the legal range,
    /// for a question the initialiser exists specifically to make
    /// unaskable (`AGENTS.md`: "a measurement that can fail into a legal
    /// answer is not a measurement"). So decoding routes through the same
    /// validating initialiser construction does, and a table that fails
    /// validation fails to decode.
    ///
    /// Second, minor: encoding through a single-value container (a bare
    /// JSON array) rather than synthesis's keyed container avoids
    /// double-wrapping under `ProjectSnapshot`, whose own key for this
    /// field is already `"segments"` — synthesis would have produced
    /// `"segments":{"segments":[...]}`. `GeometryRegistry` makes the same
    /// choice for the same reason (see its own `Codable` conformance).
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
