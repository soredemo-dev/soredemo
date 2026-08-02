import Foundation

/// A half-open host-clock interval, stamped with its boot epoch.
///
/// Replaces `TimeRange` wherever a value crosses a session boundary — notably
/// `EvidenceRef.sourceInterval`, which is host time by D2-12 Q1.
public struct HostRange: Hashable, Codable, Sendable {
    public let epoch: BootEpoch
    public let start: Nanoseconds
    public let duration: Nanoseconds

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

    /// `false` for an instant from another epoch. Not a precondition failure,
    /// because a reverse index legitimately asks this of everything it holds —
    /// the same reason `ReverseIndex.dependents(of:)` returns empty rather than
    /// trapping when it is stale.
    public func contains(_ instant: HostInstant) -> Bool {
        guard isComparable(with: instant) else { return false }
        return instant.hostTime >= start && instant.hostTime < end
    }
}
