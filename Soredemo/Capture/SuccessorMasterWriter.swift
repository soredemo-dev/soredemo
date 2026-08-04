import AVFoundation
import CoreMedia
import Foundation

/// **The second conformance behind the seam — see `MasterWriter.swift`'s header for why it
/// exists and why `CaptureSession` does not use it yet.** That header already re-measured the two
/// properties that decided `AVAssetWriter` over `SCRecordingOutput` on this path (two audio
/// tracks, the pinned colour tags) through `SoredemoSpikeD --verify`; the differential section of
/// `scripts/cross-boundary-digest-probe.swift` repeats that measurement against the real
/// `MasterWriting` conformance rather than the spike's throwaway rig, comparing the two finished
/// FILES rather than either writer's account of itself.
///
/// Built on `AVAssetWriter.start()`, `AVAssetWriterInput.inputReceiver(for:)` and
/// `SampleBufferReceiver.appendImmediately(_:)` — the three successors `MasterWriter.swift` names,
/// none of them deprecated at this project's 26.0 floor.
///
/// **Order matters, and getting it wrong stalls with no error, no crash, no diagnostic.**
/// `spikes/2026-08-03-writer-receiver-hang` measured a stall at frame 137 from mixing `add(_:)` /
/// `startWriting()` with a receiver taken for the same input — two lifecycles at once, a state
/// nobody designed. So this type takes every receiver FIRST, then calls `start()`, then
/// `startSession(at:)` — never `add(_:)`, never `startWriting()`.
///
/// **`isReadyForMoreMediaData` has no successor.** `AVAssetWriterInput.SampleBufferReceiver`
/// — dumped with `swift-api-digester -dump-sdk` while writing this file, because no header or
/// `.swiftinterface` names its members — has exactly three: `append(_:)`, `appendImmediately(_:)`,
/// `finish()`. No readiness getter. The deprecation message on the OLD `isReadyForMoreMediaData`
/// itself says "Use the input receiver's async append(...) method instead" — the redesign's
/// answer to "is it ready" is "suspend until it is," which the awaiting `append(_:)` does and the
/// non-suspending `appendImmediately(_:)` used below does not. `MasterTrackWriting.append` must
/// not suspend (`CaptureSession` calls it from a ScreenCaptureKit delivery queue it cannot block),
/// so this conformance keeps reading the underlying `AVAssetWriterInput`'s own
/// `isReadyForMoreMediaData` — a real, live signal even though the input is never `add(_:)`-ed the
/// old way, measured directly: pushing 30 synthetic frames through this exact shape, it read
/// `true` for four frames, then `false` for 25 polls before the encoder drained, then `true`
/// again, and the finished file completed normally. It is not one of the four calls
/// `MasterWriter.swift`'s header measures as condemned (`addInput:`, `startWriting`,
/// `AVAssetWriterInput.append(_:)`, the pixel-buffer adaptor); it is a fifth, separately
/// deprecated property with no replacement of its own, kept because `MasterTrackWriting`'s
/// contract needs a real pre-check: `append`'s `false` must mean "the writer already failed," not
/// "call again in a moment," and only a genuine readiness read keeps those apart.
///
/// **`expectsMediaDataInRealTime` is left at its default (`false`), deliberately not copied from
/// `LegacyMasterWriter`.** Its own deprecation message says its replacement is exactly
/// `appendImmediately(_:)` — calling that method IS the real-time behaviour on this path, so
/// setting the old property as well would be asking the redesign for the thing it already does.
///
/// **`refusedInput` is threaded through but never called.** It exists so this initializer has the
/// exact shape `LegacyMasterWriter.init(outputURL:videoSettings:refusedInput:startFailed:) throws`
/// has, which is what lets the differential probe build both conformances from one call site. It
/// has nothing to call it for: `inputReceiver(for:)` returns a `SampleBufferReceiver` directly,
/// not an optional and not a throwing call (confirmed with the same digester dump) — the
/// successor stack has no "refused" outcome at this point for `refusedInput` to report.
///
/// `@unchecked Sendable` for the same reason as `LegacyMasterWriter`: `AVAssetWriter`,
/// `AVAssetWriterInput` and `SampleBufferReceiver` are not `Sendable`, and the discipline that
/// makes their use safe here is the caller's, not this type's — every append happens on a
/// ScreenCaptureKit delivery queue (or, in the differential probe, a single synchronous caller),
/// guarded by `isReadyForMoreMediaData` ahead of it.
///
/// **A known gap this conformance does NOT paper over: driving three simultaneous receivers
/// through `appendImmediately(_:)` as fast as the caller can push, with no artificial pacing,
/// reproducibly stalled in testing** — `isReadyForMoreMediaData` (and, separately,
/// `appendImmediately(_:)`'s own return value driven in a bare retry loop) stopped reporting
/// ready again somewhere between frame 64 and frame 112 across a dozen runs, independent of
/// codec, with no error and no crash. The SAME workload through the AWAITING `append(_:)`
/// (unusable here — `MasterTrackWriting.append` must not suspend) completed 120 frames in under
/// 0.3 s every time. This looks like a real gap in `appendImmediately(_:)` under concurrent
/// multi-track load in this SDK, not a usage error on the order this header already documents —
/// see the Task 6 report for the full measurement. It is the concrete reason
/// `MasterWriter.swift`'s own header keeps `CaptureSession` on `LegacyMasterWriter`, and why
/// `ARCHITECTURE.md` D6b-27's "re-run Spike D on every OS/SDK bump" exists: this finding belongs
/// to a future Spike D run, not to a change made here under a differential-test deadline.
nonisolated final class SuccessorMasterWriter: MasterWriting, @unchecked Sendable {
    private let writer: AVAssetWriter
    private let videoTrack: SuccessorMasterTrack
    private let systemAudioTrack: SuccessorMasterTrack
    private let microphoneTrack: SuccessorMasterTrack
    private let errorBox: SuccessorAppendErrorBox

    var outputURL: URL { writer.outputURL }
    var video: any MasterTrackWriting { videoTrack }
    var systemAudio: any MasterTrackWriting { systemAudioTrack }
    var microphone: any MasterTrackWriting { microphoneTrack }

    /// A captured `appendImmediately(_:)` throw takes priority over the writer's own `.error`:
    /// it is more specific about what actually happened, and it is the only place the throwing
    /// mismatch (see `SuccessorMasterTrack.append(_:)`) becomes visible instead of silently
    /// wearing the same `false` a plain refusal already returns.
    var errorDescription: String? {
        errorBox.capturedAppendError ?? writer.error.map { String(describing: $0) }
    }

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

    /// Builds the writer with all three tracks and starts it, or throws. See this type's header
    /// for the order (every receiver, then `start()`, then the caller's `startSession(at:)`) and
    /// for why `refusedInput` is accepted but never invoked.
    init(outputURL: URL, videoSettings: [String: Any],
         refusedInput: (String) -> Error, startFailed: (String?) -> Error) throws {
        let writer = try AVAssetWriter(url: outputURL, fileType: .mov)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        let systemAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
        let micInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)

        // Every receiver FIRST — no `add(_:)` for any of the three — and only THEN `start()`.
        // Reversing this order, or calling `add(_:)`/`startWriting()` anywhere in between, is
        // exactly the usage error `spikes/2026-08-03-writer-receiver-hang` measured stalling at
        // frame 137 with no error and no diagnostic.
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

    func startSession(at presentationTime: CMTime) {
        writer.startSession(atSourceTime: presentationTime)
    }

    func finish() async {
        // `finish()` on each receiver, mirroring `markAsFinished()` on the legacy path, before
        // asking the writer to finish — the same order `spikes/2026-08-03-writer-receiver-hang`
        // uses for the successor lifecycle.
        videoTrack.finishReceiver()
        systemAudioTrack.finishReceiver()
        microphoneTrack.finishReceiver()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
    }
}

