import Testing
import Foundation
@testable import Timeline

// MARK: - Nanoseconds(rationalSeconds:timescale:)
//
// Why this file exists, and why the values in it are measured rather than
// chosen: `CaptureSession.handleScreenSample` converted a `CMTime` to
// integer nanoseconds as
//
//     Int64(pts.value) * 1_000_000_000 / Int64(pts.timescale)
//
// which traps on `Int64` overflow. It was not a rare edge case. `SCStream`
// stamps every frame with host time at timescale 1_000_000_000, so
// `pts.value` IS nanoseconds since boot, and the multiplication overflows
// once the machine has been up for 9.223372036854776 seconds. The whole
// frame path trapped on its very first complete frame, on every run, on
// every machine — and 324 tests did not see it, because nothing had ever
// fed the session a real sample buffer.
//
// The arithmetic lives here, in a Foundation-only leaf module, precisely so
// that it is reachable by a test. The part that genuinely needs
// ScreenCaptureKit is reading `pts.value` and `pts.timescale` off a real
// `CMTime`; the part that was wrong is this, and this needs nothing.

/// The measurement that produced the fix, pinned as the test.
///
/// `CMClockGetTime(CMClockGetHostTimeClock())` returned
/// `value=451316246248958 timescale=1000000000` on the machine where
/// `SoredemoSpikeB video` trapped. Under the old expression this is
/// `451316246248958 * 1_000_000_000`, which is 4.5e23 against an `Int64`
/// ceiling of 9223372036854775807 — a trap, not a wrong number.
@Test func hostTimePTSAtNanosecondTimescaleDoesNotOverflow() throws {
    let observed = try #require(Nanoseconds(rationalSeconds: 451_316_246_248_958,
                                             timescale: 1_000_000_000))
    // At timescale 1e9 the conversion is the identity, which is the whole
    // point: the old code trapped computing a value it did not need to
    // compute at all.
    #expect(observed == Nanoseconds(451_316_246_248_958))
}

/// The boundary the measurement names. Anything past 9.223372036854776 s of
/// uptime overflowed; this is the first second on either side of it.
@Test func hostTimePTSEitherSideOfTheOldOverflowThresholdConverts() throws {
    let justUnder = try #require(Nanoseconds(rationalSeconds: 9_000_000_000, timescale: 1_000_000_000))
    let justOver = try #require(Nanoseconds(rationalSeconds: 10_000_000_000, timescale: 1_000_000_000))
    #expect(justUnder == Nanoseconds(9_000_000_000))
    #expect(justOver == Nanoseconds(10_000_000_000))
}

/// **Uptime is a fixture dimension, and this is the exact value of it that
/// separates pass from fail.**
///
/// `Int64.max / 1_000_000_000 == 9_223_372_036`, so under the old expression
/// `9_223_372_036` ns of uptime is the largest value that did NOT overflow
/// and `9_223_372_037` is the first that did. A machine rebooted moments
/// before a test run passed; the same machine an hour later did not. Nothing
/// in the suite named uptime, so nothing in the suite could have said so.
///
/// It joins the list of environment dimensions this project has been caught
/// by — `scale: 1`, an origin of `(0, 0)`, a centred rectangle, a warm build
/// vs a clean one, TCC state — and it belongs there for the same reason: the
/// test does not control it, and it decides the result.
///
/// Straddling the boundary by exactly one nanosecond is the point. A test at
/// 9 s and a test at 10 s (above) would both have passed a fix that was off
/// by a nanosecond in the guard; these two would not.
@Test func theExactUptimeAtWhichTheOldExpressionBeganToOverflow() throws {
    #expect(Int64.max / 1_000_000_000 == 9_223_372_036)   // states where the boundary comes from
    let lastSafe = try #require(Nanoseconds(rationalSeconds: 9_223_372_036, timescale: 1_000_000_000))
    let firstUnsafe = try #require(Nanoseconds(rationalSeconds: 9_223_372_037, timescale: 1_000_000_000))
    #expect(lastSafe == Nanoseconds(9_223_372_036))
    #expect(firstUnsafe == Nanoseconds(9_223_372_037))
}

