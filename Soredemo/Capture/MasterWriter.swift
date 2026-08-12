import AVFoundation
import CoreMedia
import Foundation
// Capture types that moved into `Headless` in Phase 3A-3.
import Headless

/// The seam the writer migration will happen behind.
///
/// `AVAssetWriter.addInput:`, `startWriting`, `AVAssetWriterInput.append(_:)` and
/// `AVAssetWriterInputPixelBufferAdaptor` are deprecated at macOS 27.0; their successors
/// (`AVAssetWriter.start()`, `inputReceiver(for:)`, `SampleBufferReceiver.append(_:)`) work at
/// this project's 26.0 floor. The shipping capture path stays on the legacy implementation
/// because the successor's `appendImmediately(_:)` stalls under three concurrent receivers — see
/// `SuccessorMasterWriter`. New media-writing code goes to the successor.
///
/// Not a general media abstraction: exactly the three tracks `CaptureSession` writes and exactly
/// the operations it performs.

/// The writer's own state, as this app needs to read it. Its own enum rather than
/// `AVAssetWriter.Status`, so the migration does not have to touch every `switch` in
/// `CaptureSession`.
nonisolated enum MasterWriterStatus: Sendable, Equatable {
    case unknown
    case writing
    case completed
    case failed
    case cancelled
    /// A state this build does not know; carries the raw value so a report can say which.
    case unrecognised(Int)

    var name: String {
        switch self {
        case .unknown: "unknown"
        case .writing: "writing"
        case .completed: "completed"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case .unrecognised(let raw): "unrecognised(\(raw))"
        }
    }
}

/// One track of the master recording.
///
/// `nonisolated`, as is every type in this file: the app target builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and every append happens on a ScreenCaptureKit
/// delivery queue, where reaching a MainActor-isolated member traps at runtime.
nonisolated protocol MasterTrackWriting: AnyObject, Sendable {
    /// The writer's backpressure signal. An append while this is `false` is refused, and for a
    /// passthrough audio input one refusal fails the whole writer, video track included.
    var isReadyForMoreMediaData: Bool { get }

    /// `false` means the writer refused it and has already failed; the caller never retries.
    func append(_ sampleBuffer: CMSampleBuffer) -> Bool
}

/// The master file being written: three tracks and a lifecycle.
nonisolated protocol MasterWriting: AnyObject, Sendable {
    var outputURL: URL { get }

    var video: any MasterTrackWriting { get }
    var systemAudio: any MasterTrackWriting { get }
    var microphone: any MasterTrackWriting { get }

    var status: MasterWriterStatus { get }
    var errorDescription: String? { get }

    /// The session's source-time origin. Called once, on the first frame actually appended — not
    /// at `start`, because the origin has to be a timestamp that exists.
    func startSession(at presentationTime: CMTime)

    func finish() async
}

/// Today's implementation, on the API deprecated at macOS 27.0.
///
/// `@unchecked Sendable`: `AVAssetWriter` and `AVAssetWriterInput` are not `Sendable`, and the
/// discipline that makes them safe here is the caller's — every append happens on a
/// ScreenCaptureKit delivery queue, guarded by the readiness check, on references published once
/// under `CaptureSession`'s lock before any callback can see them.
nonisolated final class LegacyMasterWriter: MasterWriting, @unchecked Sendable {
    private let writer: AVAssetWriter
    private let videoTrack: LegacyMasterTrack
    private let systemAudioTrack: LegacyMasterTrack
    private let microphoneTrack: LegacyMasterTrack

    var outputURL: URL { writer.outputURL }
    var video: any MasterTrackWriting { videoTrack }
    var systemAudio: any MasterTrackWriting { systemAudioTrack }
    var microphone: any MasterTrackWriting { microphoneTrack }

    var errorDescription: String? { writer.error.map { String(describing: $0) } }

    var status: MasterWriterStatus {
        switch writer.status {
        case .unknown: .unknown
        case .writing: .writing
        case .completed: .completed
        case .failed: .failed
        case .cancelled: .cancelled
        @unknown default: .unrecognised(writer.status.rawValue)
        }
    }

    /// Builds the writer with all three tracks and starts it, or throws. The video settings and
    /// the two passthrough audio inputs are the caller's, unchanged.
    init(outputURL: URL, videoSettings: [String: Any],
         refusedInput: (String) -> Error, startFailed: (String?) -> Error) throws {
        let writer = try AVAssetWriter(url: outputURL, fileType: .mov)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        let systemAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
        systemAudioInput.expectsMediaDataInRealTime = true
        let micInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
        micInput.expectsMediaDataInRealTime = true

        for input in [videoInput, systemAudioInput, micInput] {
            guard writer.canAdd(input) else {
                throw refusedInput(input.mediaType.rawValue)
            }
            writer.add(input)
        }
        guard writer.startWriting() else {
            throw startFailed(writer.error?.localizedDescription)
        }

        self.writer = writer
        self.videoTrack = LegacyMasterTrack(input: videoInput)
        self.systemAudioTrack = LegacyMasterTrack(input: systemAudioInput)
        self.microphoneTrack = LegacyMasterTrack(input: micInput)
    }

    func startSession(at presentationTime: CMTime) {
        writer.startSession(atSourceTime: presentationTime)
    }

    func finish() async {
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
    }
}

nonisolated final class LegacyMasterTrack: MasterTrackWriting, @unchecked Sendable {
    private let input: AVAssetWriterInput

    init(input: AVAssetWriterInput) {
        self.input = input
    }

    var isReadyForMoreMediaData: Bool { input.isReadyForMoreMediaData }

    func append(_ sampleBuffer: CMSampleBuffer) -> Bool {
        input.append(sampleBuffer)
    }
}
