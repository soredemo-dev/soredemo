import Testing
import Foundation
@testable import Capture

// The rolling clip buffer is a second encode of every frame, and on 2026-09-22 it was measured
// costing 40% of the delivered frame rate at 3492 x 1964: 112.1 and 112.2 fps without it, 66.9
// and 67.7 with, the conditions interleaved so the figure is the buffer's and not a thermal
// slope. What is pinned here is the rule that decides when to give it up.

private let second: Int64 = 1_000_000_000

@Test func aRecordingGettingTheRateItAskedForKeepsItsClipBuffer() {
    // 60 delivered against 60 asked for.
    #expect(CaptureSession.clipBufferVerdict(framesInWindow: 90, windowNanos: second + second / 2,
                                             requestedFrameRate: 60) == nil)
}

@Test func aSmallShortfallIsJitterAndNotAVerdict() {
    // 58 fps against 60 — inside the floor, so nothing is dropped. A rule that fired here would
    // take the feature away from every recording on every machine.
    let frames = Int((58.0 * 1.5).rounded())
    #expect(CaptureSession.clipBufferVerdict(framesInWindow: frames,
                                             windowNanos: second + second / 2,
                                             requestedFrameRate: 60) == nil)
}

/// The measured case: a 3492 x 1964 recording that asked for 60 and was given 38.
@Test func theMeasuredShortfallDropsTheClipBuffer() {
    let verdict = CaptureSession.clipBufferVerdict(framesInWindow: 57,
                                                   windowNanos: second + second / 2,
                                                   requestedFrameRate: 60)
    #expect(verdict != nil)
    #expect(abs((verdict?.delivered ?? 0) - 38) < 0.001)
    #expect(verdict?.wanted == 60)
}

/// **The rule is a ratio, so it says the same thing at every rate.** A pixel budget would have
/// been this machine's number; this one holds on a 120 fps recording and a 30 fps one alike.
@Test func theSameShortfallIsJudgedTheSameAtEveryRequestedRate() {
    for rate in [30, 60, 120] {
        let comfortable = Int((Double(rate) * 0.95 * 1.5).rounded())
        let starved = Int((Double(rate) * 0.60 * 1.5).rounded())
        #expect(CaptureSession.clipBufferVerdict(framesInWindow: comfortable,
                                                 windowNanos: second + second / 2,
                                                 requestedFrameRate: rate) == nil,
                "\(rate) fps: 95% of the asked-for rate should not drop the buffer")
        #expect(CaptureSession.clipBufferVerdict(framesInWindow: starved,
                                                 windowNanos: second + second / 2,
                                                 requestedFrameRate: rate) != nil,
                "\(rate) fps: 60% of the asked-for rate should drop it")
    }
}

/// A stream that delivered nothing has not shown the clip buffer is expensive — it has shown
/// something else is wrong, and taking a feature away over that blames the wrong thing.
@Test func aWindowThatMeasuredNothingIsNotAVerdict() {
    #expect(CaptureSession.clipBufferVerdict(framesInWindow: 0, windowNanos: second,
                                             requestedFrameRate: 60) == nil)
    #expect(CaptureSession.clipBufferVerdict(framesInWindow: 40, windowNanos: 0,
                                             requestedFrameRate: 60) == nil)
    #expect(CaptureSession.clipBufferVerdict(framesInWindow: 40, windowNanos: second,
                                             requestedFrameRate: 0) == nil)
}

// MARK: - when it attaches, which is what "開頭卡" turned out to be

/// **The opening of a recording never carries the clip buffer.** Measured 2026-09-22 through the
/// real `CaptureSession`, reading the master file back: with the buffer attached at stream start
/// the first 2.5 s delivered about 35 fps, and the same run delivered about 48 fps the moment the
/// watchdog dropped it. The clip buffer's second encode only costs when it runs beside the master's
/// — a bare stream with it held 86 fps — so the cost landed exactly on the first seconds of every
/// recording, which is the part of a video people watch most closely.
@Test func theOpeningSecondOfARecordingCarriesNoClipBuffer() {
    #expect(!CaptureSession.clipBufferIsDue(sinceOpenNanos: 0))
    #expect(!CaptureSession.clipBufferIsDue(sinceOpenNanos: 500_000_000))
    #expect(!CaptureSession.clipBufferIsDue(sinceOpenNanos: CaptureSession.clipBufferAttachDelayNanos - 1))
    #expect(CaptureSession.clipBufferIsDue(sinceOpenNanos: CaptureSession.clipBufferAttachDelayNanos))
}

/// A delay of zero is the design this replaced, so it is pinned away from zero by name.
@Test func theClipBufferWaitsAtLeastASecond() {
    #expect(CaptureSession.clipBufferAttachDelayNanos >= 1_000_000_000)
}
