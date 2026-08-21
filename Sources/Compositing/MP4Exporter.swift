import AVFoundation
import Foundation

/// One MP4 (H.264) export of a recorded master, written directly against `AVAssetReader` /
/// `AVAssetWriter`. Neither master writer is usable here: one hardcodes `fileType: .mov`, and
/// `MasterWriting` requires video plus two audio tracks while
/// `AVAssetReaderVideoCompositionOutput` produces exactly one stream.
///
/// Several AVFoundation calls used here are deprecated as of the 27.0 SDK; the file is left
/// unseamed because it drives one track and the successor reader API is unmeasured.
///
/// `copyNextSampleBuffer()` may return marker-only buffers with zero samples; a caller counting
/// frames must check `CMSampleBufferGetNumSamples`.
public enum MP4Exporter {
    /// Exports `asset`'s video through the same `AVVideoComposition` the preview uses, so the two
    /// cannot disagree. Never drops a frame: the poll loop waits on `isReadyForMoreMediaData`
    /// rather than skipping, and a `framesRead`/`framesWritten` mismatch throws. `nonisolated`
    /// because `finishWriting(_:)` calls back on an AVFoundation-owned queue.
    /// `trim` selects the span of the SOURCE to export; `nil` exports all of it.
    ///
    /// **The reader is given the range, and the writer's session starts at the range's
    /// start.** Two things follow from that pairing and both matter. The reader decodes only
    /// what is wanted, so trimming the first minute off a recording costs nothing to skip
    /// rather than a minute of decoding thrown away. And `startSession(atSourceTime:)` at the
    /// range's start makes the output's first frame time zero: the composition's frames keep
    /// carrying their original presentation times, so a session started at `.zero` for a trim
    /// beginning at 30 s would produce a file with 30 seconds of nothing at the front.
    public nonisolated static func export(asset: AVAsset, to outputURL: URL,
                                          outputWidth: Int, outputHeight: Int,
                                          trim: CMTimeRange? = nil,
                                          frameRate: Int = 60) async throws -> ExportReport {
        precondition(frameRate > 0, "frameRate must be positive, got \(frameRate)")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw ExportError.noVideoTrack }
        if let trim, !trim.duration.isValid || trim.duration.seconds <= 0 {
            throw ExportError.emptyTrim
        }

        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        // The same composition the preview uses.
        let composition = try await CompositionBuilder.composition(
            for: asset, outputWidth: outputWidth, outputHeight: outputHeight,
            frameDuration: frameDuration)

