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
    /// stance `NormalizedFrame` takes on `geometryRevision`.
    public static func < (lhs: HostInstant, rhs: HostInstant) -> Bool {
        precondition(lhs.epoch == rhs.epoch,
                     "comparing host instants across boot epochs: \(lhs.epoch.id) vs \(rhs.epoch.id)")
        return lhs.hostTime < rhs.hostTime
    }
}
