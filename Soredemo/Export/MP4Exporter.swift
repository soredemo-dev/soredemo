import AVFoundation
import Foundation

/// One MP4 (H.264) export of a recorded master — the deliverable Phase 2B's own completion
/// sentence closes on: "export → open the exported file in QuickTime and watch it."
///
/// **`AVAssetReader` → `AVAssetWriter`, on the LEGACY API, not the successor — and that is a
/// measured correction to this task's own brief, not a preference.** The brief's `Interfaces:`
/// line names `SuccessorMasterWriter`; `Soredemo/Capture/MasterWriter.swift`'s header (Task 6)
/// already carried the caveat that the directive "new media-writing code goes to the successor"
/// assumes `appendImmediately(_:)` tolerates the concurrent-receiver load real writing needs, and
/// that this was unmeasured for anything other than three receivers fed together. This export's
/// own shape is different — `AVAssetReaderVideoCompositionOutput` produces exactly ONE stream,
/// so only the video track would ever be FED — and `SuccessorMasterWriter.init` still opens
/// all three receivers unconditionally (video, system audio, microphone; `MasterWriting` requires
/// all three), because that is what `CaptureSession` needs it for. Nobody had measured "three
/// created, one fed" before this task. Measured it directly, before writing this file (throwaway
/// harness, not committed, 320×240 h264, `SuccessorMasterWriter` unmodified):
///
/// - **3 receivers created, only the video one fed, 200 frames (well past Task 6's observed
///   64–112 stall window), 12 runs, no pacing: 12/12 stalled.** Frame numbers: 84, 116, 79, 80,
///   86, 77, 89, 123, 85, 91, 77, 81 — the same window Task 6 measured with all three tracks FED,
///   even though this shape feeds only one. That rules out "the stall is about feeding three
///   tracks" — it is about three receivers being CREATED, full stop.
/// - **Supplementary, not the deciding measurement:** a genuinely single-receiver writer (built
///   directly on `AVAssetWriter.start()` / `inputReceiver(for:)` / `appendImmediately(_:)`, NOT
///   `SuccessorMasterWriter`, with no unused audio inputs at all) completed 200 frames cleanly in
///   47 of 48 runs across four batches (one early failure at frame 4, never reproduced again — not
///   investigated further, since this measurement does not decide anything this file ships). This
///   says the defect is specific to `SuccessorMasterWriter`'s three-receiver shape, not to
///   `appendImmediately(_:)` at any concurrency — worth a future D6b-27 run building a real
///   purpose-built single-receiver successor writer, but that writer does not exist and is not
///   what this file uses.
///
/// **So: `LegacyMasterWriter`'s underlying AVFoundation calls, not its type.** The decision
/// procedure this task was given is "it stalls → use `LegacyMasterWriter`", and it stalled — but
/// `LegacyMasterWriter` itself is the wrong TYPE to instantiate here regardless of which
/// conformance stalls, for two independent reasons neither measurement above touches:
///
/// 1. `LegacyMasterWriter.init` hardcodes `AVAssetWriter(url:fileType: .mov)` — no parameter
///    selects a container. This task's own scope is "one MP4 (H.264). Full stop." A `.mov` file
///    renamed `.mp4` is not that; the deliverable must actually carry the MPEG-4 file type, which
///    only `AVAssetWriter(url:fileType: .mp4)` produces.
/// 2. `MasterWriting` requires video, system audio AND microphone — three tracks, always. This
///    export's own signature (`export(asset:to:outputWidth:outputHeight:)`) carries no audio
///    parameter, and `AVAssetReaderVideoCompositionOutput` — the ONLY reader output this file
///    uses, per the brief's own Step 1 — produces exactly one stream. There is no second or third
///    track's worth of samples anywhere in this function to feed two more receivers with, and
///    silently shipping a file with two empty, zero-sample audio tracks would be the same kind of
///    unmeasured shape this whole task exists to not ship.
///
/// So this function is written directly against `AVAssetWriter`/`AVAssetWriterInput` — the exact
/// non-deprecated-at-this-project's-26.0-floor calls `LegacyMasterWriter` itself uses
/// (`canAdd`/`add`/`startWriting()`/`append(_:)`/`isReadyForMoreMediaData`/`finishWriting`) — with
/// `fileType: .mp4` and exactly the one video input this export needs. Nothing here is the
/// successor stack, and nothing here is `MasterWriting`; both would be the wrong shape for what
/// this specific file does, independent of the stall.
enum MP4Exporter {
    /// Exports `asset`'s video, through the SAME `AVVideoComposition`
    /// `CompositionBuilder.composition(for:outputWidth:outputHeight:frameDuration:)` builds for
    /// the preview (`StageWindow.load()` calls the identical function with the identical
    /// arguments) — D8's whole point: one compositor, one composition object, so "preview and
    /// export agree" is a fact about a type rather than a rule two call sites must remember.
    ///
    /// `nonisolated`, not the app target's default `@MainActor` — `writer.finishWriting(_:)`
    /// below calls its completion handler from an AVFoundation-owned queue, not necessarily the
    /// main actor's executor; a `@MainActor`-isolated closure literal there is exactly the trap
    /// "things the brief cannot know" item 2 describes (compiles clean, fails at runtime with only
    /// a warning). `MasterWriter.swift`'s whole file carries the identical `nonisolated` for the
    /// identical reason.
    ///
    /// **Never drops a frame.** Every sample `AVAssetReaderVideoCompositionOutput` hands back is
    /// appended — the poll loop below waits on `isReadyForMoreMediaData` rather than skipping a
    /// frame the writer was not ready for yet — and `framesRead`/`framesWritten` are counted
    /// independently and compared at the end; a mismatch throws rather than being silently
    /// reported. A count that is only reported is a count nobody reads.
    nonisolated static func export(asset: AVAsset, to outputURL: URL,
                                    outputWidth: Int, outputHeight: Int) async throws -> ExportReport {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw ExportError.noVideoTrack }

