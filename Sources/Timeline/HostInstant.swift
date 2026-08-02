import Foundation

/// A host-clock instant, stamped with the boot session it came from.
public struct HostInstant: Hashable, Codable, Sendable, Comparable {
    public let epoch: BootEpoch
    public let hostTime: Nanoseconds

    public init(epoch: BootEpoch, hostTime: Nanoseconds) {
        self.epoch = epoch
        self.hostTime = hostTime
    }

    /// Ordering is only defined within an epoch. Comparing across one is a
    /// programming error, not a runtime condition to recover from — the same
    /// stance `NormalizedFrame` takes on `geometryRevision`. Contrast
    /// `HostRange.contains`, which asks the same "same reference frame?"
    /// question but returns `false` instead of trapping, because a caller
    /// legitimately asks that one across epochs; see `HostRange.contains`'s
    /// doc comment and D2-11 for why the two guards differ.
    ///
    /// Like every precondition in this package, this cannot be exercised
    /// with `#expect` — a precondition failure kills the process — so it is
    /// not covered by `EpochTests.swift`; see the Task 1 review-fix report
    /// for how it was verified out-of-process instead.
    public static func < (lhs: HostInstant, rhs: HostInstant) -> Bool {
        precondition(lhs.epoch == rhs.epoch,
                     "comparing host instants across boot epochs: \(lhs.epoch.id) vs \(rhs.epoch.id)")
        return lhs.hostTime < rhs.hostTime
    }
}
