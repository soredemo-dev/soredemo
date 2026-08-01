/// An instant (or a duration) expressed as integer nanoseconds.
///
/// **Never a `Double`.** Accumulated floating-point error in a timeline shows
/// up much later as drift that is very hard to attribute — a beat that lands
/// slightly off, a zoom that starts a frame early — and by then the cause is
/// many derivations away. `Nanoseconds` wraps an `Int64` specifically so that
/// arithmetic on it (`+`, `-`, comparisons) is exact, not merely close.
///
/// `Timeline` is a leaf module (design doc D-P1): this type has no notion of
/// wall-clock time and reads no clock. Every instant a caller has is passed
/// in from outside — capture timestamps, encoded media time, etc. — never
/// produced here.
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
    public static func + (lhs: Nanoseconds, rhs: Nanoseconds) -> Nanoseconds {
        Nanoseconds(lhs.rawValue + rhs.rawValue)
    }

    public static func - (lhs: Nanoseconds, rhs: Nanoseconds) -> Nanoseconds {
        Nanoseconds(lhs.rawValue - rhs.rawValue)
    }
}
