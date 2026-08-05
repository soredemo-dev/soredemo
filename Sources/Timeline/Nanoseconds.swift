/// An instant or duration as integer nanoseconds. Wraps `Int64`, never a `Double`, so
/// arithmetic is exact rather than accumulating drift. This type reads no clock:
/// every instant is passed in from outside, never produced here.
public struct Nanoseconds: Hashable, Codable, Sendable, Comparable {
    public let rawValue: Int64

    public init(_ rawValue: Int64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Nanoseconds, rhs: Nanoseconds) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension Nanoseconds {
    /// Converts a rational time — `value / timescale` seconds — to integer
    /// nanoseconds, or `nil` if it is not a time or does not fit.
    ///
    /// Divides before multiplying, splitting into whole seconds plus a remainder to
    /// stay exact: `value * 1_000_000_000 / timescale` overflows `Int64` for host time
    /// at timescale `1_000_000_000` after ~9.2 seconds of uptime. Truncation is toward
    /// zero, matching `Int64` division on both signs.
    ///
    /// Returns `nil` rather than trapping on a non-positive timescale or a value whose
    /// nanosecond form exceeds `Int64`: the caller is a stream callback holding one
    /// frame, and dropping it beats killing a recording. Drops must be counted.
    public init?(rationalSeconds value: Int64, timescale: Int32) {
        guard timescale > 0 else { return nil }
        let scale = Int64(timescale)
        // Cannot overflow: the sole overflowing `Int64` division is `Int64.min / -1`,
        // and `scale` is positive by the guard above.
        let wholeSeconds = value / scale
        let remainder = value % scale
        guard case let (secondsInNanos, secondsOverflow) =
                wholeSeconds.multipliedReportingOverflow(by: 1_000_000_000),
              !secondsOverflow,
              // `|remainder| < scale`, so this overflows only above a ~9.2e9 timescale,
              // unreachable through `CMTime`'s `Int32`, but checked rather than argued.
              case let (remainderInNanos, remainderOverflow) =
                remainder.multipliedReportingOverflow(by: 1_000_000_000),
              !remainderOverflow,
              case let (total, sumOverflow) =
                secondsInNanos.addingReportingOverflow(remainderInNanos / scale),
              !sumOverflow
        else { return nil }
        self.init(total)
    }

    public static func + (lhs: Nanoseconds, rhs: Nanoseconds) -> Nanoseconds {
        Nanoseconds(lhs.rawValue + rhs.rawValue)
    }

    public static func - (lhs: Nanoseconds, rhs: Nanoseconds) -> Nanoseconds {
        Nanoseconds(lhs.rawValue - rhs.rawValue)
    }
}
