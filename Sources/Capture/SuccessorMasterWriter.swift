import AVFoundation
import CoreMedia
import Foundation

/// The second conformance behind the seam (see `MasterWriter.swift`), built on
/// `AVAssetWriter.start()`, `AVAssetWriterInput.inputReceiver(for:)` and
/// `SampleBufferReceiver.appendImmediately(_:)` — none deprecated at this project's 26.0 floor.
///
/// Order matters: every receiver is taken FIRST, then `start()`, then `startSession(at:)`, never
/// `add(_:)` and never `startWriting()`. Mixing `add(_:)`/`startWriting()` with a receiver taken
/// for the same input stalls with no error, no crash and no diagnostic.
///
/// `SampleBufferReceiver` has no readiness getter, and its awaiting `append(_:)` cannot be used
/// because `MasterTrackWriting.append` must not suspend (`CaptureSession` calls it from a
/// ScreenCaptureKit delivery queue it cannot block). So this conformance reads the underlying
/// `AVAssetWriterInput.isReadyForMoreMediaData` — a live signal even though the input is never
/// `add(_:)`-ed, separately deprecated with no replacement of its own.
///
/// `expectsMediaDataInRealTime` is left at its default: `appendImmediately(_:)` is its documented
/// replacement, so calling that method is the real-time behaviour on this path.
///
/// `refusedInput` is accepted but never called; it only gives this initializer the same shape as
/// `LegacyMasterWriter.init`. `inputReceiver(for:)` neither throws nor returns an optional, so
/// the successor stack has no "refused" outcome here.
///
/// `@unchecked Sendable` for the same reason as `LegacyMasterWriter`: the AVFoundation types are
/// not `Sendable`, and the discipline is the caller's — every append happens on a ScreenCaptureKit
/// delivery queue, guarded by `isReadyForMoreMediaData` ahead of it.
///
/// Known gap: three simultaneous receivers driven through `appendImmediately(_:)` with no pacing
/// reproducibly stall, never reporting ready again, with no error and no crash; the same load
/// through the awaiting `append(_:)` does not. This is why `CaptureSession` stays on
/// `LegacyMasterWriter`.
nonisolated final class SuccessorMasterWriter: MasterWriting, @unchecked Sendable {
    private let writer: AVAssetWriter
    private let videoTrack: SuccessorMasterTrack
    private let systemAudioTrack: SuccessorMasterTrack
    private let microphoneTrack: SuccessorMasterTrack
    private let errorBox: SuccessorAppendErrorBox

    public var outputURL: URL { writer.outputURL }
    public var video: any MasterTrackWriting { videoTrack }
    public var systemAudio: any MasterTrackWriting { systemAudioTrack }
    public var microphone: any MasterTrackWriting { microphoneTrack }

    /// A captured `appendImmediately(_:)` throw takes priority over the writer's own `.error`: it
    /// is the only place the throwing mismatch (see `SuccessorMasterTrack.append(_:)`) is visible.
    public var errorDescription: String? {
        errorBox.capturedAppendError ?? writer.error.map { String(describing: $0) }
    }

    public var status: MasterWriterStatus {
        switch writer.status {
        case .unknown: .unknown
        case .writing: .writing
        case .completed: .completed
        case .failed: .failed
        case .cancelled: .cancelled
        @unknown default: .unrecognised(writer.status.rawValue)
        }
    }

    /// Builds the writer with all three tracks and starts it, or throws. See this type's header
    /// for the receiver-then-`start()` order and for why `refusedInput` is never invoked.
    init(outputURL: URL, videoSettings: [String: Any],
         refusedInput: (String) -> Error, startFailed: (String?) -> Error) throws {
        let writer = try AVAssetWriter(url: outputURL, fileType: .mov)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        let systemAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
        let micInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)

        // Every receiver FIRST — no `add(_:)` for any of the three — and only THEN `start()`.
        // Reversing this order, or calling `add(_:)`/`startWriting()` anywhere in between,
        // stalls the writer with no error and no diagnostic.
        let videoReceiver = writer.inputReceiver(for: videoInput)
        let systemAudioReceiver = writer.inputReceiver(for: systemAudioInput)
        let micReceiver = writer.inputReceiver(for: micInput)

        do {
            try writer.start()
        } catch {
            throw startFailed(error.localizedDescription)
        }

        let errorBox = SuccessorAppendErrorBox()
        self.writer = writer
        self.errorBox = errorBox
        self.videoTrack = SuccessorMasterTrack(input: videoInput, receiver: videoReceiver, errorBox: errorBox)
        self.systemAudioTrack = SuccessorMasterTrack(
            input: systemAudioInput, receiver: systemAudioReceiver, errorBox: errorBox)
        self.microphoneTrack = SuccessorMasterTrack(input: micInput, receiver: micReceiver, errorBox: errorBox)
    }

    public func startSession(at presentationTime: CMTime) {
        writer.startSession(atSourceTime: presentationTime)
    }

    public func finish() async {
        // `finish()` on each receiver, mirroring `markAsFinished()` on the legacy path, before
        // asking the writer to finish.
        videoTrack.finishReceiver()
        systemAudioTrack.finishReceiver()
        microphoneTrack.finishReceiver()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
    }
}

