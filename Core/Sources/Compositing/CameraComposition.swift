import AVFoundation
import Foundation

/// Puts the camera's file and the screen recording into one asset, so a single
/// `AVVideoComposition` can see both.
///
/// **Two video tracks in one composition, not two players.** `AVAsynchronousVideoCompositionRequest`
/// hands the compositor a buffer per source track, which is exactly what an overlay needs — and
/// it means the camera is cut, scrubbed and exported by the same machinery as the screen. Two
/// players would have to be kept in sync by hand, which is a clock problem this project has
/// already paid for once.
public enum CameraComposition {
    /// What `combine` produced: the asset to render, and which track the camera is.
    /// **Not `Sendable`.** `AVAsset` is not, and the honest answer is to say so rather than to
    /// mark this and carry the problem across a boundary the compiler was pointing at. Every
    /// caller stays on the main actor, which is where the composition is built and where the
    /// player item is made.
    public struct Combined {
        public let asset: AVAsset
        /// `nil` when there is no camera — the common case, and the one that must cost nothing.
        public let cameraTrackID: CMPersistentTrackID?
        /// `nil` when there is no music bed. **A track ID rather than an index**, because the
        /// mix has to tell this track from the recording's own and an index shifts the moment a
        /// recording has no system audio — see `AudioMixBuilder`.
        public let musicTrackID: CMPersistentTrackID?

        public init(asset: AVAsset, cameraTrackID: CMPersistentTrackID?,
                    musicTrackID: CMPersistentTrackID? = nil) {
            self.asset = asset
            self.cameraTrackID = cameraTrackID
            self.musicTrackID = musicTrackID
        }
    }

    /// The screen recording with the camera's video laid alongside it.
    ///
    /// **They do not both start at zero, and `cameraStartOffset` is the difference.** This used
    /// to insert both at the same instant and call it an approximation pending the camera's
    /// first-frame host time. That time is now recorded — `CameraRecorder.firstFrameHostTimeNanos`
    /// beside `CaptureSession.Diagnostics.firstFrameHostTimeNanos`, the same anchor
    /// `openObservationLog(atFirstFrame:)` takes for the pointer — so it need not be approximate.
    ///
    /// **Positive means the camera started LATER**, so its picture belongs that far in and the
    /// overlay is absent before then, which is what the person saw; negative means it started
    /// first, so that much of its head is footage of a recording that had not begun and is
    /// trimmed off. A camera takes hundreds of milliseconds to wake and expose, so this is
    /// usually lateness of more than a frame — visible in a hand wave on a small overlay.
    ///
    /// Returns the screen asset untouched when there is no camera, so the common path builds no
    /// composition at all.
    @MainActor
    public static func combine(screen: sending AVAsset,
                               cameraURL: URL?,
                               cameraStartOffset: CMTime = .zero,
                               musicURL: URL? = nil) async throws -> Combined {
        let music = musicURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        guard let cameraURL, FileManager.default.fileExists(atPath: cameraURL.path) else {
            // **A bed with no camera still needs a composition.** The common path returns the
            // screen asset untouched precisely so nothing is built when nothing is added; music
            // is something added, so it takes the same road the camera does.
            guard let music else { return Combined(asset: screen, cameraTrackID: nil) }
            return try await withMusicAlone(screen: screen, musicURL: music)
        }
        let camera = AVURLAsset(url: cameraURL)
        guard let cameraTrack = try await camera.loadTracks(withMediaType: .video).first else {
            return Combined(asset: screen, cameraTrackID: nil)
        }

        let composition = AVMutableComposition()
        let screenDuration = try await screen.load(.duration)
        let whole = CMTimeRange(start: .zero, duration: screenDuration)

        for track in try await screen.loadTracks(withMediaType: .video) {
            guard let inserted = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            try inserted.insertTimeRange(whole, of: track, at: .zero)
        }
        // Audio comes along, or the preview and the export would be silent whenever a camera is
        // on — which is the sort of thing that looks like the microphone broke.
        for track in try await screen.loadTracks(withMediaType: .audio) {
            guard let inserted = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            try inserted.insertTimeRange(whole, of: track, at: .zero)
        }

        guard let cameraSlot = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return Combined(asset: screen, cameraTrackID: nil) }
        // **Clamped to the screen's length.** A camera that kept running a second longer would
        // extend the composition past the recording, and the export would end on a frame of
        // somebody reaching for the keyboard.
        let cameraDuration = try await camera.load(.duration)
        // A late camera is placed late and a head-start is trimmed; either way the material read
        // is clamped so the composition never grows past the screen recording.
        let late = max(cameraStartOffset, .zero)
        let early = max(CMTimeMultiply(cameraStartOffset, multiplier: -1), .zero)
        let room = CMTimeSubtract(screenDuration, late)
        let available = CMTimeSubtract(cameraDuration, early)
        guard room > .zero, available > .zero else {
            // The whole camera falls outside the recording. Better an overlay-free composition
            // than a zero-length track the compositor would still be told to draw.
            return Combined(asset: composition, cameraTrackID: nil)
        }
        let cameraRange = CMTimeRange(start: early, duration: min(available, room))
        try cameraSlot.insertTimeRange(cameraRange, of: cameraTrack, at: late)

