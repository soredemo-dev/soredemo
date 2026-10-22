import Foundation
import Testing
@testable import Project

/// **A project shared without the words on the screen.** The observation log keeps the
/// accessibility title under every click — a window's name, a button's label, sometimes an
/// e-mail's subject. Right for the editor; a surprise in a file somebody sends on (audit R5).
/// Redacted as text so every other byte survives, which a decode and re-encode cannot promise.
@Suite struct EvidenceRedactionTests {
    private let line = #"{"kind":"axChain","hit":{"role":"AXButton","title":"Send \"Q3\" to boss\\finance","children":[{"role":"AXStaticText","title":"郵件 ✉️"}]},"instant":{"hostTime":123}}"#

    @Test func everyTitleIsReplacedAndNothingElseMoves() {
        let redacted = EvidenceRedaction.redacted(line)
        #expect(redacted == #"{"kind":"axChain","hit":{"role":"AXButton","title":"[redacted]","children":[{"role":"AXStaticText","title":"[redacted]"}]},"instant":{"hostTime":123}}"#)
        // Still a record: the editor reads the roles and positions, which stay.
        #expect((try? JSONSerialization.jsonObject(with: Data(redacted.utf8))) != nil)
    }

    @Test func linesStayLinesAndARedactedLogIsAFixedPoint() {
        let log = line + "\n" + #"{"kind":"pointer","instant":{"hostTime":1}}"# + "\n"
        let once = EvidenceRedaction.redacted(log)
        #expect(once.split(separator: "\n", omittingEmptySubsequences: false).count
                == log.split(separator: "\n", omittingEmptySubsequences: false).count)
        #expect(EvidenceRedaction.redacted(once) == once)
    }

    /// **The committed fixture was redacted by `scripts/redact-observation-log.swift`**, and this
    /// type must agree with it: the fixture is already redacted, so redacting it again changes
    /// nothing. Two instruments, one question, compared — the audit table's row 3, for this pair.
    @Test func theCommittedFixtureIsAlreadyWhatThisWouldWrite() throws {
        let url = try #require(Bundle.module.url(forResource: "segment-00-redacted", withExtension: "jsonl"),
                               "the fixture is not in this test target's resources")
        let fixture = try String(contentsOf: url, encoding: .utf8)
        #expect(fixture.contains(#""title":"[redacted]""#), "the fixture carries no title to compare on")
        #expect(EvidenceRedaction.redacted(fixture) == fixture)
    }

    @Test func aPackagesLogsAreRedactedInPlaceAndItsOtherFilesAreNot() throws {
        let package = FileManager.default.temporaryDirectory
            .appending(path: "soredemo-redact-\(ProcessInfo.processInfo.globallyUniqueString)",
                       directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: package) }
        let observations = package.appending(path: "observations", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: observations, withIntermediateDirectories: true)
        try (line + "\n").write(to: observations.appending(path: "segment-00.jsonl"), atomically: true, encoding: .utf8)
        try (line + "\n").write(to: observations.appending(path: "segment-01.jsonl"), atomically: true, encoding: .utf8)
        let manifest = package.appending(path: "project.json")
        try #"{"title":"my own project title"}"#.write(to: manifest, atomically: true, encoding: .utf8)

        let count = try EvidenceRedaction.redactObservations(in: package)

        #expect(count == 2)
        for name in ["segment-00.jsonl", "segment-01.jsonl"] {
            let text = try String(contentsOf: observations.appending(path: name), encoding: .utf8)
            #expect(!text.contains("boss") && text.contains("[redacted]"), "\(name) still says what was on screen")
        }
        // Only the evidence: a person's own words in the edit are theirs to share.
        #expect(try String(contentsOf: manifest, encoding: .utf8).contains("my own project title"))
    }

    /// Bytes that are not text are refused, not passed through: the copy would carry exactly what
    /// the person asked to leave out.
    @Test func aLogThatIsNotTextIsRefusedRatherThanSkipped() throws {
        let package = FileManager.default.temporaryDirectory
            .appending(path: "soredemo-redact-bin-\(ProcessInfo.processInfo.globallyUniqueString)",
                       directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: package) }
        let observations = package.appending(path: "observations", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: observations, withIntermediateDirectories: true)
        try Data([0xFF, 0xFE, 0x22, 0x74]).write(to: observations.appending(path: "segment-00.jsonl"))
        #expect(throws: EvidenceRedaction.Failure.notText("segment-00.jsonl")) {
            try EvidenceRedaction.redactObservations(in: package)
        }
    }
}
