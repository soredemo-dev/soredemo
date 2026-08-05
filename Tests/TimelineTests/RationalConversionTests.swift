import Testing
import Foundation
@testable import Timeline

// MARK: - Nanoseconds(rationalSeconds:timescale:)
//
// The naive `value * 1_000_000_000 / timescale` traps on `Int64` overflow.
// `SCStream` stamps frames at timescale 1_000_000_000, so `value` is already
// nanoseconds since boot and the multiply overflows after ~9.2s of uptime.

/// A real host-clock PTS at nanosecond timescale, which the old expression
/// multiplied to 4.5e23 and trapped on.
@Test func hostTimePTSAtNanosecondTimescaleDoesNotOverflow() throws {
    let observed = try #require(Nanoseconds(rationalSeconds: 451_316_246_248_958,
                                             timescale: 1_000_000_000))
    // At timescale 1e9 the conversion is the identity.
    #expect(observed == Nanoseconds(451_316_246_248_958))
}

/// The first second on either side of the ~9.223372036854776 s overflow threshold.
@Test func hostTimePTSEitherSideOfTheOldOverflowThresholdConverts() throws {
    let justUnder = try #require(Nanoseconds(rationalSeconds: 9_000_000_000, timescale: 1_000_000_000))
    let justOver = try #require(Nanoseconds(rationalSeconds: 10_000_000_000, timescale: 1_000_000_000))
    #expect(justUnder == Nanoseconds(9_000_000_000))
    #expect(justOver == Nanoseconds(10_000_000_000))
}

/// `Int64.max / 1_000_000_000 == 9_223_372_036`, the largest uptime the old
/// expression survived; `9_223_372_037` is the first that overflowed.
/// Straddling by exactly one nanosecond catches an off-by-one in the guard
/// that the 9 s / 10 s pair above would not.
@Test func theExactUptimeAtWhichTheOldExpressionBeganToOverflow() throws {
    #expect(Int64.max / 1_000_000_000 == 9_223_372_036)   // states where the boundary comes from
    let lastSafe = try #require(Nanoseconds(rationalSeconds: 9_223_372_036, timescale: 1_000_000_000))
    let firstUnsafe = try #require(Nanoseconds(rationalSeconds: 9_223_372_037, timescale: 1_000_000_000))
    #expect(lastSafe == Nanoseconds(9_223_372_036))
    #expect(firstUnsafe == Nanoseconds(9_223_372_037))
}

/// The far end of the uptime dimension: three weeks, a real uptime laptops reach
/// on sleep/wake cycles, not a synthetic extreme.
@Test func hostTimePTSAfterThreeWeeksOfUptimeConverts() throws {
    let threeWeeksInNanos: Int64 = 21 * 24 * 60 * 60 * 1_000_000_000
    #expect(threeWeeksInNanos == 1_814_400_000_000_000)
    let observed = try #require(Nanoseconds(rationalSeconds: threeWeeksInNanos, timescale: 1_000_000_000))
    #expect(observed == Nanoseconds(1_814_400_000_000_000))
}

/// An unevenly dividing timescale truncates toward zero, with no `Double`
/// anywhere. 600 is the QuickTime timescale; 1001/30000 is broadcast 29.97.
@Test func nonDividingTimescalesTruncateTowardZero() throws {
    #expect(try #require(Nanoseconds(rationalSeconds: 1, timescale: 600))
            == Nanoseconds(1_666_666))          // 1/600 s = 1666666.66… ns
    #expect(try #require(Nanoseconds(rationalSeconds: 1001, timescale: 30_000))
            == Nanoseconds(33_366_666))         // one 29.97 frame
    #expect(try #require(Nanoseconds(rationalSeconds: -1, timescale: 600))
            == Nanoseconds(-1_666_666))         // toward zero, not toward -inf
}

/// Exercises the seconds term rather than the remainder term; it fits in `Int64`
/// only if the division happens before the multiply.
@Test func largeValueAtSmallTimescaleConverts() throws {
    #expect(try #require(Nanoseconds(rationalSeconds: 451_316, timescale: 1))
            == Nanoseconds(451_316_000_000_000))
}

/// A non-positive timescale is not a time: `nil`, never a trap, so one bad
/// attachment cannot kill a recording.
@Test func nonPositiveTimescaleIsNotConvertible() {
    #expect(Nanoseconds(rationalSeconds: 1_000, timescale: 0) == nil)
    #expect(Nanoseconds(rationalSeconds: 1_000, timescale: -600) == nil)
}

/// A duration that does not fit in `Int64` nanoseconds at all must be `nil`,
/// not a trap and not a silently truncated number.
@Test func valueTooLargeToExpressInNanosecondsIsNotConvertible() {
    #expect(Nanoseconds(rationalSeconds: Int64.max, timescale: 1) == nil)
    #expect(Nanoseconds(rationalSeconds: Int64.min, timescale: 1) == nil)
}

/// The largest representable value must convert; rejecting it would be an
/// off-by-one in the overflow guard.
@Test func largestRepresentableValueConverts() throws {
    #expect(try #require(Nanoseconds(rationalSeconds: Int64.max, timescale: 1_000_000_000))
            == Nanoseconds(Int64.max))
}
