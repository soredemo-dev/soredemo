import Testing
@testable import Compositing

/// The export's speed, measured once and used to price the next one. **Not square and not 1080p**,
/// and a rate with no round numbers in it, so an expression with width and height swapped, or one
/// that forgot a factor, cannot land on the right answer by accident.
@Test func aFinishedExportGivesTheRateAndTheRatePricesTheNext() throws {
    // Measured shape: 600 frames of 3024 × 1964 in 8.07 s, the M1 Pro figure.
    let rate = try #require(ExportThroughput.pixelsPerSecond(frames: 600, width: 3024, height: 1964, seconds: 8.07))
    #expect(abs(rate - 600.0 * 3024 * 1964 / 8.07) < 1)
    // At that rate, 1800 frames of 1920 × 1080 take 1800·1920·1080 / rate seconds.
    let next = try #require(ExportThroughput.seconds(frames: 1800, width: 1920, height: 1080, pixelsPerSecond: rate))
    #expect(abs(next - 1800.0 * 1920 * 1080 / rate) < 0.001)
}

/// **A measurement that could not be taken is not a rate.** Nothing counted, or no time passed,
/// is `nil` — never a number that would then price every later export.
@Test func nothingMeasuredIsNoRateAndNoRateIsNoEstimate() {
    #expect(ExportThroughput.pixelsPerSecond(frames: 0, width: 1920, height: 1080, seconds: 3) == nil)
    #expect(ExportThroughput.pixelsPerSecond(frames: 60, width: 0, height: 1080, seconds: 3) == nil)
    #expect(ExportThroughput.pixelsPerSecond(frames: 60, width: 1920, height: 1080, seconds: 0) == nil)
    #expect(ExportThroughput.pixelsPerSecond(frames: 60, width: 1920, height: 1080, seconds: .nan) == nil)
    #expect(ExportThroughput.seconds(frames: 60, width: 1920, height: 1080, pixelsPerSecond: 0) == nil)
    #expect(ExportThroughput.seconds(frames: 60, width: 1920, height: 1080, pixelsPerSecond: -5) == nil)
}
