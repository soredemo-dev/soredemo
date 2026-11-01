import Testing
import Foundation
import CoreMedia
import Geometry
import Project
import Render
import Timeline
@testable import Compositing

private let epoch = BootEpoch(id: UUID(uuidString: "2B2B2B2B-3C3C-4D4D-5E5E-6F6F6F6F6F6F")!)
private let second: Int64 = 1_000_000_000

/// Written line by line rather than through `ObservationWriter`, for
/// `RecordedStillnessReaderTests`' reason: a reader belongs to the WIRE FORMAT, not to
/// whatever today's writer emits. A writer and reader that drift together pass a round trip
/// and fail every recording already on disk.
private func writeLog(at url: URL, crops: [ContentCropSample]) throws {
    let header = ObservationLogHeader(
        anchor: EpochAnchor(epoch: epoch, hostTime: Nanoseconds(0), wallClockUnixNanos: 0),
        segmentIndex: 0, mediaFilename: "master-00.mov",
        revision: GeometryRevision(id: 1), blindness: [])
    var lines: [Data] = [try ObservationLog.encode(header)]
    for crop in crops { lines.append(try ObservationLog.encode(crop)) }
    lines.append(try ObservationLog.encode(ObservationLogTrailer(
        segmentIndex: 0,
        hostRange: HostRange(epoch: epoch, start: Nanoseconds(0), duration: Nanoseconds(10 * second)),
        endedBy: SegmentBoundary.stopped,
        recordCounts: ["contentCrop": crops.count],
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
        .appending(path: "content-crop-\(UUID().uuidString)", directoryHint: .isDirectory)
        .appending(path: "segment-00.jsonl")
}

// A timescale of 600, not a nanosecond one: `CMTimeScale` is `Int32` and a billion overflows
// nothing but says the wrong thing about what this test is measuring, which is seconds.
private func at(_ seconds: Int64) -> CMTime { CMTime(value: seconds * 600, timescale: 600) }

/// Must EXTEND `StageCompositorTests`: `.serialized` does not serialise sibling top-level
/// suites, and every one of these writes the same process-global `observationLogURL`.
extension StageCompositorTests {

    /// **The case that keeps every existing project rendering exactly as it did.** A recording
    /// made before `ContentCropSample` existed, and every imported one, has no such record —
    /// and the whole buffer is what those have always been treated as.
    @Test func aRecordingWhoseLogNeverSaidIsCroppedNotAtAll() throws {
        let url = scratchLog()
        try writeLog(at: url, crops: [])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        StageCompositor.observationLogURL = url
        StageCompositor.overrides = []
        defer { StageCompositor.observationLogURL = nil }

        #expect(StageCompositor().contentCrop(at: at(0)) == .whole)
        #expect(StageCompositor().contentCrop(at: at(5)) == .whole)
    }

    @Test func noConfiguredLogCropsNotAtAll() {
        StageCompositor.observationLogURL = nil
        StageCompositor.overrides = []
        #expect(StageCompositor().contentCrop(at: at(0)) == .whole)
    }

    /// The whole read path, from the bytes on disk to the answer one frame gets: a window that
    /// filled its buffer for two seconds and was then shrunk so that it filled 1419 columns of
    /// 1600 — the measured geometry, and the 181 columns of background down the right that are
    /// the bug this repairs.
    @Test func aResizeInTheLogMovesTheCropAtTheFrameItHappened() throws {
        let shrunk = CropRect(x: 0, y: 0, width: 1419.0 / 1600, height: 1)
        let url = scratchLog()
        try writeLog(at: url, crops: [
            ContentCropSample(instant: HostInstant(epoch: epoch, hostTime: Nanoseconds(0)),
                              content: .whole, contentScale: 1),
            ContentCropSample(instant: HostInstant(epoch: epoch, hostTime: Nanoseconds(2 * second)),
                              content: shrunk, contentScale: 1.7733),
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        StageCompositor.observationLogURL = url
        StageCompositor.overrides = []
        defer { StageCompositor.observationLogURL = nil }

        let compositor = StageCompositor()
        #expect(compositor.contentCrop(at: at(0)) == .whole)
        #expect(compositor.contentCrop(at: at(1)) == .whole)
        #expect(compositor.contentCrop(at: at(2)) == shrunk)
        #expect(compositor.contentCrop(at: at(9)) == shrunk)
    }

    /// An invalid time has no crop to look up, and the refusal is `.whole` rather than `nil`
    /// for `ContentCropTrack.crop(at:)`'s reason — every frame has a crop.
    @Test func anInvalidTimeIsCroppedNotAtAll() throws {
        let url = scratchLog()
        try writeLog(at: url, crops: [
            ContentCropSample(instant: HostInstant(epoch: epoch, hostTime: Nanoseconds(0)),
                              content: CropRect(x: 0, y: 0, width: 0.5, height: 1),
                              contentScale: 2),
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        StageCompositor.observationLogURL = url
        StageCompositor.overrides = []
        defer { StageCompositor.observationLogURL = nil }

        #expect(StageCompositor().contentCrop(at: CMTime.invalid) == .whole)
    }
}
