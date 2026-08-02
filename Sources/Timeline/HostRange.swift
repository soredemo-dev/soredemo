import Foundation

/// A half-open host-clock interval, stamped with its boot epoch.
///
/// Replaces `TimeRange` wherever a value crosses a session boundary — notably
/// `EvidenceRef.sourceInterval`, which is host time by D2-12 Q1.
public struct HostRange: Hashable, Codable, Sendable {
    public let epoch: BootEpoch
    public let start: Nanoseconds
    public let duration: Nanoseconds

    /// Traps if `duration` is negative. Like every precondition in this
    /// package, this cannot be exercised with `#expect` — a precondition
    /// failure kills the process — so it is not covered by
    /// `EpochTests.swift`; see the Task 1 review-fix report for how it was
    /// verified out-of-process instead.
    public init(epoch: BootEpoch, start: Nanoseconds, duration: Nanoseconds) {
        precondition(duration.rawValue >= 0, "a negative duration is not a range")
        self.epoch = epoch
        self.start = start
        self.duration = duration
    }

    public var end: Nanoseconds { start + duration }

    /// Whether this range can be reasoned about together with `instant` at all.
    /// Separate from `contains` on purpose: a caller that wants to know *why* a
    /// containment test failed can ask, instead of inferring it from `false`.
    public func isComparable(with instant: HostInstant) -> Bool { instant.epoch == epoch }

    /// `false` for an instant from another epoch — deliberately not a
    /// precondition failure, unlike `HostInstant.<`. The two guards answer the
    /// same underlying question (are these two values in the same reference
    /// frame?) but take opposite stances on what a mismatch means: ordering
    /// two instants assumes a shared clock, so `HostInstant.<` treats a
    /// mismatch as mis-plumbed state and traps, the same stance
    /// `NormalizedFrame.contains` takes on `geometryRevision`. "Does this
    /// instant fall in this range" is different — a caller can legitimately
    /// ask it across epochs (Task 4's `SegmentTable.contentTime(of:)`; by
    /// Phase 4 a project holds several recordings, each its own epoch) and
    /// needs an answer, not a crash. See D2-11 for the corrected rationale —
    /// the design doc originally called this row "the same" as
    /// `GeometryRevision`'s and that was wrong.
    ///
    /// A caller that gets `false` back and needs to know *why* — different
    /// epoch, or same epoch but outside the range — should call
    /// `isComparable(with:)` directly rather than infer it from this method
    /// alone.
    ///
    /// The closest existing precedent is `ReverseIndex.dependents(of:)`,
    /// which also returns empty rather than trapping when it cannot currently
    /// answer — but the analogy is imperfect: that type signals the
    /// staleness of a cache, a temporal condition that resolves once the
    /// index is rebuilt. This signals that two identities never matched and
    /// never will; nothing rebuilds it into a match. Both choose `false`
    /// over a trap because the caller's question is legitimate to ask, not
    /// because the two absences mean the same thing.
    public func contains(_ instant: HostInstant) -> Bool {
        guard isComparable(with: instant) else { return false }
        return instant.hostTime >= start && instant.hostTime < end
    }
}
