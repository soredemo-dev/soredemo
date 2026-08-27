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
        case couldNotStage(String)

        var description: String {
            switch self {
            case .notAVideo(let name):
                "\(name) is not a video file"
            case .noVideoTrack(let name):
                "\(name) has no video in it"
            case .couldNotStage(let reason):
                "the recording could not be prepared: \(reason)"
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
        let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        guard !tracks.isEmpty else {
            throw ImportError.noVideoTrack(url.lastPathComponent)
        }

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
        return (destination, sink)
    }
}
