import Testing
import Foundation
import Compositing
import Overlays
import Render
import Timeline
@testable import Soredemo

/// **The captions model's file work, without a panel** — step 1 of
/// `docs/design/2026-10-23-splitting-the-captions-panel.md`. Reading and writing a sidecar and
/// adopting a font each sat behind an `NSOpenPanel` or `NSSavePanel` and could only be reached
/// by clicking.
@MainActor @Suite(.serialized) struct CaptionsModelTests {
    private func scratch(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "captions-model-test-\(name)-\(ProcessInfo.processInfo.globallyUniqueString)")
    }

    private func seconds(_ value: Double) -> Nanoseconds { Nanoseconds(Int64(value * 1e9)) }

    /// **An edit that starts two seconds into the recording**, so the export's clock and the
    /// recording's differ. An edit starting at zero is the identity of the mapping and would pass
    /// with the mapping deleted.
    private var cutFromTwoSeconds: EditTimeline {
        EditTimeline(clips: [EditClip(id: ClipID(rawValue: 1), sourceStart: seconds(2),
                                      duration: seconds(2))])
    }

    @Test func aSidecarIsReadBackIntoTheRecordingsClockAndWhatFallsPastTheEditIsCounted() throws {
        let file = scratch("read").appendingPathExtension("srt")
        try """
        1
        00:00:00,500 --> 00:00:01,500
        inside

        2
        00:00:02,500 --> 00:00:03,500
        past the end

        """.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let model = CaptionsModel()
        model.importSidecar(from: file, edit: cutFromTwoSeconds)

        let cues = model.track.cues
        try #require(cues.count == 1)
        #expect(cues[0].text == "inside")
        #expect(cues[0].start == seconds(2.5))
        #expect(cues[0].end == seconds(3.5))
        #expect(model.status?.contains("1 fell outside the edit") == true)
    }

    /// Nothing placeable leaves the captions as they were: a file that fits nowhere is not an
    /// instruction to delete every line.
    @Test func aSidecarWithNothingInsideTheEditChangesNothing() throws {
        let file = scratch("outside").appendingPathExtension("srt")
        try "1\n00:00:05,000 --> 00:00:06,000\nlate\n"
            .write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let model = CaptionsModel()
        let before = CaptionTrack(cues: [CaptionCue(text: "kept", start: seconds(2.2),
                                                    end: seconds(2.8))])
        model.restore(track: before, style: .default, burnsIn: false)
        model.importSidecar(from: file, edit: cutFromTwoSeconds)

        #expect(model.track == before)
        #expect(model.status != nil)
    }

    @Test func anExportedSidecarIsInTheExportsClock() throws {
        let file = scratch("write").appendingPathExtension("srt")
        defer { try? FileManager.default.removeItem(at: file) }

        let model = CaptionsModel()
        model.restore(track: CaptionTrack(cues: [CaptionCue(text: "hello", start: seconds(2.5),
                                                            end: seconds(3.5))]),
                      style: .default, burnsIn: false)
        model.exportSidecar(format: .subRip, edit: cutFromTwoSeconds, to: file)

        let written = try String(contentsOf: file, encoding: .utf8)
        #expect(written.contains("00:00:00,500 --> 00:00:01,500"))
        #expect(written.contains("hello"))
    }

    /// A package laid out as a recording's is: only the path matters, so no movie is written.
    private func package() throws -> URL {
        let package = scratch("package")
        try FileManager.default.createDirectory(
            at: package.appending(path: ProjectStore.mediaDirectory, directoryHint: .isDirectory),
            withIntermediateDirectories: true)
        return package
    }

    private func font(named name: String, bytes: String) throws -> URL {
        let directory = scratch("font")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try Data(bytes.utf8).write(to: url)
        return url
    }

    @Test func aChosenFontIsCopiedIntoThePackageAndBecomesTheStyles() throws {
        let package = try package()
        defer { try? FileManager.default.removeItem(at: package) }
        let chosen = try font(named: "Brand.ttf", bytes: "first")
        defer { try? FileManager.default.removeItem(at: chosen.deletingLastPathComponent()) }
        let mediaURL = package.appending(path: "\(ProjectStore.mediaDirectory)/master-00.mov")

        let model = CaptionsModel()
        model.adoptFont(chosen, mediaURL: mediaURL)

        let copied = package.appending(path: "\(TextArt.fontDirectory)/Brand.ttf")
        #expect(try String(contentsOf: copied, encoding: .utf8) == "first")
        #expect(model.style.fontFilename == "Brand.ttf")
        #expect(model.fontFailure == nil)
    }

    /// **A second `Brand.ttf` replaces the first** rather than failing because a file of that
    /// name is already there — the cache-clearing in `adoptFont` exists for exactly this case.
    @Test func aFontOfTheSameNameReplacesTheOneInThePackage() throws {
        let package = try package()
        defer { try? FileManager.default.removeItem(at: package) }
        let first = try font(named: "Brand.ttf", bytes: "first")
        let second = try font(named: "Brand.ttf", bytes: "second")
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }
        let mediaURL = package.appending(path: "\(ProjectStore.mediaDirectory)/master-00.mov")

        let model = CaptionsModel()
        model.adoptFont(first, mediaURL: mediaURL)
        model.adoptFont(second, mediaURL: mediaURL)

        let copied = package.appending(path: "\(TextArt.fontDirectory)/Brand.ttf")
        #expect(try String(contentsOf: copied, encoding: .utf8) == "second")
        #expect(model.fontFailure == nil)
    }

    /// The reason is kept and the style keeps the font it had.
    @Test func aFontWithANameThePackageCannotHoldIsRefused() throws {
        let package = try package()
        defer { try? FileManager.default.removeItem(at: package) }
        let chosen = try font(named: ".Hidden.ttf", bytes: "x")
        defer { try? FileManager.default.removeItem(at: chosen.deletingLastPathComponent()) }
        let mediaURL = package.appending(path: "\(ProjectStore.mediaDirectory)/master-00.mov")

        let model = CaptionsModel()
        model.adoptFont(chosen, mediaURL: mediaURL)

        #expect(model.style.fontFilename == nil)
        #expect(model.fontFailure?.contains(".Hidden.ttf") == true)
        #expect(!FileManager.default.fileExists(
            atPath: package.appending(path: "\(TextArt.fontDirectory)/.Hidden.ttf").path))
    }
}
