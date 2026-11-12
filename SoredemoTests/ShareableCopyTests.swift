import Testing
import Foundation
import Geometry
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
        // A library with a screenshot whose text and original name are about a client.
        var library = Library()
        try library.adding(kind: .image, filename: "invoice.png", name: "invoice",
                           origin: .imported(originalName: "ACME invoice.png"), pictureText: "Invoice for ACME")
        let folder = package.appending(path: Library.directory, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(library).write(to: folder.appending(path: Library.listFilename))
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
        let sharedLibrary = try String(contentsOf: destination.appending(path: "library/library.json"), encoding: .utf8)
        #expect(!sharedLibrary.contains("ACME"), "the shared copy's library still says what a screenshot showed: \(sharedLibrary)")
        #expect(sharedLibrary.contains("invoice.png"), "the copy lost the library's file")
        let ownLibrary = try String(contentsOf: source.package.appending(path: "library/library.json"), encoding: .utf8)
        #expect(ownLibrary.contains("ACME"), "sharing a copy redacted the person's own library")
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
        let savedLibrary = try String(contentsOf: destination.appending(path: "library/library.json"), encoding: .utf8)
        #expect(savedLibrary.contains("ACME"), "an ordinary save keeps the library whole")
    }
}

/// **The camera file is opened through the same door as the recording.** It was found by name
/// and checked only for existing, so a shared package whose `camera-00.mov` was a symbolic link
/// opened the file it pointed at as the camera — the hole `ProjectPackageIO.mediaFile(named:in:)`
/// closed for the recording, still open beside it. Step 4 of
/// `docs/design/2026-10-23-splitting-the-recording-coordinator.md`.
@MainActor @Suite struct ProjectCameraFileTests {
    private func package(camera: (URL) throws -> Void) throws -> URL {
        let package = FileManager.default.temporaryDirectory
            .appending(path: "soredemo-cam-\(ProcessInfo.processInfo.globallyUniqueString).soredemo",
                       directoryHint: .isDirectory)
        let media = package.appending(path: "media", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try Data("movie".utf8).write(to: media.appending(path: "master-00.mov"))
        // A real package has a manifest; without one `open` refuses before it reaches the camera,
        // and every test below would be about the missing manifest instead.
        try ProjectPackageIO.save(ProjectSnapshot(schemaVersion: ProjectSnapshot.currentSchemaVersion,
                                                  geometries: GeometryRegistry(),
                                                  mediaFilenames: ["master-00.mov"]), to: package)
        try camera(media.appending(path: "camera-00.mov"))
        return package
    }

    @Test func aPackagesOwnCameraFileIsOpened() throws {
        let package = try package { try Data("face".utf8).write(to: $0) }
        defer { try? FileManager.default.removeItem(at: package) }
        #expect(try ProjectStore.open(package).cameraURL?.lastPathComponent == "camera-00.mov")
    }

    @Test func aCameraFileThatIsALinkToElsewhereIsNotOpened() throws {
        let outside = FileManager.default.temporaryDirectory
            .appending(path: "soredemo-cam-outside-\(ProcessInfo.processInfo.globallyUniqueString).mov")
        try Data("not yours".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let package = try package { try FileManager.default.createSymbolicLink(at: $0, withDestinationURL: outside) }
        defer { try? FileManager.default.removeItem(at: package) }
        #expect(try ProjectStore.open(package).cameraURL == nil)
    }

    @Test func aPackageWithNoCameraHasNone() throws {
        let package = try package { _ in }
        defer { try? FileManager.default.removeItem(at: package) }
        #expect(try ProjectStore.open(package).cameraURL == nil)
    }
}
