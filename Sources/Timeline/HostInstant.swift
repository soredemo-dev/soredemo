import Foundation

/// A host-clock instant, stamped with the boot session it came from.
public struct HostInstant: Hashable, Codable, Sendable, Comparable {
    public let epoch: BootEpoch
    public let hostTime: Nanoseconds

    public init(epoch: BootEpoch, hostTime: Nanoseconds) {
        self.epoch = epoch
        self.hostTime = hostTime
    }

    /// Ordering is defined only within an epoch; traps across epochs, since comparing
    /// them is a programming error, not a condition to recover from. Contrast
    /// `HostRange.contains`, which returns `false` because asking it is legitimate.
    public static func < (lhs: HostInstant, rhs: HostInstant) -> Bool {
        precondition(lhs.epoch == rhs.epoch,
                     "comparing host instants across boot epochs: \(lhs.epoch.id) vs \(rhs.epoch.id)")
        return lhs.hostTime < rhs.hostTime
    }
}
