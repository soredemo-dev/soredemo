/// A half-open span of time, `[start, start + duration)`, on a single boot's clock
/// with no epoch attached. `end` is excluded, so touching ranges do not overlap and
/// two abutting citations cannot double-claim the boundary nanosecond.
///
/// No caller in `Sources/` today: anything crossing a reboot must use `HostRange`.
/// Only a provably intra-boot interval, where an epoch would be pure overhead, would
/// justify this type over `HostRange`.
public struct TimeRange: Hashable, Codable, Sendable {
    public let start: Nanoseconds
    public let duration: Nanoseconds

    /// Traps if `duration` is negative.
    public init(start: Nanoseconds, duration: Nanoseconds) {
        precondition(duration.rawValue >= 0,
                     "TimeRange.duration must be non-negative, got \(duration.rawValue)")
        self.start = start
        self.duration = duration
    }

    /// The exclusive upper bound: `start + duration`.
    public var end: Nanoseconds { start + duration }

    /// True for every instant in `[start, end)`. A zero-duration range contains
    /// nothing, not even `start`; including it would make `contains` disagree with
    /// `overlaps` for two zero-duration ranges at the same instant.
    public func contains(_ instant: Nanoseconds) -> Bool {
        instant >= start && instant < end
    }

    /// True iff the two half-open intervals share at least one instant. Touching
    /// ranges (`a.end == b.start`) do not overlap.
    public func overlaps(_ other: TimeRange) -> Bool {
        start < other.end && other.start < end
    }
}
