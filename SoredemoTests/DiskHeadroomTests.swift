import Testing
import Foundation
@testable import Soredemo

/// **A full disk mid-take used to be a lost take** — the writer fails, and nothing could be
/// recovered (audit R1, R3). So: an estimate before the take, and a measurement during it.
/// `docs/design/2026-10-22-audit-and-how-to-stand-out.md`.
@Suite struct DiskHeadroomTests {
    private let megabyte: Int64 = 1_000_000

    /// The master's own arithmetic (`MasterQuality.videoBitRate`) plus two float stereo audio
    /// tracks at 48 kHz. 3024 × 1964 at 60 fps — this MacBook's whole display — is about 85 Mbps.
    @Test func aTakeOfTheWholeDisplayCostsWhatTheMasterSpends() {
        let rate = DiskHeadroom.bytesPerSecond(pixelWidth: 3024, pixelHeight: 1964, frameRate: 60)
        let video = Double(3024 * 1964) * 0.3 * 48 / 8
        let audio = 2.0 * 48_000 * 2 * 4
        #expect(abs(rate - (video + audio)) < 1)
    }

    /// **Twice the bytes, because a finished segment exists twice for a moment** — its scratch
    /// file and its copy in the package — so the take that fits is half what free space suggests.
    @Test func theMinutesLeftCountTheSegmentsCopy() {
        let minutes = DiskHeadroom.minutes(available: 1_200 * megabyte, bytesPerSecond: 10_000_000)
        #expect(abs(minutes - 1.0) < 0.001)
    }

    @Test func aTakeThatWouldNotLastAMinuteIsRefusedAndOneUnderTenIsWarned() {
        let rate = 10_000_000.0
        #expect(DiskHeadroom.verdict(available: 1_000 * megabyte, bytesPerSecond: rate) == .tooLittle)
        #expect(DiskHeadroom.verdict(available: 6_000 * megabyte, bytesPerSecond: rate) == .low(minutes: 5))
        #expect(DiskHeadroom.verdict(available: 60_000 * megabyte, bytesPerSecond: rate) == .plenty)
        // Unknown free space is not a reason to stop somebody recording.
        #expect(DiskHeadroom.verdict(available: nil, bytesPerSecond: rate) == .plenty)
    }

    // MARK: - during the take, measured

    /// **Measured, not estimated**: the free space falling is everything writing to the disk,
    /// this app and every other. The take stops — and is saved — while there is still room for
    /// the segment's copy plus one more minute at the rate the disk is actually filling.
    @Test func theTakeStopsWhileItCanStillBeSaved() {
        var watch = DiskWatch()
        // Start: 10 GB free. Filling at 100 MB/s.
        var free: Int64 = 10_000 * megabyte
        var stopped = false
        var seconds = 0
        while !stopped && seconds < 200 {
            stopped = watch.observe(free: free, after: 1) == .stopNow
            free -= 100 * megabyte
            seconds += 1
        }
        // Written S, free F: stop when F < S + 60 s × 100 MB/s. 10000 − 100t < 100t + 6000 → t > 20.
        #expect(stopped)
        #expect((20...22).contains(seconds), "stopped after \(seconds) s")
        // Whatever it chose, the copy still fits: free at the stop covers what was written.
        #expect(free + 100 * megabyte >= 10_000 * megabyte - free)
    }

    @Test func aDiskWithRoomNeverStopsTheTake() {
        var watch = DiskWatch()
        var free: Int64 = 500_000 * megabyte
        for _ in 0..<600 {
            #expect(watch.observe(free: free, after: 1) == .fine)
            free -= 10 * megabyte
        }
    }

    /// A pause closes the segment and its copy is made, so the next segment starts its count
    /// again from the free space at resume.
    @Test func aNewSegmentStartsItsOwnCount() {
        var watch = DiskWatch()
        // 8000 MB free, filling at 100 MB/s. Eleven seconds is the last moment the first segment
        // is fine: 7000 free against 1000 written + 6000 for a minute.
        var free: Int64 = 8_000 * megabyte
        for _ in 0...10 {
            #expect(watch.observe(free: free, after: 1) == .fine)
            free -= 100 * megabyte
        }
        watch.segmentBegan()
        // 6900 MB free. Counted from the resume, nothing is written yet: fine. Counted from the
        // first segment's start, 1100 written + 6000 would be over it — which is the count a
        // missing reset would keep, and the take it would stop for no reason.
        #expect(watch.observe(free: free, after: 1) == .fine)
    }

    /// Unknown free space measures nothing and stops nothing.
    @Test func anUnreadableDiskStopsNothing() {
        var watch = DiskWatch()
        #expect(watch.observe(free: nil, after: 1) == .fine)
    }
}
