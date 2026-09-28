import Testing
import Foundation
@testable import Soredemo

/// **`master-00` is an internal name, never a title.** `RecordingName`.
@Suite struct RecordingNameTests {
    /// 14:07:09 on 3 September — a single-digit month and day, an afternoon hour and non-zero
    /// seconds, so a missing pad, a 12-hour clock or a dropped field each changes the answer.
    private let recorded: Date = {
        var parts = DateComponents()
        (parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second) = (2026, 9, 3, 14, 7, 9)
        parts.timeZone = .current
        return Calendar(identifier: .gregorian).date(from: parts)!
    }()

    private let fresh = URL(fileURLWithPath: "/tmp/soredemo-preview-X/media/master-00.mov")

    @Test func aFreshRecordingIsNamedForWhenItWasMade() {
        let name = RecordingName.display(for: fresh, savedPackage: nil, recordedAt: recorded)
        #expect(name == String(localized: "Recording \("2026-09-03 14.07.09")"))
        #expect(!name.contains("master"))
        #expect(!name.contains(":") && !name.contains("/"), "a colon or a slash is a path separator")
    }

    @Test func aSavedProjectIsCalledWhatThePersonCalledIt() {
        let package = URL(fileURLWithPath: "/Users/someone/Movies/Onboarding demo.soredemo")
        #expect(RecordingName.display(for: fresh, savedPackage: package, recordedAt: recorded)
                == "Onboarding demo")
    }

    @Test func anOpenedVideoKeepsItsOwnName() {
        let opened = URL(fileURLWithPath: "/Users/someone/Desktop/Bug report 12.mov")
        #expect(RecordingName.display(for: opened, savedPackage: nil, recordedAt: recorded) == "Bug report 12")
    }

    /// A file somebody named `master-copy` or `master-1` is theirs; only the capture's own
    /// two-digit segment names are replaced.
    @Test func onlyTheCapturesOwnNamesAreReplaced() {
        #expect(RecordingName.isInternalSegmentName("master-00"))
        #expect(RecordingName.isInternalSegmentName("master-12"))
        #expect(!RecordingName.isInternalSegmentName("master-copy"))
        #expect(!RecordingName.isInternalSegmentName("master-1"))
        #expect(!RecordingName.isInternalSegmentName("my master-00"))
    }

    @Test func withNoDateItIsStillNotAnInternalName() {
        #expect(RecordingName.display(for: fresh, savedPackage: nil, recordedAt: nil)
                == String(localized: "Recording"))
    }

    /// The creation date is read from the file — a file written now has one, and a missing file
    /// has none rather than a made-up one.
    @Test func theDateComesFromTheFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("name-\(UUID().uuidString).mov")
        try Data([0]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(RecordingName.creationDate(of: url) != nil)
        #expect(RecordingName.creationDate(of: url.appendingPathExtension("gone")) == nil)
    }
}
