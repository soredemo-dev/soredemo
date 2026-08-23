import AVFoundation
import Foundation
import Project
import Timeline

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
/// Where an export has got to.
///
/// **Phases, not one percentage**, and `../opensource/Screen Record Opensource/an Electron recorder-main`'s
/// export status model is why: the last step is `AVAssetWriter.finishWriting`, which takes
/// seconds on a long recording and reports nothing. A bar that reached 100% and then sat there
/// looks stopped, and a person cancels a job that was about to finish. Naming the phase is
/// what lets the UI say "finishing" instead of lying at 100%.
public enum ExportProgress: Sendable, Equatable {
    /// Reading the recording and building the composition. No useful fraction — it is one
    /// asset load, and a bar that jumped 0→30 would be describing nothing.
    case preparing
    /// Writing frames. `fraction` is 0…1 of the output timeline, which is the only part long
    /// enough for a person to watch.
    case writing(fraction: Double, framesWritten: Int)
    /// `finishWriting`. Indeterminate by nature: AVFoundation gives no progress, and inventing
    /// one would be a bar that moves without meaning.
    case finishing

    /// What a control should show, or `nil` when the phase has no honest number.
    public var fraction: Double? {
        if case .writing(let fraction, _) = self { return fraction }
        return nil
    }

    public var isFinishing: Bool { self == .finishing }
}

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
    /// Deletes a partial output. Called when an export throws or is cancelled: a half-written
    /// MP4 sitting where a person asked for their video is worse than no file, because it looks
    /// like the export worked.
    private nonisolated static func discardPartialOutput(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    public nonisolated static func export(asset: AVAsset, to outputURL: URL,
                                          outputWidth: Int, outputHeight: Int,
                                          edit: EditTimeline? = nil,
                                          assetIsAlreadyEdited: Bool = false,
                                          audioMix: AudioMix = .unchanged,
                                          frameRate: Int = 60,
                                          quality: ExportQuality = .best,
                                          onProgress: (@Sendable (ExportProgress) -> Void)? = nil
    ) async throws -> ExportReport {
        precondition(frameRate > 0, "frameRate must be positive, got \(frameRate)")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        onProgress?(.preparing)
        if let edit, edit.isEmpty { throw ExportError.emptyTrim }
        // **The compositor must be looking at the SAME edit.** It reads the observation log in
        // source time and is handed output times, so it converts through
        // `StageCompositor.editTimeline`; an export whose asset was cut one way while that
        // static said another would place every cursor and every zoom by the difference. The
        // static is process-global because AVFoundation owns compositor instances, so the
        // pairing cannot be passed as an argument — it can be checked, which is this.
        if unsafe StageCompositor.editTimeline != edit {
            throw ExportError.editTimelineMismatch
        }

        // Cutting happens here, not in the reader. `AVAssetReader.timeRange` selects ONE span,
        // which is a trim; a timeline with a cut in the middle has two or more, and an
        // `AVMutableComposition` is what turns them into a single asset whose own timeline is
        // already the edited one.
        // `if let` rather than `Optional.map`: the transform is `async throws`, which `map`
        // cannot carry.
        var asset = asset
        // **`assetIsAlreadyEdited` separates two things `edit` was doing at once.** It said
        // "cut this for me" AND "this is the edit the compositor is mapping the observation log
        // through", and a caller who had already cut the asset could only opt out of the first
        // by lying about the second. The camera is why: `EditedAsset.make` takes the FIRST video
        // track and drops the rest, so a camera laid alongside must be combined AFTER the cut —
        // which means the caller does the cut. The compositor still has to be told the same
        // edit, and the check below still holds it to that.
        if let edit, !assetIsAlreadyEdited {
            asset = try await EditedAsset.make(from: asset, by: edit)
        }

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw ExportError.noVideoTrack }

        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        // The same composition the preview uses.
        let composition = try await CompositionBuilder.composition(
            for: asset, outputWidth: outputWidth, outputHeight: outputHeight,
            frameDuration: frameDuration)

        let writer = try AVAssetWriter(url: outputURL, fileType: .mp4)
        // **Compression properties, which were not being set at all.** A codec and a size and
        // nothing else lets AVFoundation choose, and its choice is tuned for camera footage —
        // measured at 10.5 Mbps for 1080p through `AVOutputSettingsAssistant`, against the
        // 18–20 Mbps that three screen recorders independently settled on. See `ExportQuality`.
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: quality.videoSettings(outputWidth: outputWidth,
                                                  outputHeight: outputHeight,
                                                  frameRate: frameRate))
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw ExportError.writerRefusedInput }
        writer.add(videoInput)

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audioInput: AVAssetWriterInput? = audioTracks.isEmpty ? nil : {
            let input = AVAssetWriterInput(mediaType: .audio,
                                           outputSettings: quality.audioSettings())
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
        // Always zero now: the composition above already begins at the edit's first clip, so
        // there is no leading span to skip. It stays a named value because `writeVideo` slots
        // its output timeline from it.
        let sessionStart = CMTime.zero
        writer.startSession(atSourceTime: sessionStart)

        let counts: (framesRead: Int, framesWritten: Int, audioWritten: Int)
        do {
            counts = try await writeInterleaved(
            asset: asset, videoTracks: videoTracks, audioTracks: audioTracks,
            composition: composition, frameDuration: frameDuration, sessionStart: sessionStart,
            writer: writer, videoInput: videoInput, audioInput: audioInput,
                audioMix: audioMix, onProgress: onProgress)
        } catch {
            discardPartialOutput(at: outputURL)
            throw error
        }
        let video = (read: counts.framesRead, written: counts.framesWritten)
        let audioSamples = counts.audioWritten

        onProgress?(.finishing)
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

    /// **One loop feeding both inputs, and the alternative is a deadlock.**
    ///
    /// The first version wrote all the video and then all the audio, with a comment asserting
    /// that `AVAssetWriter` accepts its inputs' data in any interleaving. That assertion is
    /// false, and a real export found it: the writer stops signalling
    /// `isReadyForMoreMediaData` on an input that has run far ahead of its siblings, because
    /// it cannot lay out the file until the others catch up. A 15-second recording with audio
    /// stalled at frame 134 — 2.23 seconds at 60 fps, which is the writer's interleaving
    /// window, not a coincidence. The two-second fixture the tests used fit inside that window
    /// and passed.
    ///
    /// So both inputs are fed from one loop, whichever is behind in presentation time and
    /// ready. Preferring the one that is behind is what keeps them within the window; falling
    /// through to the other when the preferred one is momentarily not ready is what stops a
    /// wait on one input from starving the other, which would reproduce the same deadlock with
    /// extra steps.
    ///
    /// **The video is resampled to a CONSTANT frame rate — a separate repair, kept here.**
    /// `AVVideoComposition.frameDuration` does not resample: measured on the 10 fps fixture
    /// with `frameDuration` set to 1/60, the export came out as 20 frames at exactly the
    /// source's 100 ms spacing. That is fatal for screen recording, because ScreenCaptureKit
    /// emits a frame when the screen changes and not otherwise — a real 11.4 s recording
    /// measured 501 frames with gaps from 6.7 ms to 35 ms.
    private nonisolated static func writeInterleaved(
        asset: AVAsset, videoTracks: [AVAssetTrack], audioTracks: [AVAssetTrack],
        composition: AVVideoComposition, frameDuration: CMTime, sessionStart: CMTime,
        writer: AVAssetWriter, videoInput: AVAssetWriterInput, audioInput: AVAssetWriterInput?,
        audioMix: AudioMix, onProgress: (@Sendable (ExportProgress) -> Void)?
    ) async throws -> (framesRead: Int, framesWritten: Int, audioWritten: Int) {
        // The output's own length, for the fraction. Read once: it cannot change while the
        // export runs, and asking per frame would be an asset load per frame.
        let totalNanos = (try? await asset.load(.duration).seconds).map { $0 * 1_000_000_000 } ?? 0
        let videoReader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        videoOutput.videoComposition = composition
        guard videoReader.canAdd(videoOutput) else { throw ExportError.readerRefusedOutput }
        videoReader.add(videoOutput)
        guard videoReader.startReading() else {
            throw ExportError.readerFailed(videoReader.error.map { String(describing: $0) }
                ?? "startReading() returned false")
        }

        // **A second reader, not a second output on the first.** Two outputs on one reader are
        // pulled by the same loop, so whichever the loop asks for advances and the other's
        // queue backs up behind it — the reader itself then stalls. Separate readers advance
        // independently, which is what lets the loop below choose freely between them.
        var audioReader: AVAssetReader?
        var audioOutput: AVAssetReaderAudioMixOutput?
        if audioInput != nil, !audioTracks.isEmpty {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
            ])
            // **The mix is applied at the READ.** `AVAssetReaderAudioMixOutput` already sums
            // the source tracks; an `AVAudioMix` sets each one's level going in, so a muted
            // microphone contributes nothing rather than being summed and then multiplied by
            // zero — and a boosted one is boosted before the sum rather than after, which is
            // the difference between raising a voice and raising the mix it is buried in.
            if audioMix.changesAnything {
                output.audioMix = Self.mix(audioMix, over: audioTracks)
            }
            guard reader.canAdd(output) else { throw ExportError.readerRefusedOutput }
            reader.add(output)
            guard reader.startReading() else {
                throw ExportError.readerFailed(reader.error.map { String(describing: $0) }
                    ?? "startReading() returned false for audio")
            }
            audioReader = reader
            audioOutput = output
        }

        var resampler = ConstantRateResampler(output: videoOutput, frameDuration: frameDuration,
                                              slot: sessionStart)
        var pendingVideo: CMSampleBuffer? = resampler.next()
        var pendingAudio: CMSampleBuffer? = audioOutput.flatMap(nextAudio)
        var audioWritten = 0
        var stallPoll: MonotonicStopwatch?
        var lastReportedPercent = -1

        /// **Reported on each whole percent, not on each frame.** A 60 fps export of a
        /// three-minute recording is 10,800 frames; a callback per frame is 10,800 hops to the
        /// main actor to move a bar by a tenth of a pixel, and the reporting would cost more
        /// than the work it reports on.
        func report(_ slot: CMTime, _ framesWritten: Int) {
            guard let onProgress, totalNanos > 0 else { return }
            let fraction = min(max(slot.seconds * 1_000_000_000 / totalNanos, 0), 1)
            let percent = Int(fraction * 100)
            guard percent != lastReportedPercent else { return }
            lastReportedPercent = percent
            onProgress(.writing(fraction: fraction, framesWritten: framesWritten))
        }

        // **Each input is finished the moment ITS source runs out, not when the loop ends.**
        // The two rarely end together — AAC packet granularity leaves the audio short of the
        // video's last frame — and a writer still expecting data from a finished input keeps
        // holding the other back. The first interleaved version marked both finished after the
        // loop and stalled at frame 578 of 600: the audio had been spent for half a second and
        // the writer had no way to know.
        var videoFinished = false
        var audioFinished = audioInput == nil
        func finishExhaustedInputs() {
            if pendingVideo == nil && !videoFinished {
                videoInput.markAsFinished()
                videoFinished = true
            }
            if pendingAudio == nil && !audioFinished {
                audioInput?.markAsFinished()
                audioFinished = true
            }
        }
        finishExhaustedInputs()

        while pendingVideo != nil || pendingAudio != nil {
            // **Cancellation is checked here, at the top of the loop.** Swift's cooperative
            // cancellation is the whole mechanism: a caller cancels its Task and the next
            // iteration throws. No flag, no second path — and the writer's partial file is
            // deleted below, because a half-written MP4 that a person can double-click is
            // worse than none.
            try Task.checkCancellation()
            // Whichever is further behind goes first; that is what keeps the two inputs inside
            // the writer's interleaving window.
            let videoFirst: Bool
            switch (pendingVideo, pendingAudio) {
            case (.some(let v), .some(let a)):
                videoFirst = CMSampleBufferGetPresentationTimeStamp(v)
                    <= CMSampleBufferGetPresentationTimeStamp(a)
            case (.some, nil): videoFirst = true
            default: videoFirst = false
            }

            if videoFirst, let frame = pendingVideo, videoInput.isReadyForMoreMediaData {
                guard videoInput.append(frame) else {
                    throw ExportError.appendRefused(
                        "frame \(resampler.framesWritten): "
                        + (writer.error.map { String(describing: $0) } ?? "no error recorded"))
                }
                resampler.framesWritten += 1
                pendingVideo = resampler.next()
                finishExhaustedInputs()
                stallPoll = nil
                report(resampler.slot, resampler.framesWritten)
            } else if let buffer = pendingAudio, let audioInput,
                      audioInput.isReadyForMoreMediaData {
                guard audioInput.append(buffer) else {
                    throw ExportError.appendRefused(
                        "audio buffer \(audioWritten): "
                        + (writer.error.map { String(describing: $0) } ?? "no error recorded"))
                }
                audioWritten += 1
                pendingAudio = audioOutput.flatMap(nextAudio)
                finishExhaustedInputs()
                stallPoll = nil
            } else if let frame = pendingVideo, videoInput.isReadyForMoreMediaData {
                // The preferred input was audio and it is not ready. Feeding video rather than
                // waiting is the difference between an interleaved writer and the deadlock
                // this loop replaced.
                guard videoInput.append(frame) else {
                    throw ExportError.appendRefused(
                        "frame \(resampler.framesWritten): "
                        + (writer.error.map { String(describing: $0) } ?? "no error recorded"))
                }
                resampler.framesWritten += 1
                pendingVideo = resampler.next()
                finishExhaustedInputs()
                stallPoll = nil
                report(resampler.slot, resampler.framesWritten)
            } else {
                // Neither input can take anything. Bounded, because a writer that never
                // becomes ready has failed and should say so rather than hang.
                if writer.status == .failed {
                    throw ExportError.writerFailed(writer.error.map { String(describing: $0) }
                        ?? "writer failed while waiting for readiness")
                }
                let poll = stallPoll ?? MonotonicStopwatch()
                stallPoll = poll
                let elapsed = poll.elapsedSeconds
                if elapsed >= Self.readinessDeadlineSeconds {
                    throw ExportError.writerNotReadyInTime(frame: resampler.framesWritten,
                                                           elapsedSeconds: elapsed)
                }
                try await Task.sleep(for: .milliseconds(2))
            }
        }

        if videoReader.status == .failed {
            throw ExportError.readerFailed(videoReader.error.map { String(describing: $0) }
                ?? "reader failed after \(resampler.framesRead) frame(s)")
        }
        if let audioReader, audioReader.status == .failed {
            throw ExportError.readerFailed(audioReader.error.map { String(describing: $0) }
                ?? "audio reader failed after \(audioWritten) buffer(s)")
        }
        // Both were finished inside the loop as their sources ran out; these are the
        // no-op safety net for a loop that exited without either ever being pending.
        finishExhaustedInputs()

        guard resampler.framesRead > 0 else { throw ExportError.noVideoTrack }
        // **The invariant that survived resampling.** One output frame per source frame is no
        // longer true and should not be; what must still hold is that the timeline reached the
        // end. `slot` is one step past the last frame written.
        if let last = resampler.lastSourcePTS, resampler.slot < last {
            throw ExportError.outputShorterThanSource(lastWritten: resampler.slot.seconds,
                                                      lastSource: last.seconds)
        }
        return (resampler.framesRead, resampler.framesWritten, audioWritten)
    }

    /// An `AVAudioMix` setting each source's level.
    ///
    /// **The mapping from a name to a track is positional**, and it is the master's own order:
    /// `LegacyMasterWriter` adds video, then system audio, then the microphone, so the audio
    /// tracks arrive in that order. `theMasterAddsItsTracksInAKnownOrder` is what stops that
    /// from changing silently — without it this would be a silent mis-assignment, muting the
    /// wrong source in a file nobody re-checks.
    ///
    /// A track beyond the two we write is left at unity rather than guessed at: an asset with
    /// three audio tracks did not come from this recorder, and silencing something because it
    /// was not expected is worse than passing it through.
    nonisolated static func mix(_ settings: AudioMix,
                                over tracks: [AVAssetTrack]) -> AVAudioMix {
        AudioMixBuilder.mix(settings, over: tracks)
    }

    /// The next audio buffer with actual samples. Marker-only buffers carry no audio and would
    /// be appended as silence of no duration.
    private nonisolated static func nextAudio(_ output: AVAssetReaderOutput) -> CMSampleBuffer? {
        while let buffer = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(buffer) > 0 { return buffer }
        }
        return nil
    }

    /// Generates the output's frame timeline instead of inheriting the source's.
    ///
    /// One frame per `frameDuration` step, each carrying the most recent composed frame at or
    /// before that step — a hold, which is what a still screen genuinely looked like. A hold
    /// repeats an image; it does not blend toward the next, which would invent motion the
    /// recording never had.
    /// Shared with `GIFExporter`, which needs the same output timeline over the same reader —
    /// internal rather than private for that one caller.
    struct ConstantRateResampler {
        let output: AVAssetReaderOutput
        let frameDuration: CMTime
        var slot: CMTime
        var framesRead = 0
        var framesWritten = 0
        var lastSourcePTS: CMTime?
        /// **How many frames `next()` has handed out**, which is what decides when the source is
        /// spent — see the guard below.
        ///
        /// Separate from `framesWritten`, which the MP4 path increments itself after a
        /// successful append and reports. Termination used to read THAT, so a caller that
        /// consumed frames without maintaining it looped forever repeating the last frame. The
        /// GIF exporter is that caller, and it found this the moment the type gained a second
        /// user: a counter a caller has to remember to bump is not a counter, it is a trap.
        private var emitted = 0
        private var held: CMSampleBuffer?
        private var pending: CMSampleBuffer?
        private var started = false

        init(output: AVAssetReaderOutput, frameDuration: CMTime, slot: CMTime) {
            self.output = output
            self.frameDuration = frameDuration
            self.slot = slot
        }

        /// The frame for the current slot, re-timed to it, or `nil` when the source is spent.
        mutating func next() -> CMSampleBuffer? {
            if !started {
                started = true
                pending = MP4Exporter.nextFrame(output, count: &framesRead)
                lastSourcePTS = pending.map { CMSampleBufferGetPresentationTimeStamp($0) }
            } else {
                slot = slot + frameDuration
            }

            while true {
                while let candidate = pending,
                      CMSampleBufferGetPresentationTimeStamp(candidate) <= slot {
                    held = candidate
                    pending = MP4Exporter.nextFrame(output, count: &framesRead)
                    if let next = pending {
                        lastSourcePTS = CMSampleBufferGetPresentationTimeStamp(next)
                    }
                }
                guard let frame = held else {
                    // Nothing composed yet at or before the first slot. Take the next frame as
                    // the first — a recording does not begin with a gap.
                    guard let first = pending else { return nil }
                    held = first
                    pending = MP4Exporter.nextFrame(output, count: &framesRead)
                    if let next = pending {
                        lastSourcePTS = CMSampleBufferGetPresentationTimeStamp(next)
                    }
                    continue
                }
                if pending == nil && emitted > 0
                    && CMSampleBufferGetPresentationTimeStamp(frame) < slot {
                    // The source is spent and the slot has passed its last frame: repeating it
                    // would extend the file past the recording.
                    return nil
                }
                emitted += 1
                return MP4Exporter.restamped(frame, at: slot)
            }
        }
    }

    /// The next composed frame with actual samples. `copyNextSampleBuffer()` may return
    /// marker-only buffers with zero samples; those are not frames and must not be counted or
    /// held, or a hold would present an empty buffer for a whole slot.
    nonisolated static func nextFrame(_ output: AVAssetReaderOutput,
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
    nonisolated static func restamped(_ buffer: CMSampleBuffer,
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
        /// An edit that keeps nothing. Refused rather than clamped: a caller that asked for
        /// nothing has a bug, and a zero-length MP4 would hide it.
        case emptyTrim
        /// The compositor's `editTimeline` is not the edit being exported. See the check's own
        /// comment: the two cannot be passed together, so they are compared instead.
        case editTimelineMismatch
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
                "the requested edit keeps nothing — an export of nothing is not a file"
            case .editTimelineMismatch:
                "StageCompositor.editTimeline does not match the edit being exported; every "
                + "cursor and zoom would be placed by the difference between them"
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