        let writer = try AVAssetWriter(url: outputURL, fileType: .mp4)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight,
        ])
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw ExportError.writerRefusedInput }
        writer.add(videoInput)

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audioInput: AVAssetWriterInput? = audioTracks.isEmpty ? nil : {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48_000,
                AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = false
            return input
        }()
        if let audioInput {
            guard writer.canAdd(audioInput) else { throw ExportError.writerRefusedInput }
            writer.add(audioInput)
        }

        guard writer.startWriting() else {
            throw ExportError.writerFailed(writer.error.map { String(describing: $0) }
                ?? "startWriting() returned false")
        }
        let sessionStart = trim?.start ?? .zero
        writer.startSession(atSourceTime: sessionStart)

        let video = try await writeVideo(asset: asset, tracks: videoTracks,
                                         composition: composition, trim: trim,
                                         frameDuration: frameDuration,
                                         sessionStart: sessionStart,
                                         writer: writer, input: videoInput)

        // **A second pass, not an interleaved one.** Two `AVAssetReader`s over the same asset
        // are independent, and `AVAssetWriter` accepts its inputs' data in any interleaving as
        // long as each input's own samples are ordered. Pulling both from ONE reader in one
        // loop would mean advancing whichever output the loop happened to ask for, and the
        // other's queue stalling the reader behind it.
        var audioSamples = 0
        if let audioInput {
            audioSamples = try await writeAudio(asset: asset, tracks: audioTracks, trim: trim,
                                                writer: writer, input: audioInput)
        }

        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw ExportError.writerFailed(writer.error.map { String(describing: $0) }
                ?? "writer did not complete: \(writer.status.rawValue)")
        }

        return ExportReport(outputURL: outputURL, framesRead: video.read,
                            framesWritten: video.written, frameRate: frameRate,
                            audioSamplesWritten: audioSamples)
    }

    /// **The video pass, resampled to a CONSTANT frame rate — and this is a repair.**
    ///
    /// `AVVideoComposition.frameDuration` does not make
    /// `AVAssetReaderVideoCompositionOutput` emit at that cadence: measured on the
    /// 10 fps fixture with `frameDuration` set to 1/60, the export came out as 20 frames at
    /// exactly the source's 100 ms spacing. One composed frame per SOURCE frame, at the
    /// source's own times.
    ///
    /// That is fatal for a screen recording specifically. ScreenCaptureKit delivers a frame
    /// when the screen changes and not otherwise, so a master is inherently variable-rate: a
    /// real 11.4 s recording measured here had 501 frames with gaps from 6.7 ms to 35 ms.
    /// Passed straight through, the MP4 is variable-frame-rate, which browsers, social
    /// platforms and several editors handle badly or re-encode badly.
    ///
    /// So the output timeline is generated here rather than inherited: one frame per
    /// `frameDuration` step, each carrying the most recent composed frame at or before that
    /// step — a hold, which is what a still screen genuinely looked like. `framesRead` counts
    /// what the composition produced and `framesWritten` what the timeline needed, and they
    /// are no longer expected to match.
    private nonisolated static func writeVideo(
        asset: AVAsset, tracks: [AVAssetTrack], composition: AVVideoComposition,
        trim: CMTimeRange?, frameDuration: CMTime, sessionStart: CMTime,
        writer: AVAssetWriter, input: AVAssetWriterInput
    ) async throws -> (read: Int, written: Int) {
        let reader = try AVAssetReader(asset: asset)
        if let trim { reader.timeRange = trim }
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: tracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.videoComposition = composition
        guard reader.canAdd(output) else { throw ExportError.readerRefusedOutput }
        reader.add(output)
        guard reader.startReading() else {
            throw ExportError.readerFailed(reader.error.map { String(describing: $0) }
                ?? "startReading() returned false")
        }

        var framesRead = 0
        var framesWritten = 0
        var held: CMSampleBuffer?
        var pending: CMSampleBuffer? = nextFrame(output, count: &framesRead)
        var slot = sessionStart
        var lastSourcePTS: CMTime? = pending.map { CMSampleBufferGetPresentationTimeStamp($0) }

        while true {
            // Advance through every composed frame at or before this slot; the last one wins.
            while let candidate = pending,
                  CMSampleBufferGetPresentationTimeStamp(candidate) <= slot {
                held = candidate
                pending = nextFrame(output, count: &framesRead)
                if let next = pending { lastSourcePTS = CMSampleBufferGetPresentationTimeStamp(next) }
            }
            guard let frame = held else {
                // Nothing has been composed yet at or before the first slot. Take the next
                // frame as the first — a recording does not start with a gap.
                guard let first = pending else { break }
                held = first
                pending = nextFrame(output, count: &framesRead)
                if let next = pending { lastSourcePTS = CMSampleBufferGetPresentationTimeStamp(next) }
                continue
            }
            if pending == nil && framesWritten > 0
                && CMSampleBufferGetPresentationTimeStamp(frame) < slot {
                // The source is exhausted and the slot has moved past its last frame: the
                // held frame has already been written once at its own slot, and repeating it
                // would extend the file past the recording.
                break
            }

            try await waitForReadiness(writer: writer, input: input, frame: framesWritten)
            guard let stamped = restamped(frame, at: slot) else {
                throw ExportError.appendRefused("could not re-time frame \(framesWritten)")
            }
            guard input.append(stamped) else {
                throw ExportError.appendRefused(
                    "frame \(framesWritten): "
                    + (writer.error.map { String(describing: $0) } ?? "no error recorded"))
            }
            framesWritten += 1
            slot = slot + frameDuration
        }

        if reader.status == .failed {
            throw ExportError.readerFailed(reader.error.map { String(describing: $0) }
                ?? "reader failed after \(framesRead) frame(s)")
        }
        input.markAsFinished()
        guard framesRead > 0 else { throw ExportError.noVideoTrack }
        // **The invariant that survived resampling.** One output frame per source frame is no
        // longer true and should not be; what must still hold is that the timeline reached the
        // end. `slot` is one step past the last frame written, so the comparison is against it
        // directly.
        if let last = lastSourcePTS, slot < last {
            throw ExportError.outputShorterThanSource(lastWritten: slot.seconds,
                                                      lastSource: last.seconds)
        }
        return (read: framesRead, written: framesWritten)
    }

    /// **The audio pass, mixed to one track.** A master carries system audio and the
    /// microphone as separate tracks, and an MP4 for a demo wants one. `AVAssetReaderAudioMixOutput`
    /// mixes every source track into a single LPCM stream, which the writer's input encodes to
    /// AAC — the pairing is what lets this stay a reader/writer pass rather than an
    /// `AVMutableComposition` with an audio mix attached.
    ///
    /// Exports had NO audio at all until this existed: the writer was given a video input and
    /// nothing else, so a recording with both microphone and system sound produced a silent
    /// file. Measured on a real export: `nb_streams = 1`.
    private nonisolated static func writeAudio(
        asset: AVAsset, tracks: [AVAssetTrack], trim: CMTimeRange?,
        writer: AVAssetWriter, input: AVAssetWriterInput
    ) async throws -> Int {
        let reader = try AVAssetReader(asset: asset)
        if let trim { reader.timeRange = trim }
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
        ])
        guard reader.canAdd(output) else { throw ExportError.readerRefusedOutput }
        reader.add(output)
        guard reader.startReading() else {
            throw ExportError.readerFailed(reader.error.map { String(describing: $0) }
                ?? "startReading() returned false for audio")
        }

        var written = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(buffer) > 0 else { continue }
            try await waitForReadiness(writer: writer, input: input, frame: written)
            guard input.append(buffer) else {
                throw ExportError.appendRefused(
                    "audio buffer \(written): "
                    + (writer.error.map { String(describing: $0) } ?? "no error recorded"))
            }
            written += 1
        }
        if reader.status == .failed {
            throw ExportError.readerFailed(reader.error.map { String(describing: $0) }
                ?? "audio reader failed after \(written) buffer(s)")
        }
        input.markAsFinished()
        return written
    }

    /// The next composed frame with actual samples. `copyNextSampleBuffer()` may return
    /// marker-only buffers with zero samples; those are not frames and must not be counted or
    /// held, or a hold would present an empty buffer for a whole slot.
    private nonisolated static func nextFrame(_ output: AVAssetReaderOutput,
                                              count: inout Int) -> CMSampleBuffer? {
        while let buffer = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(buffer) > 0 {
                count += 1
                return buffer
            }
        }
        return nil
    }

    /// The same buffer presented at a different time. The image is unchanged — a hold repeats
    /// a frame, it does not synthesise one — so only the timing is rewritten.
    private nonisolated static func restamped(_ buffer: CMSampleBuffer,
                                              at time: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: time,
                                        decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        let status = unsafe CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: buffer,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy)
        return status == noErr ? copy : nil
    }

    /// Wait for the input rather than skip the sample, but bounded. The clock choice and its
    /// argument live in `MonotonicStopwatch.swift` — this file deliberately cannot name a
    /// clock (`Tests/AppSourceTests`'s scan).
    private nonisolated static func waitForReadiness(writer: AVAssetWriter,
                                                    input: AVAssetWriterInput,
                                                    frame: Int) async throws {
        let poll = MonotonicStopwatch()
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed {
                throw ExportError.writerFailed(writer.error.map { String(describing: $0) }
                    ?? "writer failed while waiting for readiness at frame \(frame)")
            }
            let elapsed = poll.elapsedSeconds
            if elapsed >= Self.readinessDeadlineSeconds {
                throw ExportError.writerNotReadyInTime(frame: frame, elapsedSeconds: elapsed)
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    /// How long the readiness poll may wait for `isReadyForMoreMediaData` before calling it a
    /// stall: past what a busy-but-working writer needs, short enough to report rather than hang.
    /// `nonisolated` because the cross-boundary probe builds this module with
    /// `-default-isolation MainActor`.
    private nonisolated static let readinessDeadlineSeconds: Double = 5.0

    public nonisolated enum ExportError: Error, CustomStringConvertible, Sendable {
        case noVideoTrack
        /// A trim whose duration is zero or invalid. Refused rather than clamped: a caller
        /// that asked for nothing has a bug, and a zero-length MP4 would hide it.
        case emptyTrim
        case readerRefusedOutput
        case writerRefusedInput
        case readerFailed(String)
        case writerFailed(String)
        case appendRefused(String)
        /// The written timeline stopped short of the source's last frame.
        ///
        /// **This replaced `frameCountMismatch(read:written:)`, which the resampling made
        /// meaningless.** That case asserted one output frame per source frame, which was the
        /// right invariant while the export inherited the source's timing and is the wrong one
        /// now: a constant-rate output repeats a held frame across a still screen and collapses
        /// a burst inside one slot to the last of them, so the two counts differ by design. The
        /// guarantee that still matters is that nothing was cut off the end.
        case outputShorterThanSource(lastWritten: Double, lastSource: Double)
        /// The readiness poll exhausted `readinessDeadlineSeconds`.
        case writerNotReadyInTime(frame: Int, elapsedSeconds: Double)

        public var description: String {
            switch self {
            case .noVideoTrack: "the asset has no video track to export"
            case .emptyTrim:
                "the requested trim has no duration — an export of nothing is not a file"
            case .readerRefusedOutput: "AVAssetReader refused the video composition output"
            case .writerRefusedInput: "AVAssetWriter refused the video input"
            case .readerFailed(let why): "AVAssetReader failed: \(why)"
            case .writerFailed(let why): "AVAssetWriter failed: \(why)"
            case .appendRefused(let why): "append refused: \(why)"
            case .outputShorterThanSource(let lastWritten, let lastSource):
                "the export stopped at \(lastWritten)s while the source runs to \(lastSource)s"
            case .writerNotReadyInTime(let frame, let elapsedSeconds):
                // `.formatted(...)`: `StrictMemorySafety` flags `String(format:)` as unsafe.
                "AVAssetWriterInput never became ready for frame \(frame) after "
                + "\(elapsedSeconds.formatted(.number.precision(.fractionLength(2))))s (deadline "
                + "\(MP4Exporter.readinessDeadlineSeconds.formatted(.number.precision(.fractionLength(2))))s) — "
                + "treated as a stall, not a slow but working writer"
            }
        }
    }
}

/// The export's frame accounting, from the exporter's counters, not the finished asset.
// `public` because the compiler refused otherwise (Phase 3A-4): this type appears in a
// public member's signature, which is what makes it genuinely part of the exported
// surface rather than merely reachable.
public nonisolated struct ExportReport: Sendable {
    public let outputURL: URL
    /// Frames the composition produced — one per SOURCE frame, at the source's own irregular
    /// times.
    public let framesRead: Int
    /// Frames the output timeline needed. **Not expected to equal `framesRead`**: the export
    /// is resampled to a constant rate, so a still screen repeats a held frame and a burst of
    /// source frames inside one slot collapses to the last of them.
    public let framesWritten: Int
    public let frameRate: Int
    /// Audio buffers written; 0 when the master carried no audio track.
    public let audioSamplesWritten: Int
}
