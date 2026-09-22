import Testing
@testable import Capture

// Whether a recording should carry the rolling clip buffer, decided BEFORE it is attached.
//
// `SCClipBufferingOutput` has no configuration — its header offers `initWithDelegate:` and an
// export, and nothing else — so its second encode cannot be made cheaper. Measured 2026-09-22
// through the real `CaptureSession` at 3492 x 1964, within one run so machine load could not
// confound it: 58 fps before it attached, 28-34 while attached, 58 again the instant it was
// dropped. Attaching and then judging always puts a stutter somewhere in the video. The only
// stutter-free answer is to know beforehand, and the only machine-independent way to know is to
// remember what this machine already measured.

private let big = ClipBufferFit.load(width: 3492, height: 1964, frameRate: 60)
private let small = ClipBufferFit.load(width: 1920, height: 1080, frameRate: 60)

@Test func withNothingLearnedEveryRecordingTriesTheClipBuffer() {
    // A fresh install has measured nothing, and the feature's value is that nobody had to ask.
    #expect(ClipBufferFit.unmeasured.attaches(atLoad: big))
    #expect(ClipBufferFit.unmeasured.attaches(atLoad: small))
}

/// The case that was reported: the buffer was dropped at the large size, so the next large
/// recording must not pay for it again.
@Test func onceDroppedAtALoadItIsNotAttachedAtThatLoadAgain() {
    let learned = ClipBufferFit.unmeasured.learning(load: big, wasDropped: true)
    #expect(!learned.attaches(atLoad: big))
    // Nor at anything heavier, which costs more by construction.
    #expect(!learned.attaches(atLoad: big * 2))
}

/// **Learning about the large size must not take the feature away from the small one**, where
/// it was measured working (81 fps with it attached at 1920 x 1080).
@Test func aDropAtALargeLoadLeavesSmallerOnesAlone() {
    let learned = ClipBufferFit.unmeasured.learning(load: big, wasDropped: true)
    #expect(learned.attaches(atLoad: small))
}

/// **It can be taken back.** A buffer that was kept at or above the learned threshold means this
/// machine can afford it after all — a quieter moment, a newer OS — and the threshold that was
/// refusing it has been disproved by a measurement. Without this, one bad afternoon would switch
/// the feature off at that size forever.
@Test func aBufferKeptAtTheLearnedLoadDisprovesTheThreshold() {
    let learned = ClipBufferFit.unmeasured.learning(load: big, wasDropped: true)
    let relearned = learned.learning(load: big, wasDropped: false)
    #expect(relearned.attaches(atLoad: big))
}

/// The threshold only ever tightens on a drop — a drop at a SMALLER load lowers it, a drop at a
/// larger one tells it nothing new.
@Test func theThresholdIsTheSmallestLoadThatDidNotFit() {
    let a = ClipBufferFit.unmeasured.learning(load: big, wasDropped: true)
    let b = a.learning(load: small, wasDropped: true)
    #expect(b.smallestLoadThatDidNotFit == small)
    let c = b.learning(load: big, wasDropped: true)
    #expect(c.smallestLoadThatDidNotFit == small)
}

/// Load is pixels per second, because that is what the two encoders share. The same pixels at
/// twice the rate is twice the load.
@Test func loadIsPixelsPerSecond() {
    #expect(ClipBufferFit.load(width: 100, height: 100, frameRate: 60)
            == 2 * ClipBufferFit.load(width: 100, height: 100, frameRate: 30))
    #expect(ClipBufferFit.load(width: 200, height: 100, frameRate: 60)
            == 2 * ClipBufferFit.load(width: 100, height: 100, frameRate: 60))
}
