import Foundation
import Testing
@testable import Compositing

/// **A bar answers "where am I"; this answers "should I wait".**
///
/// Reported by somebody using the app: the export shows a fraction and never says how long. The
/// two are different questions and only the second one changes what anybody does.
///
/// The tests below are mostly about **not** saying things: the first estimate is the one that
/// decides whether anybody believes the rest of them, and an export half a second in has a
/// fraction near zero and a division near infinity.
@Suite("Export time estimate")
struct ExportETATests {
    // MARK: - Saying nothing until there is something to say

    /// **Both conditions, not either.** A fast export passes the fraction in a moment, with a
    /// rate measured over almost nothing; a slow one sits below the fraction with plenty of
    /// elapsed time and no idea where it is going. Each of these would be claimed by an `||`.
    @Test("nothing is claimed before the export has both run and got somewhere")
    func nothingIsClaimedTooEarly() {
        var eta = ExportETA()
        // Plenty of progress, no time: a 90%-in-half-a-second reading is not a rate.
        #expect(eta.update(fraction: 0.9, elapsed: 0.5) == nil)
        // Plenty of time, no progress: elapsed / 0.001 is four hours of nonsense.
        #expect(eta.update(fraction: 0.001, elapsed: 30) == nil)
        #expect(eta.secondsRemaining == nil)
    }

    @Test("once it has both, it answers")
    func itAnswersOnceItCan() {
        var eta = ExportETA()
        // A quarter done after ten seconds: forty seconds total, thirty left.
        let remaining = eta.update(fraction: 0.25, elapsed: 10)
        #expect(remaining != nil)
        #expect(abs((remaining ?? 0) - 30) < 0.001)
    }

    /// **A moment of nonsense does not blank a number somebody is reading.** A NaN fraction, or a
    /// report at 100%, leaves the last estimate standing rather than clearing it — a value that
    /// appears and disappears reads as a bug in the app rather than as an estimate.
    @Test("an unusable report leaves the last estimate rather than clearing it")
    func nonsenseDoesNotClear() {
        var eta = ExportETA()
        eta.update(fraction: 0.5, elapsed: 10)
        let held = eta.secondsRemaining
        #expect(held != nil)
        eta.update(fraction: .nan, elapsed: 12)
        #expect(eta.secondsRemaining == held)
        eta.update(fraction: 1, elapsed: 20)
        #expect(eta.secondsRemaining == held)
    }

    // MARK: - Smoothing

    /// **A number that jumps while somebody is looking at it is a number they stop looking at.**
    /// The raw estimate wobbles report to report; this checks the smoothing actually damps it —
    /// after one update toward a much larger value, the reading has moved a quarter of the way
    /// and not all of it.
    @Test("the estimate moves toward a new reading rather than jumping to it")
    func itIsSmoothed() {
        var eta = ExportETA()
        eta.update(fraction: 0.5, elapsed: 10)     // 10 s left
        #expect(abs((eta.secondsRemaining ?? 0) - 10) < 0.001)
        // The export slows sharply: a quarter done after 20 s means 60 s left, raw.
        eta.update(fraction: 0.25, elapsed: 20)
        let moved = eta.secondsRemaining ?? 0
        #expect(moved > 10, "it did not move toward the new reading at all")
        #expect(moved < 60, "it jumped straight to the new reading instead of easing")
        // A quarter of the way from 10 to 60 is 22.5.
        #expect(abs(moved - 22.5) < 0.001)
    }

    /// Four updates reach a change, which is what `smoothing` is chosen for: fast enough to
    /// follow an export that genuinely slows, slow enough not to flicker.
    @Test("a sustained change is reached in a few updates")
    func aSustainedChangeIsReached() {
        var eta = ExportETA()
        eta.update(fraction: 0.5, elapsed: 10)
        // Eight updates at a quarter each closes 1 - 0.75^8 = 90% of the gap. Written as a
        // fraction of the distance rather than as an absolute, because that is the property
        // `smoothing` actually has and an absolute tolerance would be a number tuned to pass.
        for _ in 0..<8 { eta.update(fraction: 0.25, elapsed: 20) }
        let closed = ((eta.secondsRemaining ?? 0) - 10) / (60 - 10)
        #expect(closed > 0.85, "only \(Int(closed * 100))% of the way after eight updates")
        for _ in 0..<12 { eta.update(fraction: 0.25, elapsed: 20) }
        #expect(abs((eta.secondsRemaining ?? 0) - 60) < 1)
    }

    // MARK: - The reading

    /// **A value rather than a sentence, because a sentence cannot be translated.** The first
    /// version returned interpolated English, which is one string-table key per number.
    @Test("the reading is as precise as the estimate deserves and no more")
    func theReadingIsCoarse() {
        #expect(ExportETA.reading(3) == .aFewSeconds)
        #expect(ExportETA.reading(9.9) == .aFewSeconds)
        #expect(ExportETA.reading(38) == .seconds(40))
        #expect(ExportETA.reading(52) == .seconds(50))
        #expect(ExportETA.reading(70) == .aMinute)
        #expect(ExportETA.reading(200) == .minutes(3))
        #expect(ExportETA.reading(3600) == .anHour)
        #expect(ExportETA.reading(3600 * 2.4) == .hours(2))
    }

    /// **Every reading between ten seconds and an hour is one a person would say.**
    ///
    /// Written as a sweep rather than as examples, and it found one: rounding to the nearest ten
    /// inside a boundary of sixty made 55 seconds read as sixty seconds, which is a minute said
    /// the long way. Seconds must be a multiple of ten and never zero; minutes must never be
    /// zero or one, because those are `.aMinute`.
    @Test("every reading in the awkward range is something a person would say")
    func everyReadingIsSayable() {
        for tenths in stride(from: 100, through: 36_000, by: 7) {
            let seconds = Double(tenths) / 10
            guard let reading: ExportETA.Reading = ExportETA.reading(seconds) else {
                Issue.record("\(seconds)s produced no reading")
                continue
            }
            switch reading {
            case .aFewSeconds, .aMinute, .anHour:
                continue
            case .seconds(let value):
                #expect(value >= 10 && value <= 50 && value % 10 == 0,
                        "\(seconds)s read as \(value) seconds")
            case .minutes(let value):
                #expect(value >= 2 && value <= 54, "\(seconds)s read as \(value) minutes")
            case .hours(let value):
                #expect(value >= 2, "\(seconds)s read as \(value) hours")
            }
        }
    }

    /// `nil` rather than a placeholder, so a caller cannot render "— left" by accident.
    @Test("nothing to say is nothing, not a placeholder")
    func nothingIsNil() {
        #expect(ExportETA.reading(nil) == nil)
        #expect(ExportETA.reading(.nan) == nil)
        #expect(ExportETA.reading(-5) == nil)
        #expect(ExportETA.reading(.infinity) == nil)
    }
}
