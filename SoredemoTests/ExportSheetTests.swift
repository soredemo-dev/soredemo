import Compositing
import Testing
@testable import Soredemo

/// The export sheet's time, priced from this Mac's last export.
@MainActor @Suite struct ExportSheetTests {
    /// **Priced from the measured rate**: 90 s of 1080p at 60 fps, at the M1 Pro's measured
    /// 441 million pixels a second, is about 25 s — "about 30 seconds" in the reading's tens.
    /// And at full Retina size the same take costs about three times as long, which is the
    /// choice the sheet exists to make visible.
    @Test func theTimeIsPricedFromThisMacsRate() {
        let rate = 600.0 * 3024 * 1964 / 8.07
        #expect(ExportSheet.estimate(seconds: 90, frameRate: 60, width: 1920, height: 1080,
                                     pixelsPerSecond: rate) == .seconds(30))
        #expect(ExportSheet.estimate(seconds: 90, frameRate: 60, width: 3024, height: 1964,
                                     pixelsPerSecond: rate) == .aMinute)
    }

    /// **No rate, no time** — the sheet says it will know after the first export, rather than
    /// quoting another Mac's engine.
    @Test func noMeasuredRateIsNoTime() {
        #expect(ExportSheet.estimate(seconds: 90, frameRate: 60, width: 1920, height: 1080,
                                     pixelsPerSecond: nil) == nil)
    }
}
