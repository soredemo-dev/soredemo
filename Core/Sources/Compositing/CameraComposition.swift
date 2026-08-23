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
    }

    /// The screen recording with the camera's video laid alongside it.
    ///
    /// **Both start at zero.** `CameraRecorder` and `CaptureSession` are started one after the
    /// other, so the two files begin within a few frames of each other and are inserted at the
    /// same instant. That is an approximation and it is stated here rather than implied: a
    /// correction needs the camera's first-frame host time recorded next to the screen's, which
    /// is the same anchor problem `openObservationLog(atFirstFrame:)` solved for the pointer and
    /// is not yet solved for this. A few frames of lip-sync error on an overlay is visible; a
    /// few frames on a talking head filling the screen would not be tolerable, and this overlay
    /// is small.
    ///
    /// Returns the screen asset untouched when there is no camera, so the common path builds no
    /// composition at all.
    @MainActor
    public static func combine(screen: sending AVAsset,
                               cameraURL: URL?) async throws -> Combined {
        guard let cameraURL, FileManager.default.fileExists(atPath: cameraURL.path) else {
            return Combined(asset: screen, cameraTrackID: nil)
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
        let cameraRange = CMTimeRange(start: .zero,
                                      duration: min(cameraDuration, screenDuration))
        try cameraSlot.insertTimeRange(cameraRange, of: cameraTrack, at: .zero)

        return Combined(asset: composition, cameraTrackID: cameraSlot.trackID)
    }
}
