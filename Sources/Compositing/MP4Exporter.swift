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
    public nonisolated static func export(asset: AVAsset, to outputURL: URL,
                                    outputWidth: Int, outputHeight: Int) async throws -> ExportReport {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw ExportError.noVideoTrack }

        // The same composition the preview uses.
        let composition = try await CompositionBuilder.composition(
            for: asset, outputWidth: outputWidth, outputHeight: outputHeight,
            frameDuration: CMTime(value: 1, timescale: 60))

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        readerOutput.videoComposition = composition
        guard reader.canAdd(readerOutput) else { throw ExportError.readerRefusedOutput }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(url: outputURL, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight,
        ]
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else { throw ExportError.writerRefusedInput }
        writer.add(writerInput)

        guard reader.startReading() else {
            throw ExportError.readerFailed(reader.error.map { String(describing: $0) }
                ?? "startReading() returned false")
        }
        guard writer.startWriting() else {
            throw ExportError.writerFailed(writer.error.map { String(describing: $0) }
                ?? "startWriting() returned false")
        }
        writer.startSession(atSourceTime: .zero)

        var framesRead = 0
        var framesWritten = 0
        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            framesRead += 1
            // Wait for readiness rather than skip the sample, but bounded. The clock
            // choice and its argument live in `MonotonicStopwatch.swift` — this file
            // deliberately cannot name a clock (`Tests/AppSourceTests`'s scan).
            let poll = MonotonicStopwatch()
            while !writerInput.isReadyForMoreMediaData {
                if writer.status == .failed {
                    throw ExportError.writerFailed(writer.error.map { String(describing: $0) }
                        ?? "writer failed while waiting for readiness at frame \(framesRead)")
                }
                let elapsed = poll.elapsedSeconds
                if elapsed >= Self.readinessDeadlineSeconds {
                    throw ExportError.writerNotReadyInTime(frame: framesRead, elapsedSeconds: elapsed)
                }
                try await Task.sleep(for: .milliseconds(2))
            }
            guard writerInput.append(sampleBuffer) else {
                throw ExportError.appendRefused(
                    "frame \(framesRead): "
                    + (writer.error.map { String(describing: $0) } ?? "no error recorded"))
            }
            framesWritten += 1
        }
        if reader.status == .failed {
            throw ExportError.readerFailed(reader.error.map { String(describing: $0) }
                ?? "reader failed after \(framesRead) frame(s)")
        }

        writerInput.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw ExportError.writerFailed(writer.error.map { String(describing: $0) }
                ?? "writer did not complete: \(writer.status.rawValue)")
        }

        // Assert the export dropped nothing.
        guard framesRead == framesWritten else {
            throw ExportError.frameCountMismatch(read: framesRead, written: framesWritten)
        }

        return ExportReport(outputURL: outputURL, framesRead: framesRead, framesWritten: framesWritten)
    }

    /// How long the readiness poll may wait for `isReadyForMoreMediaData` before calling it a
    /// stall: past what a busy-but-working writer needs, short enough to report rather than hang.
    /// `nonisolated` because the cross-boundary probe builds this module with
    /// `-default-isolation MainActor`.
    private nonisolated static let readinessDeadlineSeconds: Double = 5.0

    public nonisolated enum ExportError: Error, CustomStringConvertible, Sendable {
        case noVideoTrack
        case readerRefusedOutput
        case writerRefusedInput
        case readerFailed(String)
        case writerFailed(String)
        case appendRefused(String)
        case frameCountMismatch(read: Int, written: Int)
        /// The readiness poll exhausted `readinessDeadlineSeconds`.
        case writerNotReadyInTime(frame: Int, elapsedSeconds: Double)

        public var description: String {
            switch self {
            case .noVideoTrack: "the asset has no video track to export"
            case .readerRefusedOutput: "AVAssetReader refused the video composition output"
            case .writerRefusedInput: "AVAssetWriter refused the video input"
            case .readerFailed(let why): "AVAssetReader failed: \(why)"
            case .writerFailed(let why): "AVAssetWriter failed: \(why)"
            case .appendRefused(let why): "append refused: \(why)"
            case .frameCountMismatch(let read, let written):
                "export dropped a frame: read \(read), wrote \(written)"
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
    public let framesRead: Int
    public let framesWritten: Int
}