/// The far end of the same dimension: a machine that has not been rebooted
/// in three weeks. The value the fix was found at — 451316246248958 ns, ~5.2
/// days — sits between this and the boundary above, which is a fine place
/// for a measurement and a poor place for the only test.
///
/// Three weeks is not arbitrary: laptops routinely reach it on sleep/wake
/// cycles without a reboot, so it is a real uptime, not a synthetic extreme.
@Test func hostTimePTSAfterThreeWeeksOfUptimeConverts() throws {
    let threeWeeksInNanos: Int64 = 21 * 24 * 60 * 60 * 1_000_000_000
    #expect(threeWeeksInNanos == 1_814_400_000_000_000)
    let observed = try #require(Nanoseconds(rationalSeconds: threeWeeksInNanos, timescale: 1_000_000_000))
    #expect(observed == Nanoseconds(1_814_400_000_000_000))
}

/// Conversion at a timescale that does not divide evenly must stay exact in
/// the integer sense — truncation toward zero, no `Double` anywhere. 600 is
/// the classic QuickTime timescale; 1001/30000 is broadcast 29.97.
@Test func nonDividingTimescalesTruncateTowardZero() throws {
    #expect(try #require(Nanoseconds(rationalSeconds: 1, timescale: 600))
            == Nanoseconds(1_666_666))          // 1/600 s = 1666666.66… ns
    #expect(try #require(Nanoseconds(rationalSeconds: 1001, timescale: 30_000))
            == Nanoseconds(33_366_666))         // one 29.97 frame
    #expect(try #require(Nanoseconds(rationalSeconds: -1, timescale: 600))
            == Nanoseconds(-1_666_666))         // toward zero, not toward -inf
}

/// A large value at a small timescale exercises the seconds term rather than
/// the remainder term: 451316 s at timescale 1 is 4.5e14 ns, comfortably
/// inside `Int64` — but only if the division happens before the multiply.
@Test func largeValueAtSmallTimescaleConverts() throws {
    #expect(try #require(Nanoseconds(rationalSeconds: 451_316, timescale: 1))
            == Nanoseconds(451_316_000_000_000))
}

/// A timescale of zero or below is not a time. Returning `nil` rather than
/// trapping is the same stance `CaptureSession` takes toward every other
/// unusable frame — drop it and count it — and the count is what makes the
/// drop visible. A trap here would kill a recording over one bad attachment.
@Test func nonPositiveTimescaleIsNotConvertible() {
    #expect(Nanoseconds(rationalSeconds: 1_000, timescale: 0) == nil)
    #expect(Nanoseconds(rationalSeconds: 1_000, timescale: -600) == nil)
}

/// The genuinely unrepresentable case: a duration that does not fit in
/// `Int64` nanoseconds at all. `Int64.max` seconds is ~9.2e18 s; expressed
/// in nanoseconds that needs ~9.2e27, which no `Int64` holds. This must be
/// `nil` — the same answer as "not a time" — and NOT a trap, and not a
/// silently truncated number.
@Test func valueTooLargeToExpressInNanosecondsIsNotConvertible() {
    #expect(Nanoseconds(rationalSeconds: Int64.max, timescale: 1) == nil)
    #expect(Nanoseconds(rationalSeconds: Int64.min, timescale: 1) == nil)
}

/// `Int64.max` at a nanosecond timescale is `Int64.max` nanoseconds — the
/// largest value that IS representable. It must convert, not fail: a
/// conversion that rejected its own maximum would be an off-by-one in the
/// overflow guard, and the guard is the entire point of this function.
@Test func largestRepresentableValueConverts() throws {
    #expect(try #require(Nanoseconds(rationalSeconds: Int64.max, timescale: 1_000_000_000))
            == Nanoseconds(Int64.max))
}
