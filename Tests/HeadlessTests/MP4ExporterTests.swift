import Testing
import Foundation
import AVFoundation
import CoreMedia
@testable import Headless

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

        #expect(report.framesRead == report.framesWritten, """
                MP4Exporter.export itself throws .frameCountMismatch on a real disagreement; \
                restated here so a future change that removed that throw would still show up
                """)

        // `resourceValues(forKeys:)`, not `fileExists(atPath:isDirectory:)`: the latter's
        // out-parameter is an `UnsafeMutablePointer`, which `StrictMemorySafety` warns on.
        let resourceValues = try outputURL.resourceValues(forKeys: [.isDirectoryKey])
        #expect(FileManager.default.fileExists(atPath: outputURL.path)
                && resourceValues.isDirectory == false, "the exported file exists on disk")

        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let size = attributes[.size] as? Int ?? 0
        #expect(size > 0, "the exported file is non-empty")
    }

    /// The readiness-timeout case exists, carries its frame/elapsed payload, and does not match
    /// another case's pattern. Constructed directly: forcing a real stall would mean either
    /// shrinking the shipped deadline or hanging 5 real seconds on every run.
    @Test func theReadinessTimeoutCaseIsDistinguishableAndNamesFrameAndElapsedTime() {
        let timeoutError = MP4Exporter.ExportError.writerNotReadyInTime(frame: 42, elapsedSeconds: 5.0)
        let mismatchError = MP4Exporter.ExportError.frameCountMismatch(read: 3, written: 2)

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
                frameCountMismatch matched the timeout case's own pattern — the two cases are \
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
