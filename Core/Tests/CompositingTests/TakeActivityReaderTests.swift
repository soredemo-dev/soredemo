import Foundation
import Framing
import Geometry
import Project
import Testing
import Timeline
@testable import Compositing

// A take read from an observation log, for a cut producer. The anchor sits at 100 s, so a span
// converted from an offset without it would land 100 s early, and every expected value is a
// literal from the fixture's own numbers.

private let epoch = BootEpoch(id: UUID(uuidString: "7A4E0000-0000-4000-8000-000000000005")!)
private let revision = GeometryRevision(id: 6)
private let second: Int64 = 1_000_000_000
private let anchor = EpochAnchor(epoch: epoch, hostTime: Nanoseconds(100 * second), wallClockUnixNanos: 0)

private func at(_ seconds: Double) -> HostInstant {
    HostInstant(epoch: epoch, hostTime: Nanoseconds(Int64((seconds * 1_000_000_000).rounded())))
}

private func range(_ from: Double, _ to: Double) -> HostRange {
    HostRange(epoch: epoch, start: at(from).hostTime,
              duration: Nanoseconds(at(to).hostTime.rawValue - at(from).hostTime.rawValue))
}

private func line<T: Encodable>(_ record: T) throws -> String {
    String(decoding: try ObservationLog.encode(record), as: UTF8.self)
}

private func element(_ role: String, _ title: String?) -> AXElementRecord {
    AXElementRecord(role: role, title: title,
                    frame: NormalizedFrame(origin: NormalizedPoint(x: 0.4, y: 0.4),
                                           size: NormalizedSize(width: 0.1, height: 0.05), revision: revision),
                    readInterval: HostRange(epoch: epoch, start: Nanoseconds(1_000), duration: Nanoseconds(500)))
}

private func press(_ seconds: Double, _ title: String) -> AXChainRecord {
    AXChainRecord(instant: at(seconds), clickPosition: NormalizedPoint(x: 0.45, y: 0.42),
                  clickRevision: revision, hitTestGlobalX: 100, hitTestGlobalY: 200,
                  hitTestInterval: HostRange(epoch: epoch, start: at(seconds).hostTime, duration: Nanoseconds(2_000_000)),
                  hit: element("AXButton", title),
                  ancestors: [element("AXWindow", nil), element("AXApplication", "Finder")], children: [],
                  truncation: .reachedRoot, axCalls: 5, depthCap: 30, walkBudgetNanos: 35_000_000)
}

/// A recording from 100 s to 120 s: presses at 103 s and 118 s, a shortcut at 105 s, secure input
/// from 107 s to 110 s, the tap off from 112 s to 113 s, and a still pointer.
private func writeLog() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "take-activity-reader-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "segment-00.jsonl")
    let records = [
        try line(PointerSample(instant: at(100.5), position: NormalizedPoint(x: 0.3, y: 0.3), revision: revision)),
        try line(press(103, "Export")),
        try line(ButtonEvent(instant: at(103), position: NormalizedPoint(x: 0.45, y: 0.42), revision: revision,
                             button: .left, phase: .down)),
        try line(KeySample(instant: at(105), shortcut: "⌘S")),
        try line(SecureInputInterval(interval: range(107, 110), endedBy: .secureInputDisabled)),
        try line(TapDisabledInterval(interval: range(112, 113), disabledBy: nil,
                                     lowerBoundFrom: .lastEnabledPoll, detectedBy: .enabledPoll)),
        try line(press(118, "Done")),
    ]
    try (records.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    return url
}

@Suite struct TakeActivityReaderTests {
    @Test func everyChannelOfTheLogArrivesOnTheRecordingsClock() throws {
        let url = try writeLog()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let take = try TakeActivityReader.take(fromObservationLogAt: url, anchor: anchor,
                                               duration: Nanoseconds(20 * second),
                                               speech: [14 * second..<16 * second])
        #expect(take.recording == range(100, 120))
        #expect(take.steps.map(\.origin) == [at(103), at(118)])
        #expect(take.steps.last?.end == at(120), "the last step closes at the recording's end")
        #expect(take.buttons.map(\.instant) == [at(103)])
        #expect(take.shortcuts.map(\.instant) == [at(105)])
        #expect(take.pointer.map(\.instant) == [at(100.5)])
        #expect(take.unobserved == [range(107, 110), range(112, 113)],
                "secure input and a switched-off tap are both spans nobody could see")
        #expect(take.speech == [range(114, 116)], "an offset of 14 s is 114 s on a recording anchored at 100 s")
    }

    @Test func anEmptySpanOfSpeechIsNotSpeech() throws {
        let url = try writeLog()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let take = try TakeActivityReader.take(fromObservationLogAt: url, anchor: anchor,
                                               duration: Nanoseconds(20 * second),
                                               speech: [5 * second..<5 * second])
        #expect(take.speech.isEmpty)
    }

    /// End to end: what the observer could not see is not proposed as dead air. Without the
    /// unobserved spans the quiet from 105 s to 118 s would be one proposal.
    @Test func whatNobodyCouldSeeIsNotProposedForRemoval() throws {
        let url = try writeLog()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let take = try TakeActivityReader.take(fromObservationLogAt: url, anchor: anchor,
                                               duration: Nanoseconds(20 * second), speech: [])
        let removed = DeadAirProposer().proposals(for: take).map(\.removes)
        #expect(removed == [range(100, 102.5), range(103.5, 104.5), range(105.5, 106.5),
                            range(110.5, 111.5), range(113.5, 117.5), range(118.5, 120)])
    }
}
