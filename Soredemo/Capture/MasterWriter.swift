import AVFoundation
import CoreMedia
import Foundation

/// **The seam the writer migration will happen behind.**
///
/// `AVAssetWriter.addInput:`, `startWriting`, `AVAssetWriterInput.append(_:)`
/// and `AVAssetWriterInputPixelBufferAdaptor` are all deprecated at macOS
/// **27.0** — measured, not announced: `scripts/scan-sdk-deprecations.py`
/// reports 78 declarations condemned at exactly that version, and this file's
/// implementation uses four of them. Their successors (`AVAssetWriter.start()`,
/// `inputReceiver(for:)`, `SampleBufferReceiver.append(_:)`) exist and work at
/// this project's 26.0 floor; `spikes/2026-08-03-writer-receiver-hang` writes
/// 3000 frames through them without stalling.
///
/// **So the migration is scheduled, not speculative.** The predecessor dies at
/// 27.0 and this project's floor moves eventually; only the date is unknown.
/// That is what makes this seam different from generalising on spec: today it
/// is one file, and after Phase 2B — with `render-core`, `export-basic` and
/// `render-parity` all writing media — it is a migration.
///
/// **Which implementation sits behind it — re-decided, because the first reason
/// was falsified thirty minutes after it was written.** That reason was "the
/// successor stack cannot write a recording", measured at 2.3 seconds of video.
/// The discriminating experiment then showed the stall was a usage error, and
/// the successors write 3000 frames without pausing. The seam survives that —
/// it is justified by a scheduled deprecation, not by a hang — but the choice
/// behind it had to be made again on true premises. `ARCHITECTURE.md` D2-17 is
/// the same shape: a correct argument outliving the world it referred to.
///
/// **The two properties that decided `AVAssetWriter` over `SCRecordingOutput`
/// were re-measured through the successor, because a redesign changes defaults
/// and neither had ever been checked on that path.** Both are reasons about what
/// the writer does to the FILE: `SCRecordingOutput` mixes the microphone into
/// the system-audio track, and uncontrolled colour tagging cost this project an
/// entire evening. `SoredemoSpikeD --verify` writes a file each way and reads the
/// finished asset back:
///
/// | | audio tracks | colour tags |
/// | --- | --- | --- |
/// | legacy `AVAssetWriterInput` | 2 | ITU_R_709_2 ×3, as requested |
/// | successor `inputReceiver(for:)` | 2 | ITU_R_709_2 ×3, as requested |
///
/// Identical. Neither decisive property is lost on the successor path.
///
/// **So the split is by age of the code, not by capability.** This path — the
/// shipping capture path — stays on the legacy implementation, because what is
/// unverified about the successor is not whether it works but whether a *real*
/// recording works: ScreenCaptureKit's own buffers, a real microphone, a display
/// reconfiguration mid-segment. Those were established by human verification
/// runs (Task 8), and re-establishing them is the actual cost of switching, not
/// the eighty lines of a second conformance.
///
/// **New media-writing code in Phase 2B goes to the successor.** `export-basic`
/// and `render-core` have no migration cost, because they do not exist yet, and
/// writing them against an API that dies at 27.0 would create the second thing
/// this seam exists to prevent. The synchronous `appendImmediately(_:)` maps
/// one-to-one onto today's `append(_:) -> Bool`, so neither side needs an async
/// restructuring to make that split work.
///
/// **The trigger is written down where it will fire:** `ARCHITECTURE.md` D6b-27
/// says re-run Spike D on every OS or SDK version bump. `26 fails / 27 works`
/// and `both fail` point at opposite strategies, and the run costs a minute.
///
/// **Deliberately not a general media abstraction.** It has exactly the three
/// tracks `CaptureSession` writes and exactly the operations it performs. A
/// wider surface would be a second thing to migrate rather than a smaller one.

/// The writer's own state, as this app needs to read it.
///
/// Its own enum rather than `AVAssetWriter.Status`: the framework's type on this
/// side of the seam would make every `switch` in `CaptureSession` a place the
/// migration has to touch, which is the thing the seam exists to prevent. The
/// cases are the same five because those are the five states that exist, not
/// because they are being passed through.
nonisolated enum MasterWriterStatus: Sendable, Equatable {
    case unknown
    case writing
    case completed
    case failed
    case cancelled
    /// A state this build does not know. Carries the raw value so a report can
    /// say which, rather than "unrecognised".
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
/// **`nonisolated`, and every type in this file is.** The app target builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so an unannotated declaration is
/// MainActor-isolated — and every append here happens on a ScreenCaptureKit
/// delivery queue, which is not the main actor. Reaching an isolated member from
/// there traps at runtime with only a warning at compile time, which is how
/// `ObservationWriter` and `LiveAXElementSource` each cost this project a
/// debugging session. A seam that traps the first time a real frame arrives is
/// worse than no seam.
nonisolated protocol MasterTrackWriting: AnyObject, Sendable {
    /// The writer's backpressure signal. An append while this is `false` is
    /// refused, and — for a passthrough audio input — refusing once fails the
    /// whole writer, taking the video track with it.
    var isReadyForMoreMediaData: Bool { get }

    /// `false` means the writer refused it. The caller records that; it never
    /// retries, because a refusal here is a writer that has already failed.
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

    /// The session's source-time origin. Called once, on the first frame that
    /// is actually appended — not at `start`, because the origin has to be a
    /// timestamp that exists.
    func startSession(at presentationTime: CMTime)

    func finish() async
}

/// **Today's implementation, on the API that dies at macOS 27.0.**
///
/// `@unchecked Sendable` for the same reason `CaptureSession` declares its
/// writer references `nonisolated(unsafe)`: `AVAssetWriter` and
/// `AVAssetWriterInput` are not `Sendable`, and the discipline that makes their
/// use safe here is the caller's — every append happens on a ScreenCaptureKit
/// delivery queue, guarded by the readiness check above it, and the references
/// are published once under `CaptureSession`'s lock before any callback can see
/// them. Moving that discipline behind this type would hide it; this comment
/// keeps it where it already lives.
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

    /// Builds the writer with all three tracks and starts it, or throws.
    ///
    /// The video settings and the two passthrough audio inputs are the
    /// caller's, unchanged — see `CaptureSession` for why audio is passthrough
    /// (`D2-8`: the master is unprocessed evidence) and why the colour
    /// properties are pinned.
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
