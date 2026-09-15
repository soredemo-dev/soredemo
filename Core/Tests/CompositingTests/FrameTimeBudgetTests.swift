import CoreMedia
import Foundation
import Overlays
import Render
import Testing
import Timeline
@testable import Compositing

// MARK: - how long one frame is allowed to take

/// **A frame budget exists to catch a regression, not to certify a machine.**
///
/// The preview and the export run the same compositor — that is what `render-parity` means — so
/// a frame that got slower makes a preview stutter and an export crawl at the same time, and
/// nothing here measured it until now. The O(n²) `CameraMotion` once shipped and was found by a
/// person watching a recording stutter; this is the instrument that would have found it first.
///
/// **Measured 2026-09-05** on Apple Silicon, sixty renders after a five-render warm-up:
///
///     1080p   median 3.61 ms   p90 4.95   p99 5.76
///     4K      median 8.69 ms   p90 9.88   p99 11.48
///
/// **Re-measured 2026-09-15 on macOS 27, and the budgets came DOWN**: 1080p 2.5 ms, 4K 7.2. The
/// platform got faster, and budgets set against the old figures had quietly become 4.8x and
/// 3.5x the median instead of the 3x they are meant to be. A budget a regression can hide
/// inside is not a budget.
///
/// **The first two runs after the upgrade said 4.87 and 4.73 and were wrong.** The machine had
/// just finished a full build; the next two said 2.61 and 2.47. Which way the evidence pointed
/// is the useful part: the fastest FRAME had got faster (2.54 -> 2.29) while the median got
/// slower, and that is a distribution widening under load rather than a compositor slowing
/// down. A measurement taken straight after a build is a measurement of the build.
///
/// The budgets below are about three times those medians. Loose on purpose: this runs on
/// whatever machine a person has, beside a full Xcode, and a budget tuned to one laptop fails on
/// the next one for a reason that has nothing to do with the code. Three times is far more than
/// scheduling noise and far less than an algorithmic regression, which is the only thing a
/// budget like this can honestly claim to catch.
///
/// **The MEDIAN is asserted and the tail is only reported.** A single slow sample on a machine
/// also compiling something is scheduling, not the compositor — the same reason § 28's memory
/// section asserts a slope and reports the peak.
@Suite struct FrameTimeBudgetTests {
    /// One warm-up render is not enough: the first compiles Core Image's kernels and the second
    /// still pays for the pool. Five is where the spread stopped moving.
    static let warmUp = 5
    static let samples = 60

    /// Two decimals, in one place.
    ///
    /// **`unsafe` once here rather than at every call site.** `String(format:)` is a C variadic
    /// and the compiler cannot see that the format string matches its argument. It does — one
    /// `%.2f` and one `Double` — and the alternative is rounding arithmetic that says less about
    /// what the number is than the number does.
    static func ms(_ value: Double) -> String { unsafe String(format: "%.2f", value) }

    struct Timing {
        let median: Double
        let p90: Double
        let p99: Double
        /// The fastest frame of the run — the one with the least interference in it, which is
        /// what a comparison BETWEEN two runs wants. See the ratio test for why.
        let min: Double
    }

    static func time(width: Int, height: Int) throws -> Timing? {
        let renderer: CoreImageFrameRenderer
        do { renderer = try CoreImageFrameRenderer() } catch FrameRenderingError.noRenderDevice {
            Issue.record("no Metal render device on this machine — a real answer, not a skip")
            return nil
        }
        let source = try makePixelBuffer(width: width, height: height, fill: (40, 90, 160))
        let destination = try makePixelBuffer(width: width, height: height, fill: (0, 0, 0))
        let base = StagePlanner.plan(outputWidth: width, outputHeight: height,
                                     sourceWidth: width, sourceHeight: height, style: .default)
        // A cursor with a ripple in flight, because a frame with nothing on it measures the
        // cheapest case and the cheapest case is not the one that stutters.
        let plan = RenderPlan(outputWidth: base.outputWidth, outputHeight: base.outputHeight,
                              card: base.card, cornerRadius: base.cornerRadius,
                              style: base.style,
                              pointer: NormalizedPointerPlacement(
                                  x: Double(width) / 2, y: Double(height) / 2,
                                  ripplePhase: 0.4, shape: .arrow))

        for _ in 0..<warmUp {
            try renderer.render(plan, source: source, camera: nil, into: destination)
        }
        let clock = ContinuousClock()
        var timings: [Double] = []
        for _ in 0..<samples {
            var rendered = false
            let took = clock.measure {
                do { try renderer.render(plan, source: source, camera: nil, into: destination)
                     rendered = true } catch { }
            }
            // The work must have happened, or this measures an early return.
            guard rendered else { Issue.record("a render failed mid-measurement"); return nil }
            timings.append(Double(took.components.seconds) * 1000
                           + Double(took.components.attoseconds) / 1e15)
        }
        timings.sort()
        return Timing(median: timings[samples / 2],
                      p90: timings[Int(Double(samples) * 0.9)],
                      p99: timings[samples - 1],
                      min: timings[0])
    }

    @Test func aFrameAt1080pStaysWellInsideItsBudget() throws {
        guard let timing = try Self.time(width: 1920, height: 1080) else { return }
        #expect(timing.median < 8, """
            1080p median \(Self.ms(timing.median)) ms, budget 8 — measured at \
            2.5 on macOS 27, so this is a threefold regression rather than a slow machine. \
            p90 \(Self.ms(timing.p90)), p99 \(Self.ms(timing.p99)).
            """)
    }

    @Test func aFrameAt4KStaysWellInsideItsBudget() throws {
        guard let timing = try Self.time(width: 3840, height: 2160) else { return }
        #expect(timing.median < 22, """
            4K median \(Self.ms(timing.median)) ms, budget 22 — measured at 7.2 \
            on macOS 27. p90 \(Self.ms(timing.p90)), \
            p99 \(Self.ms(timing.p99)).
            """)
    }

    /// **Four times the pixels does not cost four times the time, and that is the shape worth
    /// pinning.** A compositor whose cost went linear in pixels would still pass both budgets
    /// above on a fast machine while being wrong; the ratio catches what an absolute number on
    /// one laptop cannot.
    ///
    /// **The FASTEST frame of each, not the median — and that is a better measurement, not a
    /// looser one.** Measured at 2.4x, this failed once at 4.13x inside a full suite run on a
    /// machine that was also compiling, and passed three times out of three in isolation. The
    /// two sizes are timed one after the other, so a burst of load lands on one of them and not
    /// the other, and a ratio of two medians carries that difference straight into the verdict.
    /// The minimum is the standard answer: the fastest observed frame is the one with the least
    /// interference in it, so min ÷ min is the closest thing to the two costs compared on an
    /// idle machine. The medians keep the two budgets above, where a typical frame is the
    /// question being asked.
    @Test func fourTimesThePixelsCostsLessThanFourTimesTheTime() throws {
        guard let small = try Self.time(width: 1920, height: 1080),
              let large = try Self.time(width: 3840, height: 2160) else { return }
        let ratio = large.min / small.min
        #expect(ratio < 4, """
            4K costs \(Self.ms(ratio))x 1080p at each one's fastest frame \
            (\(Self.ms(small.min)) ms and \(Self.ms(large.min)) ms) — measured at 2.4x. \
            Above 4 the compositor has stopped amortising anything across the frame.
            """)
    }
}
