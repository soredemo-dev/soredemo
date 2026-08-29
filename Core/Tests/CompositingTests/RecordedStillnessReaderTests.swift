import Foundation
import Geometry
import Overlays
import Project
import Testing
import Timeline
@testable import Compositing

private let epoch = BootEpoch(id: UUID(uuidString: "0F0F0F0F-1111-2222-3333-444444444444")!)
private let second: Int64 = 1_000_000_000

/// The log is written here line by line rather than through `ObservationWriter`.
///
/// Not only because this target may not reach into `Capture` — the seam between
/// writer and reader belongs to the smoke chain — but because it makes these
/// the right tests: a reader should be held to the WIRE FORMAT, not to whatever
/// today's writer happens to emit. A writer and reader that drift together pass
/// a round trip and fail every recording already on disk.
private func writeLog(at url: URL, records: [any ObservationRecord],
                      declaringStill: Bool, hostRange: HostRange) throws {
    var lines: [Data] = []
    let header = ObservationLogHeader(
        anchor: EpochAnchor(epoch: epoch, hostTime: Nanoseconds(0), wallClockUnixNanos: 0),
        segmentIndex: 0, mediaFilename: "master-00.mov",
        revision: GeometryRevision(id: 1), blindness: [])
    lines.append(try ObservationLog.encode(header))
    for record in records { lines.append(try ObservationLog.encode(record)) }
    var counts: [String: Int] = [:]
    if declaringStill { counts["still"] = 0 }
    for record in records { counts[record.kind, default: 0] += 1 }
    lines.append(try ObservationLog.encode(ObservationLogTrailer(
        segmentIndex: 0, hostRange: hostRange, endedBy: SegmentBoundary.stopped,
        recordCounts: counts,
        gapWatches: GapSite.allCases.map {
            GapWatch(site: $0, looks: 0, watchedSpanNanos: 0, gapsFound: 0, lost: 0)
        })))
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    var bytes = Data()
    for line in lines { bytes.append(line); bytes.append(0x0A) }
    try bytes.write(to: url)
}

private func scratchLog() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "still-reader-\(UUID().uuidString)", directoryHint: .isDirectory)
        .appending(path: "segment-00.jsonl")
}

/// A recorded interval read out of a log and turned into a span — the reader and
/// `RecordedStillness` together, because each passing alone says nothing about
/// the seam between them.
@Test func aRecordedIntervalBecomesASpanWithTheSegmentTableItIsReadAgainst() throws {
    let url = scratchLog()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let hostRange = HostRange(epoch: epoch, start: Nanoseconds(0), duration: Nanoseconds(60 * second))
    try writeLog(at: url, records: [StillInterval(
        interval: HostRange(epoch: epoch, start: Nanoseconds(10 * second),
                            duration: Nanoseconds(5 * second)),
        endedBy: .thePictureChanged, idleFrames: 300)],
                 declaringStill: true, hostRange: hostRange)

    guard case .recorded(let intervals) = try RecordedStillnessReader
        .intervals(fromObservationLogsAt: [url]) else {
        Issue.record("expected the log's still lines to be read back"); return
    }
    #expect(intervals.count == 1)
    #expect(intervals.first?.idleFrames == 300)

    let table = try SegmentTable(segments: [
        MasterSegment(index: 0, mediaFilename: "master-00.mov", hostRange: hostRange,
                      revision: GeometryRevision(id: 1), endedBy: .stopped)])
    let outcome = RecordedStillness.spans(recorded: intervals, in: table)
    #expect(outcome.refused.isEmpty)
    #expect(outcome.spans.count == 1)
    #expect(outcome.spans.first?.start.rawValue == 10 * second + 300_000_000)
    #expect(outcome.spans.first?.end.rawValue == 15 * second - 300_000_000)
}

/// The three-way answer, both halves of it. A log that DECLARED the kind and
/// held none is a measurement — the picture never stopped changing — and
/// decoding it would only confirm that. A log that never declared it predates
/// the timeline and says nothing either way.
///
/// This is what `ObservationWriter.declareRecordKind` is for, and without it the
/// two logs below would differ in nothing at all.
@Test func neverStillAndNeverRecordedAreDifferentAnswers() throws {
    let hostRange = HostRange(epoch: epoch, start: Nanoseconds(0), duration: Nanoseconds(second))
    let declared = scratchLog(), silent = scratchLog()
    defer {
        for url in [declared, silent] {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }
    try writeLog(at: declared, records: [], declaringStill: true, hostRange: hostRange)
    try writeLog(at: silent, records: [], declaringStill: false, hostRange: hostRange)

    #expect(try RecordedStillnessReader.intervals(fromObservationLogsAt: [declared])
            == .nothingWasEverStill)
    #expect(try RecordedStillnessReader.intervals(fromObservationLogsAt: [silent])
            == .theRecordingDoesNotCarryIt)
}

/// A log truncated before its trailer — a crash mid-recording — sends the caller
/// to the picture rather than claiming nothing was ever still. Right either way,
/// and only the safe direction costs time.
@Test func aLogTruncatedBeforeItsTrailerSendsTheCallerToThePicture() throws {
    let url = scratchLog()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let header = ObservationLogHeader(
        anchor: EpochAnchor(epoch: epoch, hostTime: Nanoseconds(0), wallClockUnixNanos: 0),
        segmentIndex: 0, mediaFilename: "master-00.mov",
        revision: GeometryRevision(id: 1), blindness: [])
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    var bytes = try ObservationLog.encode(header)
    bytes.append(0x0A)
    try bytes.write(to: url)

    #expect(try RecordedStillnessReader.intervals(fromObservationLogsAt: [url])
            == .theRecordingDoesNotCarryIt)
}
