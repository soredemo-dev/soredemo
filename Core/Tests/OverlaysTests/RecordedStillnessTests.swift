import Foundation
import Geometry
import Project
import Testing
import Timeline
@testable import Overlays

private let epoch = BootEpoch(id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)

private func table(_ segments: [(start: Int64, duration: Int64)]) throws -> SegmentTable {
    try SegmentTable(segments: segments.enumerated().map { index, s in
        MasterSegment(index: index, mediaFilename: "master-\(index).mov",
                      hostRange: HostRange(epoch: epoch, start: Nanoseconds(s.start),
                                           duration: Nanoseconds(s.duration)),
                      revision: GeometryRevision(id: 1),
                      endedBy: index == segments.count - 1 ? .stopped : .paused)
    })
}

private func still(from startNanos: Int64, to endNanos: Int64,
                   callbacksPerSecond: Double = 60) -> StillInterval {
    let seconds = Double(endNanos - startNanos) / 1_000_000_000
    return StillInterval(
        interval: HostRange(epoch: epoch, start: Nanoseconds(startNanos),
                            duration: Nanoseconds(endNanos - startNanos)),
        endedBy: .thePictureChanged,
        idleFrames: max(1, Int(seconds * callbacksPerSecond)))
}

private let second: Int64 = 1_000_000_000

/// A five-second still stretch inside one segment becomes one span, and the
/// padding is given back at each end exactly as the pixel path gives it back.
@Test func aRecordedStretchBecomesASpanWithTheSamePaddingThePixelPathUses() throws {
    let segments = try table([(start: 1_000 * second, duration: 60 * second)])
    let outcome = RecordedStillness.spans(recorded: [still(from: 1_010 * second, to: 1_015 * second)],
                                          in: segments)
    #expect(outcome.refused.isEmpty)
    #expect(outcome.spans.count == 1)
    let span = try #require(outcome.spans.first)
    // 10s into the segment, plus 0.3s of padding; 15s minus 0.3s.
    #expect(span.start.rawValue == 10 * second + 300_000_000)
    #expect(span.end.rawValue == 15 * second - 300_000_000)
}

/// The two paths must agree, or one recording gets two answers. Both are asked
/// for the same five-second stretch of a sixty-second recording.
@Test func theRecordedPathAndThePixelPathGiveTheSameSpan() throws {
    let segments = try table([(start: 0, duration: 60 * second)])
    let recorded = RecordedStillness.spans(recorded: [still(from: 10 * second, to: 15 * second)],
                                           in: segments)
    // The pixel path over the same recording: 0.25s slices, still from 10s to 15s.
    var changes = [Double](repeating: 1, count: 240)
    for slice in 40..<60 { changes[slice] = 0 }
    let pixels = StillnessFinder.spans(changes: changes, sliceSeconds: 0.25)

    #expect(pixels.count == 1)
    #expect(recorded.spans.count == 1)
    #expect(recorded.spans.first?.start == pixels.first?.start)
    #expect(recorded.spans.first?.end == pixels.first?.end)
}

/// A stretch shorter than the minimum is refused BY NAME, carrying what it
/// measured — a caller reporting "nothing found" over this would be wrong.
@Test func aStretchShorterThanTheMinimumIsRefusedByName() throws {
    let segments = try table([(start: 0, duration: 60 * second)])
    let outcome = RecordedStillness.spans(recorded: [still(from: 5 * second, to: 6 * second)],
                                          in: segments)
    #expect(outcome.spans.isEmpty)
    #expect(outcome.refused.count == 1)
    guard case .tooShortToCut(let measured) = outcome.refused.first?.refusal else {
        Issue.record("expected a named length refusal"); return
    }
    #expect(measured.rawValue == second)
}

