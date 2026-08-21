import AVFoundation
import Foundation
import Timeline

/// Turns a recording plus an `EditTimeline` into one asset containing only what survived.
///
/// **Shared by the preview and the export deliberately.** The two were already required to
/// build the same `AVVideoComposition`; once an edit exists they must also be looking at the
/// same cut asset, or a person reviews one video and ships another. Extracted from
/// `MP4Exporter` the moment the preview needed it, rather than copied into it.
public enum EditedAsset {
    /// **One asset containing only what survived, in output order.**
    ///
    /// Each surviving clip's source range is inserted into a composition track, so the result's
    /// own timeline IS the edited one and everything downstream — the reader, the video
    /// composition, the writer — counts in output time without knowing an edit happened.
    ///
    /// `merged()` first: two clips that abut in the source are one read here. The unmerged form
    /// exists so a reviewer's timeline can show where a cut was made, which an exporter has no
    /// use for.
    ///
    /// One composition track per SOURCE audio track, not one mixed track: a master carries
    /// system sound and the microphone separately, and mixing is `AVAssetReaderAudioMixOutput`'s
    /// job further down. Doing it here would mix twice.
    public nonisolated static func make(from asset: AVAsset,
                                       by timeline: EditTimeline) async throws -> AVAsset {
        let composition = AVMutableComposition()
        let sourceVideo = try await asset.loadTracks(withMediaType: .video)
        guard let sourceVideoTrack = sourceVideo.first else { throw EditedAssetError.noVideoTrack }
        let sourceAudio = try await asset.loadTracks(withMediaType: .audio)

        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw EditedAssetError.trackRefused }
        let audioTracks = sourceAudio.compactMap { _ in
            composition.addMutableTrack(withMediaType: .audio,
                                        preferredTrackID: kCMPersistentTrackID_Invalid)
        }

        var cursor = CMTime.zero
        for clip in timeline.merged().clips {
            let range = CMTimeRange(
                start: CMTime(value: clip.sourceStart.rawValue, timescale: 1_000_000_000),
                duration: CMTime(value: clip.duration.rawValue, timescale: 1_000_000_000))
            try videoTrack.insertTimeRange(range, of: sourceVideoTrack, at: cursor)
            for (index, track) in audioTracks.enumerated() where index < sourceAudio.count {
                // A source whose audio is shorter than its video is normal — the microphone
                // may have started late. A clip past the end of one track is skipped for that
                // track rather than failing the whole export.
                try? track.insertTimeRange(range, of: sourceAudio[index], at: cursor)
            }
            cursor = cursor + range.duration
        }
        return composition
    }
}

public enum EditedAssetError: Error, CustomStringConvertible, Sendable, Equatable {
    case noVideoTrack
    case trackRefused

    public var description: String {
        switch self {
        case .noVideoTrack: "the recording has no video track to cut"
        case .trackRefused: "AVMutableComposition refused a track"
        }
    }
}