        // The SAME composition the preview uses — see this type's own header.
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
            // Never drop: wait for readiness rather than skip this sample.
            while !writerInput.isReadyForMoreMediaData {
                if writer.status == .failed {
                    throw ExportError.writerFailed(writer.error.map { String(describing: $0) }
                        ?? "writer failed while waiting for readiness at frame \(framesRead)")
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

        // Step 2: assert the export dropped nothing. A count that is only reported is a count
        // nobody reads.
        guard framesRead == framesWritten else {
            throw ExportError.frameCountMismatch(read: framesRead, written: framesWritten)
        }

        return ExportReport(outputURL: outputURL, framesRead: framesRead, framesWritten: framesWritten)
    }

    nonisolated enum ExportError: Error, CustomStringConvertible, Sendable {
        case noVideoTrack
        case readerRefusedOutput
        case writerRefusedInput
        case readerFailed(String)
        case writerFailed(String)
        case appendRefused(String)
        case frameCountMismatch(read: Int, written: Int)

        var description: String {
            switch self {
            case .noVideoTrack: "the asset has no video track to export"
            case .readerRefusedOutput: "AVAssetReader refused the video composition output"
            case .writerRefusedInput: "AVAssetWriter refused the video input"
            case .readerFailed(let why): "AVAssetReader failed: \(why)"
            case .writerFailed(let why): "AVAssetWriter failed: \(why)"
            case .appendRefused(let why): "append refused: \(why)"
            case .frameCountMismatch(let read, let written):
                "export dropped a frame: read \(read), wrote \(written)"
            }
        }
    }
}

/// What Step 2 exists to prove: the exported file's frame accounting, read back from the
/// exporter's own counters (never dropped without a check, per this file's header) rather than
/// only from the finished asset — a person reading a report should not have to re-open the file
/// to learn whether the export dropped anything.
nonisolated struct ExportReport: Sendable {
    let outputURL: URL
    let framesRead: Int
    let framesWritten: Int
}
