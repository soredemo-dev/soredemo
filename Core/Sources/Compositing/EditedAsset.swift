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
    /// own timeline IS the edited one and everything downstream counts in output time without
    /// knowing an edit happened. `merged()` first, so two clips that abut in the source are one
    /// read here.
    ///
    /// **One composition track per SOURCE audio track, not one mixed track**, and
    /// `substitutingAudio` replaces them individually by index: a master carries system sound
    /// and the microphone separately, noise removal produces a cleaned MICROPHONE, and the shape
    /// of that parameter is what stops a cleaned track being pasted over both. A substitute that
    /// cannot be read leaves the original in place — losing the voice is worse than keeping its
    /// hiss, and a cache file deleted under the app is an ordinary thing.
    ///
    /// `docs/design/what-the-exporter-reads.md` has the rest.
    public nonisolated static func make(from asset: AVAsset,
                                       by timeline: EditTimeline,
                                       substitutingAudio: [Int: AVAsset] = [:],
                                       library: [Int: AVAsset] = [:])
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

        // A library video's sound on its own track, so the recording's mix and noise removal never
        // reach it (`docs/design/2026-11-13-clips-from-the-library.md`). Made when first needed.
        var libraryAudio: AVMutableCompositionTrack?
        var cursor = CMTime.zero
        for clip in timeline.merged().clips {
            let played = CMTime(value: clip.outputDuration.rawValue, timescale: 1_000_000_000)
            switch clip.source {
            case .recording:
                break
            case .picture:
                // Empty time: the compositor draws the picture there (D6b-37), and it is silent.
                videoTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: played))
                cursor = cursor + played
                continue
            case .video(let item):
                guard let file = library[item],
                      let fileVideo = try await file.loadTracks(withMediaType: .video).first else {
                    throw EditedAssetError.libraryItemMissing(item)
                }
                let span = CMTimeRange(start: CMTime(value: clip.sourceStart.rawValue, timescale: 1_000_000_000),
                                       duration: CMTime(value: clip.duration.rawValue, timescale: 1_000_000_000))
                try videoTrack.insertTimeRange(span, of: fileVideo, at: cursor)
                if clip.speed != 1 { videoTrack.scaleTimeRange(CMTimeRange(start: cursor, duration: span.duration), toDuration: played) }
                if let fileAudio = try await file.loadTracks(withMediaType: .audio).first {
                    if libraryAudio == nil {
                        libraryAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                    }
                    try? libraryAudio?.insertTimeRange(span, of: fileAudio, at: cursor)
                    if clip.speed != 1 { libraryAudio?.scaleTimeRange(CMTimeRange(start: cursor, duration: span.duration), toDuration: played) }
                }
                cursor = cursor + played
                continue
            }
            let range = CMTimeRange(
                start: CMTime(value: clip.sourceStart.rawValue, timescale: 1_000_000_000),
                duration: CMTime(value: clip.duration.rawValue, timescale: 1_000_000_000))
            try videoTrack.insertTimeRange(range, of: sourceVideoTrack, at: cursor)
            // **Scaled after the insert, over the span just written.** `scaleTimeRange` operates
            // on the composition's own timeline, so it must be given where the material landed
            // rather than where it came from — and it must be applied per clip, because the
            // speeds differ. A clip at 1 is skipped: scaling a range to its own duration is a
            // no-op that still costs an edit-list entry per clip.
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
    /// A library clip whose file was not given — refused by its id, never played as black.
    case libraryItemMissing(Int)

    public var description: String {
        switch self {
        case .noVideoTrack: "the recording has no video track to cut"
        case .trackRefused: "AVMutableComposition refused a track"
        case .libraryItemMissing(let item): "library item \(item) is in the edit and its file was not found"
        }
    }
}
