import Foundation
import Testing
import Timeline
@testable import Project

private let epoch = BootEpoch(id: UUID(uuidString: "3C2B1A00-9F8E-4D7C-B6A5-948372615000")!)

private func at(_ nanos: Int64) -> HostInstant { HostInstant(epoch: epoch, hostTime: Nanoseconds(nanos)) }

@Test func aChapterMarkIsAnObservationStampedWithItsEpoch() {
    let mark = ChapterMark(instant: at(1_234_567_890))
    #expect(mark.kind == "mark")
    #expect(mark.epochs == [epoch])
    #expect(mark.instant == at(1_234_567_890))
}

/// A record wearing another record's discriminator would be routed by `kind` and decoded as this
/// type anyway; refusing here is what stops that.
@Test func decodingAMarkRefusesAnotherRecordsKind() throws {
    let encoded = try JSONEncoder().encode(ChapterMark(instant: at(42)))
    #expect(try JSONDecoder().decode(ChapterMark.self, from: encoded) == ChapterMark(instant: at(42)))
    var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["kind"] = "still"
    let wrong = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(ChapterMark.self, from: wrong) }
}

/// Every segment's log, merged and in time order — a paused take has one log per segment, and a
/// mark in the second must not come before one in the first because of which file was read last.
@Test func theReaderFindsEveryMarkInEverySegmentInTimeOrder() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "chapter-marks-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    func log(_ name: String, _ lines: [Data]) throws -> URL {
        let url = directory.appending(path: name)
        try lines.reduce(into: Data()) { $0.append($1); $0.append(0x0A) }.write(to: url)
        return url
    }
    let still = StillInterval(interval: HostRange(epoch: epoch, start: Nanoseconds(5), duration: Nanoseconds(1_000_000_000)),
                              endedBy: .thePictureChanged, idleFrames: 60)
    let second = try log("segment-01.jsonl", [
        try ObservationLog.encode(ChapterMark(instant: at(9_000))),
        try ObservationLog.encode(ChapterMark(instant: at(7_000))),
    ])
    let first = try log("segment-00.jsonl", [
        try ObservationLog.encode(still),
        try ObservationLog.encode(ChapterMark(instant: at(3_000))),
    ])

    let marks = try ChapterMarkReader.marks(fromObservationLogsAt: [second, first])
    #expect(marks.map(\.instant.hostTime.rawValue) == [3_000, 7_000, 9_000])
}
