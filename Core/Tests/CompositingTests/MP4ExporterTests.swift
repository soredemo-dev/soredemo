import Testing
import Foundation
import AVFoundation
import CoreMedia
import Project
import Timeline
@testable import Compositing

/// Extends the `StageCompositorTests` serialized suite rather than declaring its own: a real
/// export drives the same process-global `StageCompositor` statics, and Swift Testing does not
/// serialise sibling top-level suites against each other.
extension StageCompositorTests {
    /// 30s wall-clock ceiling on the whole export, so a regression in `MP4Exporter`'s own 5s
    /// per-frame `readinessDeadlineSeconds` cannot hang `swift test` with no output. Generous:
    /// the 20-frame fixture really exports in well under a second.
    private static let testTimeoutSeconds: Double = 30

    private enum TestTimeoutError: Error, CustomStringConvertible {
        case exceededWallClockLimit(seconds: Double)
        var description: String {
            switch self {
            case .exceededWallClockLimit(let seconds):
                "MP4Exporter.export did not finish within this test's own \(seconds)s wall-clock "
                + "limit — evidence of a regression in the production readiness cap, not an "
                + "assertion about export correctness"
            }
        }
    }

    /// A real export of `Tests/RenderParityFixtures/two-tone.mov` through the real
    /// `CompositionBuilder`/`StageCompositor`/`CoreImageFrameRenderer` stack, not a synthesised
    /// asset. Output lands in the temporary directory and is removed in a `defer`.
    @Test func exportingTheFixtureNeverDropsAFrameAndFinishesWithinTheTestsOwnTimeout() async throws {
        unsafe StageCompositor.renderer = try CoreImageFrameRenderer()
        unsafe StageCompositor.style = .default
        unsafe StageCompositor.observationLogURL = nil
        unsafe StageCompositor.overrides = []
        unsafe StageCompositor.editTimeline = nil

        let asset = AVURLAsset(url: repositoryRootFromTests
            .appending(path: "Tests/RenderParityFixtures/two-tone.mov"))
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp4exporter-test-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let report = try await withThrowingTaskGroup(of: ExportReport.self) { group in
            group.addTask {
                try await MP4Exporter.export(
                    asset: asset, to: outputURL, outputWidth: 160, outputHeight: 90)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(Self.testTimeoutSeconds))
                throw TestTimeoutError.exceededWallClockLimit(seconds: Self.testTimeoutSeconds)
            }
            guard let first = try await group.next() else {
                throw TestTimeoutError.exceededWallClockLimit(seconds: Self.testTimeoutSeconds)
            }
            group.cancelAll()
            return first
        }

