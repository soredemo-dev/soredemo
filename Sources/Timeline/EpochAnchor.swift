import Foundation

/// Ties one boot epoch to a wall-clock reading, for display and rough placement.
///
/// The wall clock is not an ordering key: it runs backwards under NTP correction and
/// can be set by hand, so sorting by `wallClockUnixNanos` is wrong — segment order
/// lives in `SegmentTable`. Not `Comparable`, so there is nothing to reach for.
/// `kern.boottime` is not the epoch identity for the same reason: it is now-minus-
/// uptime and moves on correction, making one boot look like two.
public struct EpochAnchor: Hashable, Codable, Sendable {
    public let epoch: BootEpoch
    public let hostTime: Nanoseconds
    public let wallClockUnixNanos: Int64

    public init(epoch: BootEpoch, hostTime: Nanoseconds, wallClockUnixNanos: Int64) {
        self.epoch = epoch
        self.hostTime = hostTime
        self.wallClockUnixNanos = wallClockUnixNanos
    }

    /// The one composition-offset → host-instant conversion. `1a98402` happened at a
    /// caller doing this addition by hand on two bare `Nanoseconds` and dropping one
    /// term; done here, the result carries its epoch, and the track queries' taking
    /// `HostInstant` is what makes the bare-number version of that mistake fail to
    /// typecheck instead of matching nothing on every frame.
    public func instant(atOffset offset: Nanoseconds) -> HostInstant {
        HostInstant(epoch: epoch, hostTime: hostTime + offset)
    }
}
