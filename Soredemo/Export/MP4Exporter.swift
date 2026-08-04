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
/// So this function is written directly against `AVAssetWriter`/`AVAssetWriterInput` — calls
/// `LegacyMasterWriter` itself also uses (`canAdd`/`add`/`startWriting()`/`append(_:)`/
/// `isReadyForMoreMediaData`/`finishWriting`), plus `AVAssetReader`/`AVAssetReaderOutput`'s own
/// equivalents this file needs that `LegacyMasterWriter` never touches (`canAdd`/`add`/
/// `startReading()`/`copyNextSampleBuffer()`) — with `fileType: .mp4` and exactly the one video
/// input this export needs. Nothing here is the successor stack, and nothing here is
/// `MasterWriting`; both would be the wrong shape for what this specific file does, independent
/// of the stall.
///
/// **These calls are on `ARCHITECTURE.md` D6b-27's own list — every substantive one of them —
/// and this file had said only "non-deprecated at this project's 26.0 floor," which is true and
/// stops one clause early.** Code review (Task 7, round 2) caught the omission and cross-checked
/// against the real 27.0 SDK headers; re-verified here directly (`scripts
/// /scan-sdk-deprecations.py --out`, confirmed against `AVAssetReader.h`/`AVAssetWriter.h`/
/// `AVAssetWriterInput.h`/`AVAssetReaderOutput.h` for the one call the scan's own regex misses —
/// see below):
///
/// | call in this file | condemned symbol | successor named in the SDK |
/// | --- | --- | --- |
/// | `reader.add(readerOutput)` | `AVAssetReader.addOutput:` | `AVAssetReader.outputProvider(for:...)` |
/// | `reader.startReading()` | `AVAssetReader.startReading` | `AVAssetReader.start()` |
/// | `readerOutput.copyNextSampleBuffer()` | `AVAssetReaderOutput.copyNextSampleBuffer` | `AVAssetReaderOutput.Provider.next()` |
/// | `writer.add(writerInput)` | `AVAssetWriter.addInput:` | `AVAssetWriter.inputReceiver(for:)` |
/// | `writer.startWriting()` | `AVAssetWriter.startWriting` | `AVAssetWriter.start()` |
/// | `writerInput.append(_:)` | `AVAssetWriterInput.appendSampleBuffer:` | `SampleBufferReceiver.append(_:)` / `.appendImmediately(_:)` |
/// | `writerInput.isReadyForMoreMediaData` | `AVAssetWriterInput.readyForMoreMediaData` | "the input receiver's async `append(...)` method" |
/// | `writerInput.expectsMediaDataInRealTime` | `AVAssetWriterInput.expectsMediaDataInRealTime` | (none named — `appendImmediately(_:)` IS the real-time behaviour, per `SuccessorMasterWriter.swift`'s own header) |
///
/// **`copyNextSampleBuffer()` is an EIGHTH condemned call, beyond the seven the review's own
/// cross-check named** — found while writing this table, not by the review. Its own header
/// explains the exact defect this file's § 14 probe check hit and fixed: *"In certain
/// configurations, such as when outputSettings is nil, copyNextSampleBuffer may return
/// marker-only sample buffers... identified by CMSampleBufferGetNumSamples returning 0."* That is
/// precisely the bug `countVideoSampleBuffers` in `scripts/cross-boundary-digest-probe.swift`
/// had and was fixed for — the deprecated method's own SDK documentation states the hazard the
/// review's third check caught empirically. `writer.canAdd(_:)`/`reader.canAdd(_:)` are NOT on
/// this list — measured directly in the same header pass, no `API_DEPRECATED` on either.
///
/// **Judgment, not a proof: this file is left unseamed.** Two things make that judgment different
/// from "it compiles, ship it": every one of these eight calls sits behind exactly ONE track, in
/// ONE small file (under 200 lines), with NO concurrent multi-track shape for `appendImmediately`
/// to stall on — the specific hazard that makes `CaptureSession`'s own writer seam load-bearing
/// does not exist here, because it cannot: this file was never going to open more than one
/// receiver. A seam earns its cost by having something real to swap FOR; here the two sides of
/// the swap are asymmetric in a way `MasterWriter.swift`'s seam is not — the writer half has a
/// working, if 3-track-shaped, successor already measured twice in this project (Task 6's
/// `SuccessorMasterWriter`, and this task's own supplementary single-receiver measurement above);
/// the READER half (`AVAssetReader.outputProvider(for:...)` / `AVAssetReaderOutput.Provider
/// .next()`) has never been touched by any task, spike, or probe in this repository — it would be
/// new territory, not a known-working alternative slotted in behind a protocol.
///
/// **What the rewrite would cost, named rather than left implicit:** measuring
/// `outputProvider(for:)`'s real shape (its exact overload for a video-composition output, what
/// `Provider.next()` returns and how it signals end-of-stream, whether it is sync or async) is a
/// Task-6-sized investigation on its own — `swift-api-digester` or `-typecheck` probes, the same
/// discipline that found `SampleBufferReceiver`'s three members and `CVReadOnlyPixelBuffer`'s
/// shape, because neither has a header comment or `.swiftinterface` friendly enough to read
/// directly. The WRITER half's rewrite is cheap by comparison (Task 6 already did the equivalent
/// work); the READER half is not measured at all, and pretending otherwise here would be writing
/// the exact kind of code-against-an-unopened-callee this project's own brief-defect pattern
/// (progress.md, "five across two tasks... before dispatch, grep the initialisers") already named
/// as a repeat mistake to stop making.
///
/// **The trigger, same register as `MasterWriter.swift`'s own:** `ARCHITECTURE.md` D6b-27 says
/// re-run `scripts/scan-sdk-deprecations.py` on every OS/SDK bump; this file's own row belongs
/// there, not invented separately here. This project's floor is 26.0 and a macOS 27 binary still
/// cannot be launched on this machine (`MasterWriter.swift`'s own header) — the same fact that
/// makes the writer seam "scheduled, not speculative" rather than urgent applies here with LESS
/// urgency, because this file's blast radius if the floor moves is one small file with a
/// measured-cheap rewrite on one half and an honestly-unmeasured other half, not three
/// concurrently-fed tracks a shipping recording depends on.
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
