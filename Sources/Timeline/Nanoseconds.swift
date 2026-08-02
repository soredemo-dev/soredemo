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
    /// Converts a rational time — `value / timescale` **seconds** — to
    /// integer nanoseconds, or `nil` if it is not a time or does not fit.
    ///
    /// **This function exists because the obvious expression traps.** The
    /// natural way to write it is
    ///
    ///     value * 1_000_000_000 / Int64(timescale)
    ///
    /// and that is what `CaptureSession.handleScreenSample` did. It is not
    /// merely fragile at the extremes: `SCStream` stamps every frame with
    /// host time at timescale `1_000_000_000`, so `value` IS nanoseconds
    /// since boot, and the multiplication overflows `Int64` once the machine
    /// has been up for **9.223372036854776 seconds**. Measured, on a machine
    /// where `CMClockGetTime(CMClockGetHostTimeClock())` returned
    /// `value=451316246248958 timescale=1000000000`: the product is ~4.5e23
    /// against a ceiling of 9223372036854775807. Every complete frame
    /// trapped, on every run.
    ///
    /// Dividing first is what makes it safe, and splitting into whole
    /// seconds plus a remainder is what keeps it *exact* while doing so —
    /// `Nanoseconds`' own doc comment forbids routing this through a
    /// `Double`, and `CMTimeGetSeconds(pts) * 1e9` is precisely the
    /// floating-point drift that type exists to prevent. Truncation is
    /// toward zero, matching `Int64` division on both signs.
    ///
    /// **`nil`, not a trap, on the unrepresentable cases** — a non-positive
    /// timescale, or a value whose nanosecond form exceeds `Int64`. The
    /// caller is a stream callback holding one frame: killing a recording in
    /// progress is a worse answer than dropping the frame, which is the same
    /// stance `recordContentScale` documents for `ContentScale != 1`. A drop
    /// is only acceptable if it is *counted*, which is why
    /// `Diagnostics.unconvertiblePresentationTimeCount` exists.
    ///
    /// `Timeline` reads no clock (D-P1): the value and timescale are handed
    /// in, and this does arithmetic on them and nothing else.
    public init?(rationalSeconds value: Int64, timescale: Int32) {
        guard timescale > 0 else { return nil }
        let scale = Int64(timescale)
        // `value / scale` and `value % scale` cannot themselves overflow
        // here: the sole overflowing case for `Int64` division is
        // `Int64.min / -1`, and `scale` is positive by the guard above.
        let wholeSeconds = value / scale
        let remainder = value % scale
        guard case let (secondsInNanos, secondsOverflow) =
                wholeSeconds.multipliedReportingOverflow(by: 1_000_000_000),
              !secondsOverflow,
              // `|remainder| < scale`, so this overflows only for a timescale
              // above ~9.2e9 — unreachable through `CMTime`'s `Int32`, but
              // checked rather than argued, because the argument is the kind
              // that was wrong the first time.
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