/// Padding erases a stretch only just longer than the minimum — the pixel path's
/// stated behaviour, reproduced here.
///
/// It cannot happen at the default settings, and that is worth saying out loud:
/// the default minimum is 2s and the default padding gives back 0.6s in total,
/// so a stretch that passed the minimum always survives. Erasure needs settings
/// a person chose, which is exactly when it matters that both paths agree.
@Test func paddingErasesAStretchOnlyJustLongerThanTheMinimum() throws {
    let eager = StillnessFinder.Settings(changeThreshold: 0.0005, minimumSeconds: 0.5,
                                         paddingSeconds: 0.3)
    let segments = try table([(start: 0, duration: 60 * second)])
    let outcome = RecordedStillness.spans(recorded: [still(from: 5 * second, to: 5 * second + 500_000_000)],
                                          in: segments, settings: eager)
    #expect(outcome.spans.isEmpty)
    #expect(outcome.refused.count == 1)

    // The pixel path erases it too: two slices of stillness, 0.5s, same settings.
    var changes = [Double](repeating: 1, count: 12)
    changes[4] = 0; changes[5] = 0
    #expect(StillnessFinder.spans(changes: changes, sliceSeconds: 0.25, settings: eager).isEmpty)
}

/// The distinction `idleFrames` exists to draw. Two intervals of identical
/// length: one carries a working stream's callbacks, one carries a stalled
/// stream's, and only the first is stillness.
@Test func aStalledStreamIsRefusedWhereAStillPictureIsNot() throws {
    let segments = try table([(start: 0, duration: 60 * second)])
    let working = RecordedStillness.spans(recorded: [still(from: 10 * second, to: 20 * second,
                                                           callbacksPerSecond: 60)], in: segments)
    #expect(working.spans.count == 1)

    let stalled = RecordedStillness.spans(recorded: [still(from: 10 * second, to: 20 * second,
                                                           callbacksPerSecond: 0.2)], in: segments)
    #expect(stalled.spans.isEmpty)
    guard case .theStreamHadStalled(let rate) = stalled.refused.first?.refusal else {
        Issue.record("expected a stalled-stream refusal"); return
    }
    #expect(rate < RecordedStillness.slowestCallbackRateThatIsStillness)
}

/// An interval in the gap between two segments belongs to no content, and a
/// nearest-edge answer would cut footage nobody measured.
@Test func anIntervalInTheGapBetweenSegmentsIsRefused() throws {
    let segments = try table([(start: 0, duration: 10 * second),
                              (start: 30 * second, duration: 10 * second)])
    let outcome = RecordedStillness.spans(recorded: [still(from: 15 * second, to: 25 * second)],
                                          in: segments)
    #expect(outcome.spans.isEmpty)
    #expect(outcome.refused.first?.refusal == .itDoesNotLandInTheContent)
}

/// An interval spanning a pause is one the recorder cannot have written — it
/// closes an open run when the segment closes. Mapped through content time it
/// would still produce a plausible range, because a pause occupies no content,
/// and that plausible range is the trap: it would cut across a boundary nothing
/// measured. Refused instead.
@Test func anIntervalSpanningAPauseIsRefusedRatherThanMappedToAPlausibleRange() throws {
    let segments = try table([(start: 0, duration: 10 * second),
                              (start: 30 * second, duration: 10 * second)])
    let outcome = RecordedStillness.spans(recorded: [still(from: 5 * second, to: 35 * second)],
                                          in: segments)
    #expect(outcome.spans.isEmpty)
    #expect(outcome.refused.first?.refusal == .itDoesNotLandInTheContent)
}

/// The spans come back in order whatever order the intervals arrived in — the
/// timeline removes them back to front and needs to know which end is which.
@Test func theSpansComeBackInOrder() throws {
    let segments = try table([(start: 0, duration: 120 * second)])
    let outcome = RecordedStillness.spans(
        recorded: [still(from: 60 * second, to: 70 * second),
                   still(from: 10 * second, to: 20 * second),
                   still(from: 90 * second, to: 100 * second)],
        in: segments)
    #expect(outcome.spans.count == 3)
    #expect(outcome.spans.map(\.start.rawValue) == outcome.spans.map(\.start.rawValue).sorted())
}
