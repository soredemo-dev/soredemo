import AVFoundation
import CoreMedia

/// Re-lays-out planar (non-interleaved) PCM as interleaved PCM, leaving the
/// samples themselves untouched.
///
/// **Why this exists.** `CaptureSession` writes both audio tracks with
/// `outputSettings: nil` — passthrough — because the master is unprocessed
/// evidence (D2-8) and re-encoding it is exactly the processing that
/// principle argues against. That file's own comment used to claim
/// "passthrough into a QuickTime movie needs no format hint". Measured, the
/// claim is false in one specific way: a `.mov` cannot store non-interleaved
/// LPCM, and a passthrough input cannot re-lay-out what it is handed, so the
/// very first audio append is refused with `-11800 / -12780` — and that
/// refusal fails the whole `AVAssetWriter`, taking the video track with it.
/// Task 8's step 1 recorded 310 unresampled frames into a zero-byte file for
/// exactly this reason.
///
/// **Interleaving is not processing.** Every sample keeps its value, its
/// channel and its position; only the order of bytes in memory changes.
/// That is why this is the right fix rather than giving the input explicit
/// `outputSettings`, which would hand the samples to an encoder.
///
/// This is a free function on purpose: it reads no state, and the whole
/// point of the defect it fixes is that a value that mattered was invisible
/// at its call site.
/// **`nonisolated` on both members, deliberately, not left to
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.** Both are called from
/// `CaptureSession.appendAudio`, which runs synchronously on
/// `sampleQueue` from ScreenCaptureKit's callback and cannot await a main
/// actor hop. Verified by compiling: without these annotations the build
/// fails with "call to main actor-isolated static method … in a synchronous
/// nonisolated context" — the same reason every stored property in
/// `CaptureSession` carries `nonisolated(unsafe)`. Neither function reads
/// any state; the isolation here is about where they may be called, not
/// about what they protect.
enum AudioInterleave {
    /// Returns `sampleBuffer` unchanged when it is already interleaved, an
    /// interleaved copy when it is not, or `nil` when the layout cannot be
    /// read or the copy cannot be made.
    ///
    /// `nil` is a drop, and `CaptureSession` counts drops. It is not a trap:
    /// killing a recording in progress over one malformed audio buffer is
    /// the worse of the two failures.
    nonisolated static func interleaved(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let inputFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        if inputFormat.isInterleaved { return sampleBuffer }

        guard let outputFormat = AVAudioFormat(commonFormat: inputFormat.commonFormat,
                                                sampleRate: inputFormat.sampleRate,
                                                channels: inputFormat.channelCount,
                                                interleaved: true) else { return nil }

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frames)
        else { return nil }
        inputBuffer.frameLength = frames

        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sampleBuffer, at: 0, frameCount: Int32(frames),
                into: inputBuffer.mutableAudioBufferList) == noErr,
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { return nil }
        // Same sample rate, same bit depth, same channel count — the only
        // difference in the two formats is `interleaved`. There is no
        // resampling and no requantisation for this converter to do.
        do { try converter.convert(to: outputBuffer, from: inputBuffer) } catch { return nil }

        // A block buffer, filled and then handed to `CMSampleBufferCreateReady`
        // — NOT `CMSampleBufferCreate(dataBuffer: nil, …)` followed by
        // `CMSampleBufferSetDataBufferFromAudioBufferList`. That second form
        // is the obvious one and it fails here with
        // `kCMSampleBufferError_RequiredParameterMissing` (-12731), returning
        // a buffer with no data at all. Measured: it is what made this
        // function drop 1045 of 1045 system-audio buffers on its first run,
        // and — separately — what made an earlier offline fixture produce a
        // real-looking AVFoundation error about something it was not about.
        //
        // The explicit `sampleSizeArray` is load-bearing for the same reason:
        // LPCM needs a constant sample size, and omitting it is half of what
        // -12731 is complaining about.
        let bytesPerFrame = Int(outputFormat.streamDescription.pointee.mBytesPerFrame)
        let totalBytes = bytesPerFrame * Int(outputBuffer.frameLength)
        guard totalBytes > 0 else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: totalBytes,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: totalBytes,
                flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block,
              let source = outputBuffer.audioBufferList.pointee.mBuffers.mData,
              CMBlockBufferReplaceDataBytes(with: source, blockBuffer: block,
                                             offsetIntoDestination: 0, dataLength: totalBytes) == noErr
        else { return nil }

        // The presentation timestamp is carried across unchanged. It is the
        // one property of the buffer that the rest of the session's timeline
        // depends on, and a re-layout has no business moving it.
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(outputFormat.sampleRate)),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            decodeTimeStamp: .invalid)
        var sampleSize = bytesPerFrame
        var rebuilt: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: block,
                formatDescription: outputFormat.formatDescription,
                sampleCount: CMItemCount(outputBuffer.frameLength), sampleTimingEntryCount: 1,
                sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize, sampleBufferOut: &rebuilt) == noErr,
              let rebuilt
        else { return nil }
        return rebuilt
    }

    /// Root-mean-square amplitude of an interleaved Float32 buffer, 0…1, or
    /// `nil` if the buffer is not readable as Float32.
    ///
    /// The audio counterpart of `CaptureSession.checkForBlackFrame`, and it
    /// exists for the same reason: a track can be present, well-formed, the
    /// right length, correctly timed, and carry **nothing**. Every count in
    /// `AudioTrackAccounting` can balance perfectly over silence — the
    /// buffers arrived, were converted, and were appended, and every one of
    /// them was zeros. Accounting answers "did anything get lost"; this
    /// answers "was there anything to lose".
    ///
    /// Recorded, not asserted, exactly like the black-frame detector: a
    /// genuinely silent recording is legitimate (a demo with no sound), so
    /// this is a number for a caller to judge, never a reason to fail a
    /// segment.
    nonisolated static func rms(of sampleBuffer: CMSampleBuffer) -> Double? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
              asbd.mBitsPerChannel == 32,
              (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0,
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
        else { return nil }

        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                           totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer, length >= 4
        else { return nil }
        let count = length / 4
        var sum = 0.0
        pointer.withMemoryRebound(to: Float.self, capacity: count) { floats in
            for i in 0..<count { sum += Double(floats[i]) * Double(floats[i]) }
        }
        return (sum / Double(count)).squareRoot()
    }

    /// A one-line description of an audio buffer's actual layout, for the
    /// diagnostics.
    ///
    /// **Recorded rather than inferred.** The conclusion "ScreenCaptureKit
    /// delivers planar audio" was reached by matching an error code against
    /// four offline trials — good evidence, and still an inference about
    /// what the OS hands over. This prints what it actually handed over.
    nonisolated static func layoutDescription(of sampleBuffer: CMSampleBuffer) -> String {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
        else { return "no audio format description" }
        let interleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        return "\(asbd.mChannelsPerFrame)ch \(asbd.mBitsPerChannel)-bit "
            + "\((asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0 ? "float" : "int") "
            + "@\(Int(asbd.mSampleRate))Hz, \(interleaved ? "INTERLEAVED" : "PLANAR"), "
            + "bytesPerFrame \(asbd.mBytesPerFrame)"
    }
}