        // `flatMap` cannot take an async body, so the optional is unwrapped in the open.
        var musicTrackID: CMPersistentTrackID?
        if let music {
            musicTrackID = try? await insertMusic(from: music, into: composition,
                                                  over: screenDuration)
        }
        return Combined(asset: composition, cameraTrackID: cameraSlot.trackID,
                        musicTrackID: musicTrackID)
    }

    /// The screen plus a bed, with no camera — the same composition minus the overlay track.
    @MainActor
    private static func withMusicAlone(screen: sending AVAsset,
                                       musicURL: URL) async throws -> Combined {
        let composition = AVMutableComposition()
        let screenDuration = try await screen.load(.duration)
        let whole = CMTimeRange(start: .zero, duration: screenDuration)
        for track in try await screen.loadTracks(withMediaType: .video) {
            guard let inserted = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            try inserted.insertTimeRange(whole, of: track, at: .zero)
        }
        for track in try await screen.loadTracks(withMediaType: .audio) {
            guard let inserted = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            try inserted.insertTimeRange(whole, of: track, at: .zero)
        }
        let musicTrackID = try? await insertMusic(from: musicURL, into: composition,
                                            over: screenDuration)
        guard musicTrackID != nil else {
            // Nothing was added, so nothing needs a composition. Handing back the screen asset
            // keeps the no-camera path as cheap as it was.
            return Combined(asset: screen, cameraTrackID: nil, musicTrackID: nil)
        }
        return Combined(asset: composition, cameraTrackID: nil, musicTrackID: musicTrackID)
    }

    /// **The bed, LOOPED to the recording's length and clamped to it.**
    ///
    /// A thirty-second piece under a three-minute demo is thirty seconds of music and two and
    /// a half minutes of nothing, which is worse than no music — so it repeats. The last
    /// repetition is cut to fit rather than allowed to run over, for the same reason the
    /// camera is clamped: a composition longer than the recording ends on material nobody
    /// recorded. Throws rather than returning `nil` on a file with no audio, so a caller that
    /// picked a video by mistake finds out.
    private static func insertMusic(from url: URL, into composition: AVMutableComposition,
                                    over duration: CMTime) async throws -> CMPersistentTrackID? {
        let asset = AVURLAsset(url: url)
        // **The async loaders, and the reason for the synchronous ones had expired.** It said
        // the async form "cannot be awaited from here without making every caller of
        // `insertMusic` async too" — and both callers have been `async throws` for some time.
        // The synchronous `tracks` and `.timeRange` are deprecated because they BLOCK while the
        // asset loads, which on a music file somebody just picked is a stall on whichever
        // thread the composition is being built on.
        guard let source = try await asset.loadTracks(withMediaType: .audio).first
        else { return nil }
        let sourceDuration = try await source.load(.timeRange).duration
        guard sourceDuration > .zero, duration > .zero else { return nil }
        guard let slot = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }

        var placed = CMTime.zero
        // A bound on the loop as well as a condition: a source whose duration reads as a few
        // nanoseconds would otherwise spin here rather than fail.
        var repetitions = 0
        let maximumRepetitions = 10_000
        while placed < duration, repetitions < maximumRepetitions {
            let remaining = CMTimeSubtract(duration, placed)
            let piece = min(sourceDuration, remaining)
            guard piece > .zero else { break }
            try slot.insertTimeRange(CMTimeRange(start: .zero, duration: piece),
                                     of: source, at: placed)
            placed = CMTimeAdd(placed, piece)
            repetitions += 1
        }
        return placed > .zero ? slot.trackID : nil
    }
}