/// Where a thrown `appendImmediately(_:)` error goes. Shared by all three tracks because
/// `errorDescription` above is one property on the writer. Only the FIRST captured error is kept,
/// matching `AVAssetWriter.error`.
nonisolated final class SuccessorAppendErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _capturedAppendError: String?

    public func record(_ error: Error) {
        lock.withLock {
            if _capturedAppendError == nil {
                _capturedAppendError = String(describing: error)
            }
        }
    }

    public var capturedAppendError: String? { lock.withLock { _capturedAppendError } }
}

nonisolated final class SuccessorMasterTrack: MasterTrackWriting, @unchecked Sendable {
    private let input: AVAssetWriterInput
    private let receiver: AVAssetWriterInput.SampleBufferReceiver
    private let errorBox: SuccessorAppendErrorBox

    init(input: AVAssetWriterInput, receiver: AVAssetWriterInput.SampleBufferReceiver,
         errorBox: SuccessorAppendErrorBox) {
        self.input = input
        self.receiver = receiver
        self.errorBox = errorBox
    }

    /// Reads the underlying input rather than the receiver, which has no such member.
    public var isReadyForMoreMediaData: Bool { input.isReadyForMoreMediaData }

    /// `appendImmediately(_:)` throws where `MasterTrackWriting.append` does not. A throw is at
    /// least as final as a plain refusal, so it also returns `false`, but the error is recorded
    /// into `errorBox` — reachable through `SuccessorMasterWriter.errorDescription` — first.
    public func append(_ sampleBuffer: CMSampleBuffer) -> Bool {
        // `CMReadySampleBuffer.init(unsafeBuffer:)` consumes its argument as `sending` while
        // `MasterTrackWriting.append`'s parameter is plain `CMSampleBuffer`, so the region checker
        // refuses to send it onward. `nonisolated(unsafe)` re-states this file's discipline: the
        // ScreenCaptureKit delivery queue owns the buffer for the duration of the call.
        nonisolated(unsafe) let ownedForSend = sampleBuffer
        // Safe here for the reason stated just above: the delivery queue owns the buffer
        // for the whole call, and `ready` does not outlive it. The mark is what
        // `.strictMemorySafety()` asks for now that this file is in a package target.
        let ready = unsafe CMReadySampleBuffer<CMSampleBuffer.DynamicContent>(unsafeBuffer: ownedForSend)
        do {
            return try receiver.appendImmediately(ready)
        } catch {
            errorBox.record(error)
            return false
        }
    }

    public func finishReceiver() {
        receiver.finish()
    }
}
