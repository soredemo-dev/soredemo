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
    /// `substitutingAudio` replaces individual audio tracks with the first audio track of
    /// another asset, keyed by index into the source's own audio tracks.
    ///
    /// **Per track, not for the whole asset, because the two tracks are not interchangeable.**
    /// A Soredemo recording carries system audio and a microphone separately
    /// (`AudioMixBuilder.trackOrder`) and a person mixes them separately. Noise removal produces
    /// a cleaned MICROPHONE and must leave system audio exactly as recorded — so the shape of
    /// this parameter is what stops a cleaned track being pasted over both.
    ///
    /// A substitute that cannot be read leaves the original in place rather than dropping the
    /// track: losing the voice is a worse outcome than keeping its hiss, and a cache file that
    /// has been deleted under the app is an ordinary thing.
    public nonisolated static func make(from asset: AVAsset,
                                       by timeline: EditTimeline,
                                       substitutingAudio: [Int: AVAsset] = [:])
    async throws -> AVAsset {
        let composition = AVMutableComposition()
        let sourceVideo = try await asset.loadTracks(withMediaType: .video)
        guard let sourceVideoTrack = sourceVideo.first else { throw EditedAssetError.noVideoTrack }
        var sourceAudio = try await asset.loadTracks(withMediaType: .audio)
        for (index, replacement) in substitutingAudio where sourceAudio.indices.contains(index) {
            guard let first = try? await replacement.loadTracks(withMediaType: .audio).first
            else { continue }
            sourceAudio[index] = first
        }

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
            // **Scaled after the insert, over the span just written.** `scaleTimeRange` operates
            // on the composition's own timeline, so it must be given where the material landed
            // rather than where it came from — and it must be applied per clip, because the
            // speeds differ. A clip at 1 is skipped: scaling a range to its own duration is a
            // no-op that still costs an edit-list entry per clip.
            let played = CMTime(value: clip.outputDuration.rawValue, timescale: 1_000_000_000)
            if clip.speed != 1 {
                videoTrack.scaleTimeRange(CMTimeRange(start: cursor, duration: range.duration),
                                          toDuration: played)
            }
            for (index, track) in audioTracks.enumerated() where index < sourceAudio.count {
                // A source whose audio is shorter than its video is normal — the microphone
                // may have started late. A clip past the end of one track is skipped for that
                // track rather than failing the whole export.
                try? track.insertTimeRange(range, of: sourceAudio[index], at: cursor)
                if clip.speed != 1 {
                    // The audio is scaled with the picture, or a sped-up clip would run out of
                    // sound half way through and the tracks would drift for the rest of the
                    // export. AVFoundation resamples rather than dropping samples, so the
                    // narration comes back higher and faster — which is what speeding up
                    // narration sounds like, and what every editor does by default.
                    track.scaleTimeRange(CMTimeRange(start: cursor, duration: range.duration),
                                         toDuration: played)
                }
            }
            // **Advanced by what was PLAYED, not by what was read.** After a scale the material
            // occupies `played` on the composition's timeline; advancing by the source duration
            // would leave a gap after every slowed clip and overlap after every fast one.
            cursor = cursor + played
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
