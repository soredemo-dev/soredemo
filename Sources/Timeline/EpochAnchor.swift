import Foundation

/// Ties one boot epoch to a wall-clock reading, for display and rough placement.
///
/// **The wall clock is not an ordering key.** It runs backwards under NTP
/// correction and can be set by hand. Segment order is recorded explicitly in
/// `SegmentTable`; anything that sorts by `wallClockUnixNanos` is wrong.
///
/// Deliberately not `Comparable`, so there is nothing to reach for. `kern.boottime`
/// is *not* the epoch identity for the same reason — it is computed as now-minus-uptime
/// and moves when the clock is corrected, which would make one boot look like two.
public struct EpochAnchor: Hashable, Codable, Sendable {
    public let epoch: BootEpoch
    public let hostTime: Nanoseconds
    public let wallClockUnixNanos: Int64

    public init(epoch: BootEpoch, hostTime: Nanoseconds, wallClockUnixNanos: Int64) {
        self.epoch = epoch
        self.hostTime = hostTime
        self.wallClockUnixNanos = wallClockUnixNanos
    }
}
