import Testing
import Foundation
import Project
@testable import Soredemo

/// **A copy to share leaves the words on the screen behind; the person's own project keeps
/// them.** Audit R5. The copy still has the recording and the edit, and its log still has every
/// role and position, so it still draws its cursor and still zooms.
@MainActor @Suite struct ShareableCopyTests {
    private let titled = #"{"kind":"axChain","hit":{"role":"AXButton","title":"Invoice for ACME — confidential"}}"#

    private func recording() throws -> (package: URL, media: URL) {
        let package = FileManager.default.temporaryDirectory
            .appending(path: "soredemo-share-src-\(ProcessInfo.processInfo.globallyUniqueString)",
                       directoryHint: .isDirectory)
        let media = package.appending(path: "media", directoryHint: .isDirectory)
        let observations = package.appending(path: "observations", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: observations, withIntermediateDirectories: true)
        let movie = media.appending(path: "master-00.mov")
        try Data("not really a movie".utf8).write(to: movie)
        try (titled + "\n").write(to: observations.appending(path: "segment-00.jsonl"),
                                  atomically: true, encoding: .utf8)
        return (package, movie)
    }

    @Test func theSharedCopyHasNoScreenTextAndTheOriginalIsUntouched() throws {
        let source = try recording()
        defer { try? FileManager.default.removeItem(at: source.package) }
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "soredemo-share-dst-\(ProcessInfo.processInfo.globallyUniqueString).soredemo",
                       directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: destination) }

        try ProjectStore.save(recordingAt: source.media, edit: EditState(), to: destination,
                              withoutScreenText: true)

        let shared = try String(contentsOf: destination.appending(path: "observations/segment-00.jsonl"),
                                encoding: .utf8)
        #expect(!shared.contains("ACME"), "the shared copy still says what was on screen")
        #expect(shared.contains(#""role":"AXButton""#), "the copy lost what it needs to zoom")
        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "media/master-00.mov").path))
        let original = try String(contentsOf: source.package.appending(path: "observations/segment-00.jsonl"),
                                  encoding: .utf8)
        #expect(original.contains("ACME"), "sharing a copy redacted the person's own project")
    }

    /// Positive control: an ordinary save keeps the evidence whole.
    @Test func anOrdinarySaveKeepsTheScreenText() throws {
        let source = try recording()
        defer { try? FileManager.default.removeItem(at: source.package) }
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "soredemo-save-dst-\(ProcessInfo.processInfo.globallyUniqueString).soredemo",
                       directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: destination) }
        try ProjectStore.save(recordingAt: source.media, edit: EditState(), to: destination)
        let saved = try String(contentsOf: destination.appending(path: "observations/segment-00.jsonl"),
                               encoding: .utf8)
        #expect(saved.contains("ACME"))
    }
}