        // **Not `framesRead == framesWritten` any more, and the change is the point.** That
        // was the right invariant while the export inherited the source's frame times; the
        // export is now resampled to a constant rate, so a still screen repeats a held frame
        // and a burst inside one slot collapses to the last of them. What must still hold is
        // that the timeline reached the end, which `.outputShorterThanSource` throws on.
        #expect(report.framesWritten >= report.framesRead,
                "a 60 fps resample of a 10 fps source cannot need fewer frames than it read")
        #expect(report.frameRate == 60)

        // `resourceValues(forKeys:)`, not `fileExists(atPath:isDirectory:)`: the latter's
        // out-parameter is an `UnsafeMutablePointer`, which `StrictMemorySafety` warns on.
        let resourceValues = try outputURL.resourceValues(forKeys: [.isDirectoryKey])
        #expect(FileManager.default.fileExists(atPath: outputURL.path)
                && resourceValues.isDirectory == false, "the exported file exists on disk")

        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let size = attributes[.size] as? Int ?? 0
        #expect(size > 0, "the exported file is non-empty")
    }

    // MARK: - constant frame rate, and audio

    /// **`AVVideoComposition.frameDuration` does not resample, and this is the measurement
    /// that showed it.** With `frameDuration` set to 1/60 over this 10 fps fixture, the export
    /// came out as 20 frames at exactly the source's 100 ms spacing — one composed frame per
    /// SOURCE frame, at the source's own times.
    ///
    /// That is fatal for a screen recording specifically: ScreenCaptureKit emits a frame when
    /// the screen changes and not otherwise, so a real 11.4 s recording measured 501 frames
    /// with gaps from 6.7 ms to 35 ms. The export now generates the output timeline instead of
    /// inheriting it.
    @Test func theExportIsConstantFrameRateWhateverTheSourceCadenceIs() async throws {
        unsafe StageCompositor.renderer = try CoreImageFrameRenderer()
        unsafe StageCompositor.style = .default
        unsafe StageCompositor.observationLogURL = nil
        unsafe StageCompositor.overrides = []
        unsafe StageCompositor.editTimeline = nil

        let asset = AVURLAsset(url: repositoryRootFromTests
            .appending(path: "Tests/RenderParityFixtures/two-tone.mov"))
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfr-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let report = try await MP4Exporter.export(asset: asset, to: outputURL,
                                                  outputWidth: 320, outputHeight: 180)
        // The fixture is 20 frames at 10 fps. Resampled to 60 fps it must be about six times
        // as many, which is also the assertion that the resampling happened at all.
        #expect(report.framesRead == 20, "the composition produced \(report.framesRead) frames")
        #expect(report.framesWritten > 100,
                "60 fps over a 2 s source should need ~115 frames, wrote \(report.framesWritten)")

        // The PTS spacing is the actual claim; the count alone would pass if frames were
        // written at the wrong times.
        let exported = AVURLAsset(url: outputURL)
        let track = try #require(try await exported.loadTracks(withMediaType: .video).first)
        let rate = try await track.load(.nominalFrameRate)
        #expect(abs(Double(rate) - 60) < 1.0,
                "the exported track reports \(rate) fps, not the constant 60 asked for")
    }

    /// A held frame repeats an image, it does not synthesise one. A resampler that produced a
    /// blended or blank frame between two source frames would invent motion the recording
    /// never had — the same fault `PointerTrack` refuses on the pointer track.
    @Test func aHeldFrameRepeatsTheSourceImageRatherThanInventingOne() async throws {
        unsafe StageCompositor.renderer = try CoreImageFrameRenderer()
        unsafe StageCompositor.style = .default
        unsafe StageCompositor.observationLogURL = nil
        unsafe StageCompositor.overrides = []
        unsafe StageCompositor.editTimeline = nil

        let asset = AVURLAsset(url: repositoryRootFromTests
            .appending(path: "Tests/RenderParityFixtures/two-tone.mov"))
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("held-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        _ = try await MP4Exporter.export(asset: asset, to: outputURL,
                                         outputWidth: 320, outputHeight: 180)

        // Two output times inside ONE source frame's 100 ms span must show the same image.
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: outputURL))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let first = try await generator.image(at: CMTime(seconds: 0.52, preferredTimescale: 600)).image
        let second = try await generator.image(at: CMTime(seconds: 0.57, preferredTimescale: 600)).image
        #expect(first.width == second.width && first.height == second.height)
        #expect(first.width > 0, "the generator produced no image to compare")
    }

    /// **Exports had no audio at all.** The writer was given a video input and nothing else, so
    /// a recording carrying both system sound and a microphone produced a silent file —
    /// measured on a real export as `nb_streams = 1`. The fixture has TWO audio tracks, like a
    /// master does, and they must arrive as one.
    @Test func aRecordingWithAudioExportsWithOneMixedAudioTrack() async throws {
        unsafe StageCompositor.renderer = try CoreImageFrameRenderer()
        unsafe StageCompositor.style = .default
        unsafe StageCompositor.observationLogURL = nil
        unsafe StageCompositor.overrides = []
        unsafe StageCompositor.editTimeline = nil

        let source = AVURLAsset(url: repositoryRootFromTests
            .appending(path: "Tests/RenderParityFixtures/two-track-audio.mov"))
        #expect(try await source.loadTracks(withMediaType: .audio).count == 2,
                "the fixture must carry two audio tracks or this proves nothing about mixing")

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let report = try await MP4Exporter.export(asset: source, to: outputURL,
                                                  outputWidth: 320, outputHeight: 180)

        #expect(report.audioSamplesWritten > 0, "no audio buffers were written")
        let exported = AVURLAsset(url: outputURL)
        let audio = try await exported.loadTracks(withMediaType: .audio)
        #expect(audio.count == 1, "expected one mixed track, got \(audio.count)")
        let duration = try await exported.load(.duration)
        #expect(duration.seconds > 1.5, "the exported file is \(duration.seconds)s")
    }

    /// **The deadlock a two-second fixture cannot find.**
    ///
    /// `AVAssetWriter` stops signalling `isReadyForMoreMediaData` on an input that has run far
    /// ahead of its siblings — it cannot lay out the file until they catch up. An export that
    /// wrote all the video and then all the audio therefore stalled at frame 134, which is
    /// 2.23 seconds at 60 fps: the writer's interleaving window, not a coincidence.
    /// `aRecordingWithAudioExportsWithOneMixedAudioTrack` uses a 2 s fixture, fits entirely
    /// inside that window, and passed the whole time the bug existed.
    ///
    /// So this fixture is TEN seconds. It is the only reason a 150 KB binary is in the repo:
    /// the bug is a function of duration, and no shorter asset can express it.
    @Test func aLongRecordingWithAudioDoesNotStallTheWriter() async throws {
        unsafe StageCompositor.renderer = try CoreImageFrameRenderer()
        unsafe StageCompositor.style = .default
        unsafe StageCompositor.observationLogURL = nil
        unsafe StageCompositor.overrides = []
        unsafe StageCompositor.editTimeline = nil

        let source = AVURLAsset(url: repositoryRootFromTests
            .appending(path: "Tests/RenderParityFixtures/long-two-track-audio.mov"))
        let duration = try await source.load(.duration)
        #expect(duration.seconds > 5, """
                this fixture must be longer than the writer's ~2.2 s interleaving window or it \
                proves nothing — it ran \(duration.seconds)s
                """)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("long-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let report = try await MP4Exporter.export(asset: source, to: outputURL,
                                                  outputWidth: 160, outputHeight: 90)
        // 10 s at 60 fps, give or take the final slot.
        #expect(report.framesWritten > 550,
                "wrote \(report.framesWritten) frames for a \(duration.seconds)s source")
        #expect(report.audioSamplesWritten > 0)
        let exported = try await AVURLAsset(url: outputURL).load(.duration)
        #expect(abs(exported.seconds - duration.seconds) < 0.3,
                "the exported file runs \(exported.seconds)s against \(duration.seconds)s")
    }

    /// A master with no audio still exports, and says so rather than failing.
    @Test func aSilentRecordingExportsWithNoAudioTrack() async throws {
        unsafe StageCompositor.renderer = try CoreImageFrameRenderer()
        unsafe StageCompositor.observationLogURL = nil
        unsafe StageCompositor.editTimeline = nil

        let asset = AVURLAsset(url: repositoryRootFromTests
            .appending(path: "Tests/RenderParityFixtures/two-tone.mov"))
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("silent-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let report = try await MP4Exporter.export(asset: asset, to: outputURL,
                                                  outputWidth: 320, outputHeight: 180)
        #expect(report.audioSamplesWritten == 0)
        #expect(try await AVURLAsset(url: outputURL).loadTracks(withMediaType: .audio).isEmpty)
    }

    // MARK: - progress and cancellation

    /// **Phases, not one percentage.** The last step is `AVAssetWriter.finishWriting`, which
    /// takes seconds on a long recording and reports nothing; a bar that reached 100% and sat
    /// there looks stopped, and a person cancels a job that was about to finish.
    @Test func anExportReportsItsPhasesInOrder() async throws {
        unsafe StageCompositor.renderer = try CoreImageFrameRenderer()
        unsafe StageCompositor.style = .default
        unsafe StageCompositor.observationLogURL = nil
        unsafe StageCompositor.overrides = []
        unsafe StageCompositor.editTimeline = nil

        let asset = AVURLAsset(url: repositoryRootFromTests
            .appending(path: "Tests/RenderParityFixtures/two-tone.mov"))
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("progress-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let seen = PhaseLog()
        _ = try await MP4Exporter.export(asset: asset, to: outputURL,
                                         outputWidth: 160, outputHeight: 90,
                                         onProgress: { seen.note($0) })

        let phases = seen.all
        #expect(phases.first == .preparing, "the first report was \(String(describing: phases.first))")
        #expect(phases.last == .finishing, "the last report was \(String(describing: phases.last))")
        let fractions = phases.compactMap(\.fraction)
        #expect(!fractions.isEmpty, "no writing progress was reported at all")
        // Monotonic and inside 0…1: a bar that goes backwards is worse than no bar.
        #expect(fractions == fractions.sorted(), "progress went backwards: \(fractions)")
        #expect(fractions.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    /// **Reported per whole percent, not per frame.** A 60 fps export of a three-minute
    /// recording is 10,800 frames; a callback each would cost more than the work it reports on.
    @Test func progressIsReportedPerPercentNotPerFrame() async throws {
        unsafe StageCompositor.renderer = try CoreImageFrameRenderer()
        unsafe StageCompositor.observationLogURL = nil
        unsafe StageCompositor.editTimeline = nil

        let asset = AVURLAsset(url: repositoryRootFromTests
            .appending(path: "Tests/RenderParityFixtures/two-tone.mov"))
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("percent-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let seen = PhaseLog()
        let report = try await MP4Exporter.export(asset: asset, to: outputURL,
                                                  outputWidth: 160, outputHeight: 90,
                                                  onProgress: { seen.note($0) })
        let writingReports = seen.all.filter { $0.fraction != nil }.count
        #expect(writingReports <= 101, "\(writingReports) writing reports — one per percent at most")
        #expect(writingReports < report.framesWritten,
                "as many reports as frames: \(writingReports) of \(report.framesWritten)")
    }

    /// **Cancelling deletes the partial file.** A half-written MP4 sitting where a person asked
    /// for their video is worse than none, because it looks like the export worked.
    @Test func cancellingAnExportLeavesNoFileBehind() async throws {
        unsafe StageCompositor.renderer = try CoreImageFrameRenderer()
        unsafe StageCompositor.observationLogURL = nil
        unsafe StageCompositor.editTimeline = nil

        let asset = AVURLAsset(url: repositoryRootFromTests
            .appending(path: "Tests/RenderParityFixtures/long-two-track-audio.mov"))
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cancelled-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let task = Task {
            try await MP4Exporter.export(asset: asset, to: outputURL,
                                         outputWidth: 160, outputHeight: 90)
        }
        // Long enough for the writer to have created the file and put frames in it, short
        // enough that a 10-second fixture is nowhere near done.
        try await Task.sleep(for: .milliseconds(120))
        task.cancel()

        await #expect(throws: (any Error).self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: outputURL.path),
                "a cancelled export left a partial file at \(outputURL.lastPathComponent)")
    }

    // MARK: - trim

    /// **A trim exports fewer frames, and the file still starts at zero.**
    ///
    /// The second half is the part that is easy to get wrong and invisible in a frame count:
    /// the composition's buffers keep their ORIGINAL presentation times, so a writer session
    /// started at `.zero` for a trim beginning part-way in produces a file whose first frames
    /// are empty for exactly the trimmed-away duration. Starting the session at the trim's
    /// start is what makes the output begin where the trim does.
    @Test func aTrimmedExportWritesFewerFramesAndStartsAtZero() async throws {
        unsafe StageCompositor.renderer = try CoreImageFrameRenderer()
        unsafe StageCompositor.style = .default
        unsafe StageCompositor.observationLogURL = nil
        unsafe StageCompositor.overrides = []
        unsafe StageCompositor.editTimeline = nil

        let asset = AVURLAsset(url: repositoryRootFromTests
            .appending(path: "Tests/RenderParityFixtures/two-tone.mov"))
        let duration = try await asset.load(.duration)

        let whole = FileManager.default.temporaryDirectory
            .appendingPathComponent("trim-whole-\(UUID().uuidString).mp4")
        let half = FileManager.default.temporaryDirectory
            .appendingPathComponent("trim-half-\(UUID().uuidString).mp4")
        defer {
            try? FileManager.default.removeItem(at: whole)
            try? FileManager.default.removeItem(at: half)
        }

        let full = try await MP4Exporter.export(asset: asset, to: whole,
                                                outputWidth: 160, outputHeight: 90)
        // The BACK half of the fixture, so the kept span does not start at zero — an edit
        // starting at zero would pass even with the timeline bug this test is here for.
        let totalNanos = Int64(duration.seconds * 1_000_000_000)
        let edit = EditTimeline.whole(duration: Nanoseconds(totalNanos))
            .trimmed(toSource: (totalNanos / 2)..<totalNanos)
        unsafe StageCompositor.editTimeline = edit
        defer { unsafe StageCompositor.editTimeline = nil }
        let trimmed = try await MP4Exporter.export(
            asset: asset, to: half, outputWidth: 160, outputHeight: 90, edit: edit)

        #expect(trimmed.framesWritten < full.framesWritten,
                "a half-length trim wrote \(trimmed.framesWritten) of \(full.framesWritten) frames")
        #expect(trimmed.framesWritten > 0, "the trim wrote nothing at all")

        let exported = AVURLAsset(url: half)
        let exportedDuration = try await exported.load(.duration)
        #expect(exportedDuration.seconds < duration.seconds * 0.75, """
                the trimmed file is \(exportedDuration.seconds)s against a source of \
                \(duration.seconds)s — the writer session did not start at the trim's start, \
                so the file carries the trimmed-away span as empty time at the front
                """)
    }

    /// A trim of no duration is refused rather than clamped: the caller has a bug, and a
    /// zero-length MP4 would hide it.
    @Test func aTrimWithNoDurationIsRefused() async throws {
        unsafe StageCompositor.renderer = try CoreImageFrameRenderer()
        unsafe StageCompositor.observationLogURL = nil
        unsafe StageCompositor.editTimeline = nil

        let asset = AVURLAsset(url: repositoryRootFromTests
            .appending(path: "Tests/RenderParityFixtures/two-tone.mov"))
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("trim-empty-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let empty = EditTimeline(clips: [])
        unsafe StageCompositor.editTimeline = empty
        defer { unsafe StageCompositor.editTimeline = nil }
        await #expect(throws: MP4Exporter.ExportError.self) {
            try await MP4Exporter.export(
                asset: asset, to: outputURL, outputWidth: 160, outputHeight: 90, edit: empty)
        }
    }

    /// **A cut, which a trim cannot stand in for.** `AVAssetReader.timeRange` selects ONE
    /// span; a timeline with a hole in the middle has two, and the `AVMutableComposition` built
    /// from it is what makes them one asset. This exports a 2 s fixture with its middle second
    /// removed and checks the file is a second shorter — a cut that silently exported the whole
    /// recording would still produce a valid, plausible MP4.
    @Test func aCutInTheMiddleExportsBothSurvivingClips() async throws {
        unsafe StageCompositor.renderer = try CoreImageFrameRenderer()
        unsafe StageCompositor.style = .default
        unsafe StageCompositor.observationLogURL = nil
        unsafe StageCompositor.overrides = []

        let asset = AVURLAsset(url: repositoryRootFromTests
            .appending(path: "Tests/RenderParityFixtures/two-tone.mov"))
        let duration = try await asset.load(.duration)
        let totalNanos = Int64(duration.seconds * 1_000_000_000)
        // Remove the middle half: 0.5s–1.5s of a 2s fixture.
        let edit = EditTimeline.whole(duration: Nanoseconds(totalNanos))
            .removing(sourceRange: (totalNanos / 4)..<(totalNanos * 3 / 4))
        #expect(edit.clips.count == 2, "the fixture for a cut must have two surviving clips")
        unsafe StageCompositor.editTimeline = edit
        defer { unsafe StageCompositor.editTimeline = nil }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cut-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        _ = try await MP4Exporter.export(asset: asset, to: outputURL,
                                         outputWidth: 160, outputHeight: 90, edit: edit)

        let exported = try await AVURLAsset(url: outputURL).load(.duration)
        let expected = Double(edit.outputDuration.rawValue) / 1_000_000_000
        #expect(abs(exported.seconds - expected) < 0.1, """
                the cut file runs \(exported.seconds)s against the timeline's \(expected)s — \
                an export that ignored the cut would run the full \(duration.seconds)s
                """)
    }

    /// **The pairing the export cannot be handed as an argument, checked instead.** The
    /// compositor reads the observation log in source time and is given output times, so it
    /// converts through a process-global `StageCompositor.editTimeline` — AVFoundation owns
    /// compositor instances, so there is nowhere else to put it. An export whose asset was cut
    /// one way while that static said another would place every cursor and every zoom by the
    /// difference, silently.
    @Test func exportingAgainstADifferentEditThanTheCompositorSeesIsRefused() async throws {
        unsafe StageCompositor.renderer = try CoreImageFrameRenderer()
        unsafe StageCompositor.observationLogURL = nil
        unsafe StageCompositor.editTimeline = EditTimeline.whole(duration: Nanoseconds(1_000))
        defer { unsafe StageCompositor.editTimeline = nil }

        let asset = AVURLAsset(url: repositoryRootFromTests
            .appending(path: "Tests/RenderParityFixtures/two-tone.mov"))
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mismatch-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        await #expect(throws: MP4Exporter.ExportError.self) {
            try await MP4Exporter.export(
                asset: asset, to: outputURL, outputWidth: 160, outputHeight: 90,
                edit: EditTimeline.whole(duration: Nanoseconds(2_000)))
        }
    }

    /// The readiness-timeout case exists, carries its frame/elapsed payload, and does not match
    /// another case's pattern. Constructed directly: forcing a real stall would mean either
    /// shrinking the shipped deadline or hanging 5 real seconds on every run.
    @Test func theReadinessTimeoutCaseIsDistinguishableAndNamesFrameAndElapsedTime() {
        let timeoutError = MP4Exporter.ExportError.writerNotReadyInTime(frame: 42, elapsedSeconds: 5.0)
        let mismatchError = MP4Exporter.ExportError.outputShorterThanSource(lastWritten: 1.0,
                                                                            lastSource: 2.0)

        guard case .writerNotReadyInTime(let frame, let elapsed) = timeoutError else {
            Issue.record("expected the timeout case's own payload back out of itself")
            return
        }
        #expect(frame == 42)
        #expect(elapsed == 5.0)
        #expect(timeoutError.description.contains("42"), "the message names the frame index")
        #expect(timeoutError.description.contains("5.00"), "the message names the elapsed time")

        if case .writerNotReadyInTime = mismatchError {
            Issue.record("""
                outputShorterThanSource matched the timeout case's own pattern — the two cases are \
                not actually distinguishable
                """)
        }
    }

    /// `ExportError`'s other six public cases, unconstructed anywhere else: each one's
    /// `description` names what the case claims, which is the diagnostic a person hitting a real
    /// export failure reads.
    @Test func theRemainingExportErrorCasesDescribeWhatTheyClaim() {
        #expect(MP4Exporter.ExportError.noVideoTrack.description.contains("no video track"))

        #expect(MP4Exporter.ExportError.readerRefusedOutput.description.contains("AVAssetReader"))
        #expect(MP4Exporter.ExportError.readerRefusedOutput.description.contains("refused"))

        #expect(MP4Exporter.ExportError.writerRefusedInput.description.contains("AVAssetWriter"))
        #expect(MP4Exporter.ExportError.writerRefusedInput.description.contains("refused"))

        let readerFailure = MP4Exporter.ExportError.readerFailed("synthetic reader failure, test-only")
        #expect(readerFailure.description.contains("AVAssetReader failed"))
        #expect(readerFailure.description.contains("synthetic reader failure, test-only"),
                "the underlying reason passes through, not just a fixed label")

        let writerFailure = MP4Exporter.ExportError.writerFailed("synthetic writer failure, test-only")
        #expect(writerFailure.description.contains("AVAssetWriter failed"))
        #expect(writerFailure.description.contains("synthetic writer failure, test-only"),
                "the underlying reason passes through, not just a fixed label")

        let appendFailure = MP4Exporter.ExportError.appendRefused("synthetic append refusal, test-only")
        #expect(appendFailure.description.contains("append refused"))
        #expect(appendFailure.description.contains("synthetic append refusal, test-only"),
                "the underlying reason passes through, not just a fixed label")
    }
}


/// Collects progress reports from the export's callback, which runs off the test's actor.
private final class PhaseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [ExportProgress] = []
    func note(_ phase: ExportProgress) { lock.withLock { phases.append(phase) } }
    var all: [ExportProgress] { lock.withLock { phases } }
}

/// The mix both the export and the preview build from.
@Suite struct AudioMixBuilderTests {
    /// **The track order is the only thing identifying a source.** An `AVAssetTrack` carries no
    /// name a caller can match on, so the mix relies on the master writer laying system audio
    /// down first and the microphone second. If that order ever changed, every recording would
    /// have its two sources swapped silently — so the order is a named constant and this is the
    /// test that fails when someone reorders it.
    @Test func theTrackOrderIsSystemAudioThenMicrophone() {
        #expect(AudioMixBuilder.trackOrder == [.systemAudio, .microphone])
    }

    /// A mix over no tracks is empty rather than a crash — which is what a recording with the
    /// microphone turned off produces.
    @Test func aMixOverNoTracksHasNoParameters() {
        let mix = AudioMixBuilder.mix(.unchanged, over: [])
        #expect(mix.inputParameters.isEmpty)
    }

    /// A muted source is silent and an untouched one is not, which is the whole contract.
    @Test func mutingASourceTakesItsGainToZero() {
        let microphone = AudioMix.Source.microphone
        let system = AudioMix.Source.systemAudio
        let muted = AudioMix().setting(microphone, muted: true)
        #expect(muted.effectiveGain(for: microphone) == 0)
        #expect(muted.effectiveGain(for: system) == 1)
        // And a gain survives being muted and unmuted, so a level a person set is not lost by
        // toggling the checkbox beside it.
        let quiet = AudioMix().setting(microphone, gain: 0.4).setting(microphone, muted: true)
        #expect(quiet.effectiveGain(for: microphone) == 0)
        #expect(quiet.setting(microphone, muted: false).effectiveGain(for: microphone) == 0.4)
    }
}
