import AVFoundation
import CoreMedia

/// Re-lays-out planar (non-interleaved) PCM as interleaved PCM, leaving sample values untouched.
///
/// A `.mov` cannot store non-interleaved LPCM and a passthrough `AVAssetWriterInput` cannot
/// re-lay-out what it is handed, so planar buffers must be converted before they are appended.
///
/// Both members are `nonisolated`: `CaptureSession.appendAudio` calls them synchronously on
/// `sampleQueue` from a ScreenCaptureKit callback and cannot await a main-actor hop.
enum AudioInterleave {
    /// Returns `sampleBuffer` unchanged when it is already interleaved, an interleaved copy when
    /// it is not, or `nil` when the layout cannot be read or the copy cannot be made. `nil` is a
    /// drop, which `CaptureSession` counts; one malformed buffer does not fail the recording.
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
        // Identical rate, depth and channel count — this converter only changes interleaving.
        do { try converter.convert(to: outputBuffer, from: inputBuffer) } catch { return nil }

        // A block buffer filled up front and handed to `CMSampleBufferCreateReady`; the
        // `CMSampleBufferCreate` + `CMSampleBufferSetDataBufferFromAudioBufferList` form fails
        // here with `kCMSampleBufferError_RequiredParameterMissing` (-12731) and yields a buffer
        // with no data. The explicit `sampleSizeArray` is required: LPCM needs a constant size.
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

        // The presentation timestamp is carried across unchanged; the session timeline needs it.
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

    /// Root-mean-square amplitude of an interleaved Float32 buffer, 0…1, or `nil` if the buffer
    /// is not readable as Float32.
    ///
    /// A track can be well-formed and correctly timed and still carry nothing; this is recorded
    /// for a caller to judge, never a reason to fail a segment, because silence is legitimate.
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

    /// A one-line description of an audio buffer's actual layout, for the diagnostics.
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
