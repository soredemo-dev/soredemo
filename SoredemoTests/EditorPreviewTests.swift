import Testing
import AVFoundation
import CoreGraphics
import Compositing
import Overlays
import Project
@testable import Soredemo

/// **The preview pipeline, without a window** — step 2 of
/// `docs/design/2026-10-23-splitting-the-stage-window.md`. Before, every line here lived in
/// `StageWindow` as `@State` and could only be reached by opening an editor.
@MainActor @Suite(.serialized) struct EditorPreviewTests {
    /// A package laid out as a recording's is — `<package>/media/master-00.mov` — holding a
    /// one-frame movie. 320×200 rather than a common size, so a size read from somewhere else
    /// does not pass by coincidence.
    ///
    /// **Not named `soredemo-preview-…`.** It was, and the test failed reading tracks with
    /// -17913: `TemporaryFileMediaSink`'s launch sweep removes every directory with that prefix,
    /// so another suite's sweep deleted this one's recording mid-test. Renaming alone made it
    /// pass, which is what separated that cause from the pipeline being wrong.
    private func recording() async throws -> EditorPreview.Files {
        let package = FileManager.default.temporaryDirectory
            .appending(path: "editor-preview-test-\(ProcessInfo.processInfo.globallyUniqueString)",
                       directoryHint: .isDirectory)
        let media = package.appending(path: ProjectStore.mediaDirectory, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let context = try #require(CGContext(
            data: nil, width: 320, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
        let movie = media.appending(path: "master-00.mov")
        try await StillMovie.write(try #require(context.makeImage()), seconds: 1, to: movie)
        return EditorPreview.Files(mediaURL: movie, cameraURL: nil, cameraStartOffsetNanos: 0)
    }

    private func remove(_ files: EditorPreview.Files) {
        try? FileManager.default.removeItem(at: ProjectStore.packageURL(forMediaAt: files.mediaURL))
    }

    @Test func aRealRecordingGivesAPlayerAndItsOwnSize() async throws {
        let files = try await recording()
        defer { remove(files) }
        let preview = EditorPreview(), editor = EditorViewModel()
        await preview.load(files, into: editor, pendingEdit: nil, scrubAudio: false)
        #expect(preview.failure == nil)
        #expect(preview.player != nil)
        #expect(preview.playingAsset != nil)
        #expect(editor.recordingSize.width == 320 && editor.recordingSize.height == 200)
    }

    /// The reason is kept, so the window can say it instead of spinning.
    @Test func aMissingRecordingGivesAReasonAndNoPlayer() async throws {
        let files = EditorPreview.Files(
            mediaURL: FileManager.default.temporaryDirectory
                .appending(path: "soredemo-nothing-\(ProcessInfo.processInfo.globallyUniqueString)/media/master-00.mov"),
            cameraURL: nil, cameraStartOffsetNanos: 0)
        let preview = EditorPreview()
        await preview.load(files, into: EditorViewModel(), pendingEdit: nil, scrubAudio: false)
        #expect(preview.player == nil)
        #expect(preview.failure != nil)
    }

    @Test func chosenMusicIsCopiedIntoThePackageAndBecomesTheBed() async throws {
        let files = try await recording()
        defer { remove(files) }
        let chosen = FileManager.default.temporaryDirectory
            .appending(path: "bed-\(ProcessInfo.processInfo.globallyUniqueString).m4a")
        try Data("not really audio".utf8).write(to: chosen)
        defer { try? FileManager.default.removeItem(at: chosen) }
        let preview = EditorPreview(), editor = EditorViewModel()
        preview.adoptMusic(chosen, files: files, editor: editor)
        let copied = ProjectStore.packageURL(forMediaAt: files.mediaURL)
            .appending(path: MusicBed.directory, directoryHint: .isDirectory)
            .appending(path: chosen.lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: copied.path))
        #expect(editor.music.filename == chosen.lastPathComponent)
        #expect(editor.music.isEnabled)
        #expect(preview.musicFailure == nil)
    }

    /// A name `MusicBed` will not store is refused with the reason, and the bed is left as it was.
    @Test func musicWithANameTheProjectCannotStoreIsRefused() async throws {
        let files = try await recording()
        defer { remove(files) }
        let chosen = FileManager.default.temporaryDirectory
            .appending(path: ".hidden-\(ProcessInfo.processInfo.globallyUniqueString).m4a")
        try Data("x".utf8).write(to: chosen)
        defer { try? FileManager.default.removeItem(at: chosen) }
        let preview = EditorPreview(), editor = EditorViewModel()
        preview.adoptMusic(chosen, files: files, editor: editor)
        #expect(editor.music.filename == nil)
        #expect(preview.musicFailure?.contains(chosen.lastPathComponent) == true)
    }

    /// Removing the bed also clears an earlier failure — a reason for a piece no longer chosen
    /// is a reason about nothing.
    @Test func removingTheMusicClearsItsFailure() async throws {
        let files = try await recording()
        defer { remove(files) }
        let bad = FileManager.default.temporaryDirectory
            .appending(path: ".bad-\(ProcessInfo.processInfo.globallyUniqueString).m4a")
        try Data("x".utf8).write(to: bad)
        defer { try? FileManager.default.removeItem(at: bad) }
        let preview = EditorPreview(), editor = EditorViewModel()
        preview.adoptMusic(bad, files: files, editor: editor)
        #expect(preview.musicFailure != nil)
        preview.removeMusic(editor: editor)
        #expect(preview.musicFailure == nil)
        #expect(editor.music == MusicBed.none)
    }
}