/// Where a thrown `appendImmediately(_:)` error goes. Shared by all three tracks, because
/// `errorDescription` above is one property on the writer, not three on the tracks. Only the
/// FIRST captured error is kept — matching `AVAssetWriter.error`, which is also a single summary
/// rather than a log, and because once one track's append has thrown, later throws are almost
/// certainly the same failure being reported again.
nonisolated final class SuccessorAppendErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _capturedAppendError: String?

    func record(_ error: Error) {
        lock.withLock {
            if _capturedAppendError == nil {
                _capturedAppendError = String(describing: error)
            }
        }
    }

    var capturedAppendError: String? { lock.withLock { _capturedAppendError } }
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

    /// See this file's header for why this reads the underlying input rather than the receiver,
    /// which has no such member at all.
    var isReadyForMoreMediaData: Bool { input.isReadyForMoreMediaData }

    /// **The mismatch the task brief calls out: `appendImmediately(_:)` throws, and
    /// `MasterTrackWriting.append` does not.** Swallowing the throw into a bare `false` would make
    /// it wear the same value a plain refusal already returns, and the two are not the same fact
    /// — see `MasterTrackWriting.append`'s own doc comment in `MasterWriter.swift`: `false` there
    /// means "the writer refused it, and it has already failed." A throw from `appendImmediately`
    /// is at least as final (measured: it did not throw for an append issued after `finish()`,
    /// which instead just returned `false` — the ordinary refusal path; a throw is reserved for
    /// something the ordinary refusal path does not cover), so returning `false` for it too is
    /// the right value. What must not happen is losing which one occurred, so the error is
    /// recorded into `errorBox` — reachable through `SuccessorMasterWriter.errorDescription` —
    /// before this returns, never discarded.
    func append(_ sampleBuffer: CMSampleBuffer) -> Bool {
        // `CMReadySampleBuffer.init(unsafeBuffer:)` consumes its argument as `sending`, and
        // `MasterTrackWriting.append`'s parameter is plain `CMSampleBuffer` (not `sending`) —
        // fixed by the protocol this file mirrors, so it cannot be changed here. Swift 6's
        // region checker then cannot prove the caller has no other live reference to
        // `sampleBuffer` and refuses to send it onward
        // (`#RegionIsolation::SendingRisksDataRace`). `nonisolated(unsafe)` on this local
        // re-states the discipline this whole file already runs on: every append happens on a
        // ScreenCaptureKit delivery queue that owns the buffer for the duration of the call, the
        // same reasoning `CaptureSession` already gives its own `nonisolated(unsafe)` storage.
        nonisolated(unsafe) let ownedForSend = sampleBuffer
        let ready = CMReadySampleBuffer<CMSampleBuffer.DynamicContent>(unsafeBuffer: ownedForSend)
        do {
            return try receiver.appendImmediately(ready)
        } catch {
            errorBox.record(error)
            return false
        }
    }

    func finishReceiver() {
        receiver.finish()
    }
}
