import Foundation
import Framing
import Geometry
import Project
import Testing
import Timeline
@testable import Soredemo

private let epoch = BootEpoch(id: UUID(uuidString: "6B1C2D3E-4F50-4617-8A9B-AC0D1E2F3A4B")!)
private let revision = GeometryRevision(id: 2)
/// **The recording starts 1000 s after boot**, so a mark placed at the click's absolute instant
/// rather than its offset into the recording lands a thousand seconds off the lane.
private let anchorSeconds: Int64 = 1_000
private let second: Int64 = 1_000_000_000

private func instant(_ seconds: Double) -> HostInstant {
    HostInstant(epoch: epoch, hostTime: Nanoseconds(anchorSeconds * second + Int64(seconds * 1e9)))
}

private func titled(_ role: String, _ title: String?) -> AXElementRecord {
    AXElementRecord(role: role, title: title,
                    frame: NormalizedFrame(origin: NormalizedPoint(x: 0.4, y: 0.4),
                                           size: NormalizedSize(width: 0.1, height: 0.05), revision: revision),
                    readInterval: HostRange(epoch: epoch, start: Nanoseconds(0), duration: Nanoseconds(1)))
}

/// A header, two named presses at 4 s and 9 s into the recording, and one press on nothing.
private func writeLog() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appending(path: "soredemo-steps-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var lines: [Data] = [try ObservationLog.encode(ObservationLogHeader(
        anchor: EpochAnchor(epoch: epoch, hostTime: Nanoseconds(anchorSeconds * second), wallClockUnixNanos: 0),
        segmentIndex: 0, mediaFilename: "master-00.mov", revision: revision, blindness: []))]
    for (seconds, hit) in [(4.0, titled("AXButton", "Export")), (6.0, nil), (9.0, titled("AXMenuItem", "Movie…"))] {
        lines.append(try ObservationLog.encode(AXChainRecord(
            instant: instant(seconds), clickPosition: NormalizedPoint(x: 0.45, y: 0.42), clickRevision: revision,
            hitTestGlobalX: 100, hitTestGlobalY: 200,
            hitTestInterval: HostRange(epoch: epoch, start: instant(seconds).hostTime, duration: Nanoseconds(1_000)),
            hit: hit, ancestors: hit == nil ? [] : [titled("AXWindow", nil), titled("AXApplication", "Keynote")],
            children: [], truncation: hit == nil ? .hitTestReturnedNothing : .reachedRoot,
            axCalls: 5, depthCap: 30, walkBudgetNanos: 35_000_000)))
    }
    let url = folder.appending(path: "segment-00.jsonl")
    var bytes = Data()
    for line in lines { bytes.append(line); bytes.append(0x0A) }
    try bytes.write(to: url)
    return url
}

private let anchor = EpochAnchor(epoch: epoch, hostTime: Nanoseconds(anchorSeconds * second), wallClockUnixNanos: 0)

@MainActor @Suite struct RecordedStepsModelTests {
    @Test func theLogsNamedPressesBecomeMarksAtTheirTimeInTheRecording() throws {
        let url = try writeLog()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = RecordedStepsModel()
        model.load(observationLogAt: url, anchor: anchor, duration: Nanoseconds(20 * second))
        #expect(model.failure == nil)
        #expect(model.marks == [StepMark(start: Nanoseconds(4 * second), number: 1, label: "Export"),
                                StepMark(start: Nanoseconds(9 * second), number: 2, label: "Movie…")])
        #expect(model.steps.last?.end == instant(20), "the duration closes the last step")
        #expect(model.steps.first?.application == "Keynote")
    }

    /// Without a duration the last step ends where it began — its end is unknown, not invented.
    @Test func withoutADurationTheLastStepHasNoLength() throws {
        let url = try writeLog()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = RecordedStepsModel()
        model.load(observationLogAt: url, anchor: anchor, duration: nil)
        #expect(model.steps.last?.end == instant(9))
    }

    @Test func noLogIsNoStepsAndAnUnreadableLogSaysSo() throws {
        let model = RecordedStepsModel()
        model.load(observationLogAt: nil, anchor: anchor, duration: nil)
        #expect(model.steps.isEmpty && model.failure == nil)

        let folder = FileManager.default.temporaryDirectory
            .appending(path: "soredemo-steps-bad-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bad = folder.appending(path: "segment-00.jsonl")
        try Data("not a log\n".utf8).write(to: bad)
        model.load(observationLogAt: bad, anchor: anchor, duration: nil)
        #expect(model.steps.isEmpty)
        #expect(model.failure != nil, "a file that could not be read is not the same as no clicks")
    }
}
