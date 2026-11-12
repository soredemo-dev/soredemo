import CoreMedia
import Metal
import CoreImage
import Foundation
import Overlays
import Render
import Testing
import Timeline
@testable import Compositing

/// **Whether this run is instrumented for code coverage, and why these tests sit out of it.**
///
/// `scripts/coverage.sh` builds with `--enable-code-coverage`, which puts a counter on every
/// branch of the renderer. Measured 2026-09-18: the same 1080p frame that takes a median of
/// 2.5 ms in gate 1 crossed its 8 ms budget under that build, so the coverage gate went red on
/// a number that says nothing about the product — while gate 1, running the same test
/// uninstrumented, stayed green. A timing measured through instrumentation is a measurement of
/// the instrumentation.
///
/// **Disabled with a reason rather than the budget being widened.** A budget loose enough for
/// an instrumented run cannot catch a real regression in the run that matters. `.enabled(if:)`
/// rather than a `#require`, which records a FAILURE — the first repair of this did that and
/// turned one red into two.
///
/// Set by `coverage.sh` and by nothing else, so an ordinary `swift test` still asserts.
private var isInstrumentedForCoverage: Bool {
    ProcessInfo.processInfo.environment["SOREDEMO_COVERAGE"] == "1"
}

/// **Whether this run is on a hosted CI runner, and why the absolute budgets sit out of it.**
///
/// GitHub's macOS runner is a virtual machine with a paravirtualised GPU. Measured 2026-11-12:
/// the same commit whose 1080p frame takes 2.9–4.3 ms here took 11.8 and then 14.5 ms there, and
/// its 4K frame 28.9 and 36.3 ms against 7.7–10.1 here — the code before and after the push
/// timed identically on this Mac, so the difference was the machine. A millisecond budget is a
/// statement about a machine; on a machine it does not describe it fails for nothing.
///
/// **Not widened, replaced there**: `theFrameStaysWithinItsMultipleOfAPlainRenderOnThisMachine`
/// times a compositor-independent Core Image pass in the same run and holds the frame to a
/// multiple of it, which a slow machine and a fast one judge alike. Set by GitHub Actions itself.
private var isOnAHostedRunner: Bool {
    ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"
}

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

    @Test(.enabled(if: !isInstrumentedForCoverage && !isOnAHostedRunner))
    func aFrameAt1080pStaysWellInsideItsBudget() throws {
        guard let timing = try Self.time(width: 1920, height: 1080) else { return }
        #expect(timing.median < 8, """
            1080p median \(Self.ms(timing.median)) ms, budget 8 — measured at \
            2.5 on macOS 27, so this is a threefold regression rather than a slow machine. \
            p90 \(Self.ms(timing.p90)), p99 \(Self.ms(timing.p99)).
            """)
    }

    @Test(.enabled(if: !isInstrumentedForCoverage && !isOnAHostedRunner))
    func aFrameAt4KStaysWellInsideItsBudget() throws {
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
    @Test(.enabled(if: !isInstrumentedForCoverage))
    func fourTimesThePixelsCostsLessThanFourTimesTheTime() throws {
        guard let small = try Self.time(width: 1920, height: 1080),
              let large = try Self.time(width: 3840, height: 2160) else { return }
        let ratio = large.min / small.min
        #expect(ratio < 4, """
            4K costs \(Self.ms(ratio))x 1080p at each one's fastest frame \
            (\(Self.ms(small.min)) ms and \(Self.ms(large.min)) ms) — measured at 2.4x. \
            Above 4 the compositor has stopped amortising anything across the frame.
            """)
    }

    /// A plain Core Image pass at the same size on the same machine — a resample and a blur, no
    /// compositor — so the frame can be judged against this machine rather than against a laptop.
    /// Same context options as the renderer, so the two differ in the compositor's work only.
    static func baseline(width: Int, height: Int) throws -> Double {
        guard let device = MTLCreateSystemDefaultDevice() else { throw FrameRenderingError.noRenderDevice }
        let context = CIContext(mtlDevice: device, options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                             .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        let source = try makePixelBuffer(width: width, height: height, fill: (40, 90, 160))
        let destination = try makePixelBuffer(width: width, height: height, fill: (0, 0, 0))
        let image = CIImage(cvPixelBuffer: source)
        let extent = image.extent
        func once() {
            let work = image.clampedToExtent()
                .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 0.999, kCIInputAspectRatioKey: 1])
                .applyingGaussianBlur(sigma: 4).cropped(to: extent)
            context.render(work, to: destination)
        }
        for _ in 0..<warmUp { once() }
        let clock = ContinuousClock()
        var timings: [Double] = []
        for _ in 0..<samples {
            let took = clock.measure { once() }
            timings.append(Double(took.components.seconds) * 1000 + Double(took.components.attoseconds) / 1e15)
        }
        timings.sort()
        return timings[samples / 2]
    }

    /// **The frame against this machine, not against a laptop.** Measured 2026-11-13, four runs:
    /// the frame's median over the plain pass's was 4.3–4.7x at 1080p and 5.8–7.5x at 4K. The
    /// limits are about three times those, the same looseness the absolute budgets keep, for the
    /// same reason: far more than noise, far less than an algorithmic regression. This is what
    /// stands for the absolute budgets on a hosted runner, and it runs everywhere.
    @Test(.enabled(if: !isInstrumentedForCoverage), arguments: [(1920, 1080, 14.0), (3840, 2160, 20.0)])
    func theFrameStaysWithinItsMultipleOfAPlainRenderOnThisMachine(width: Int, height: Int, limit: Double) throws {
        guard let frame = try Self.time(width: width, height: height) else { return }
        let plain = try Self.baseline(width: width, height: height)
        let multiple = frame.median / plain
        #expect(multiple < limit, """
            \(width)x\(height): the frame's median \(Self.ms(frame.median)) ms is \(Self.ms(multiple))x a plain \
            Core Image pass's \(Self.ms(plain)) ms on this machine; the limit is \(Self.ms(limit))x — measured \
            at 4.3–4.7x (1080p) and 5.8–7.5x (4K). Above it the compositor got slower, whatever the machine.
            """)
    }
}
