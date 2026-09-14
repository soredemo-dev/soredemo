import AVFoundation
import Capture
import Foundation
import UniformTypeIdentifiers

/// **Brings a video file that this app did not record into the editor.**
///
/// Until now the only way into the editor was to record something or to open a `.soredemo`
/// project. A person with a video already on their disk — one they recorded before installing
/// this, one somebody sent them, one they made on a phone and airdropped — had no way in at all.
///
/// **The file is put into a package rather than opened where it lies, and that is the whole of
/// this type.** Everything downstream assumes the shape a recording has:
/// `ObservationWriter.expectedLogURL` looks for `<package>/observations/` beside
/// `<package>/media/master-NN.mov`, `ProjectStore.packageURL(forMediaAt:)` is the media file's
/// grandparent, and noise removal writes its cleaned copy into that package. Opening
/// `~/Desktop/demo.mp4` in place would make the package `~`, and the first cleaned audio track
/// would land in the person's home folder.
///
/// **Linked when it can be, copied when it cannot.** A hard link is instant and costs no disk;
/// it only works within one volume, so a file on an external drive or a network share falls back
/// to a copy. Either way the original is untouched — this app does not move somebody's files.
enum ImportedRecording {
    /// The video types the editor can open. **Asked of the system rather than listed**: a
    /// hard-coded list of extensions goes stale, and `UTType.movie`'s conformances are what
    /// AVFoundation will actually accept.
    static var readableTypes: [UTType] { [.movie, .video, .quickTimeMovie, .mpeg4Movie] }

    enum ImportError: Error, CustomStringConvertible {
        case notAVideo(String)
        case noVideoTrack(String)
        /// The file could not be examined at all. **Distinct from `noVideoTrack` on purpose**:
        /// folding a failed read into "there is no video in it" sends somebody looking for a
        /// track that is there, and says nothing about the thing that actually went wrong.
        case couldNotRead(name: String, reason: String)
        case couldNotStage(String)
        case truncated(name: String, expected: Double, got: Double)

        var description: String {
            switch self {
            case .notAVideo(let name):
                "\(name) is not a video file"
            case .noVideoTrack(let name):
                "\(name) has no video in it"
            case .couldNotRead(let name, let reason):
                "\(name) could not be read: \(reason). This says nothing about what is in it."
            case .couldNotStage(let reason):
                "the recording could not be prepared: \(reason)"
            case .truncated(let name, let expected, let got):
                """
                \(name) arrived incomplete — \((got * 10).rounded() / 10) s of \
                \((expected * 10).rounded() / 10) s. If it was dragged from another \
                application it may still have been writing it; try again, or open it from \
                the file itself.
                """
            }
        }
    }

    /// Stages `url` into a scratch package and returns the media URL the editor should open.
    ///
    /// **Checked for a video track before anything is copied.** A `.mp4` holding only audio is a
    /// real thing, and finding out after copying four gigabytes is worse than finding out first.
    @MainActor
    static func stage(_ url: URL) async throws -> (mediaURL: URL, sink: TemporaryFileMediaSink) {
        let asset = AVURLAsset(url: url)
        // **A failed read is not an empty answer.** `(try? …) ?? []` made every unreadable file
        // — a codec this Mac has no decoder for, a partial download, a permission the sandbox
        // refused — report "has no video in it", which is a fact about the READ dressed as a
        // fact about the FILE. The person then goes looking for a video track that is there.
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw ImportError.couldNotRead(name: url.lastPathComponent,
                                           reason: String(describing: error))
        }
        guard !tracks.isEmpty else {
            throw ImportError.noVideoTrack(url.lastPathComponent)
        }
        // Read now, compared after the file lands. See `truncated` below for what this catches.
        //
        // **Optional, because "unknown" and "zero" are different answers.** As `?? 0` it made
        // the guard below — `sourceSeconds > 0` — skip the truncation check entirely whenever
        // the duration could not be read, silently, which is the one case where a short copy is
        // most likely.
        let sourceSeconds = try? await asset.load(.duration).seconds

        let sink: TemporaryFileMediaSink
        do {
            sink = try TemporaryFileMediaSink()
        } catch {
            throw ImportError.couldNotStage(String(describing: error))
        }
        guard let package = sink.packageURL else {
            throw ImportError.couldNotStage("the scratch package has no location")
        }

        // **`master-00` with the source's own extension.** The name is what
        // `ObservationWriter.expectedLogURL` matches on; the extension has to stay the file's own
        // or AVFoundation is handed a `.mov` that is really an `.mp4`.
        let destination = package.appending(path: "media", directoryHint: .isDirectory)
            .appending(path: "master-00.\(url.pathExtension.isEmpty ? "mov" : url.pathExtension)")
        do {
            try FileManager.default.linkItem(at: url, to: destination)
        } catch {
            // Across volumes, or on a filesystem with no hard links. Copying is the fallback and
            // not the default: a five-gigabyte recording linked is instant and copied is not.
            do {
                try FileManager.default.copyItem(at: url, to: destination)
            } catch {
                throw ImportError.couldNotStage(String(describing: error))
            }
        }
        // **The staged file is checked against the original, and a drop is why.**
        //
        // A Finder drag can arrive as a file PROMISE, and a framework that resolves one into a
        // temporary copy may hand it over before the system has finished writing it. A
        // ten-second recording reached the editor as roughly one second that way — every layer
        // downstream reported the truncated length perfectly consistently, because the file
        // really was that long by the time anything looked.
        //
        // The drop path resolves the real file URL now, so this should never fire. It stays
        // because "should never fire" is the claim, not the mechanism: a short recording is
        // indistinguishable from a correct one once it is open, and finding out at export is too
        // late.
        // **`?? 0` here was the worst of the three.** A copy that landed perfectly but whose
        // duration could not be re-read became `0`, which is less than every source duration —
        // so a correct import was deleted and reported as "arrived incomplete — 0 s of 12 s".
        // A false accusation, caused by a read, against a file that was fine.
        guard let stagedSeconds = try? await AVURLAsset(url: destination)
            .load(.duration).seconds else {
            try? FileManager.default.removeItem(at: destination)
            throw ImportError.couldNotStage("the copied file's length could not be read")
        }
        // A tenth of a second of slack: re-reading a container can round the last sample.
        if let sourceSeconds, sourceSeconds > 0, stagedSeconds < sourceSeconds - 0.1 {
            try? FileManager.default.removeItem(at: destination)
            throw ImportError.truncated(name: url.lastPathComponent,
                                        expected: sourceSeconds, got: stagedSeconds)
        }
        return (destination, sink)
    }
}
