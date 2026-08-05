import Testing
import Foundation
import AVFoundation
import CoreMedia
@testable import Headless

/// **Joins the `StageCompositorTests` serialized suite — deliberately not a new suite of its
/// own.** `StageCompositor.renderer`/`.style`/`.observationLogURL`/`.overrides` are process-global
/// mutable state (`StageCompositorTests.swift`'s own header), and a real `MP4Exporter.export`
/// call drives that same compositor through `CompositionBuilder.composition`'s installed
/// `customVideoCompositorClass`, exactly as `RecordedPointerPositionTests.swift` already does for
/// the same reason. That file's own header states the rule this one follows: a second
/// `@Suite(.serialized)` here would not serialise against `StageCompositorTests`'s own suite —
/// Swift Testing does not serialise sibling top-level suites against each other — so the only
/// way to actually stop racing those tests on the same statics is to extend that suite, not
/// declare a new one.
extension StageCompositorTests {
    /// A wall-clock ceiling around the WHOLE export, distinct from `MP4Exporter`'s own internal
    /// per-frame `readinessDeadlineSeconds` (5s, `MP4Exporter.swift`'s own doc comment). That
    /// per-frame cap is the real fix for Spike D's stall; this is what stops a REGRESSION in that
    /// cap — an edit that widens or removes it — from hanging this test, and therefore `swift
    /// test`, with no output. A `Task.sleep`-based cancelling arm races the real export inside a
    /// `withThrowingTaskGroup`, not a second copy of the production bound. 30s is generous for a
    /// 64×64, 2-second, 20-frame source (`Tests/RenderParityFixtures/two-tone.mov`) composed at a
    /// small output size — the real export is expected to finish in well under a second; this
    /// only fires on a genuine regression.
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

    /// The entry-rule discharge for `MP4Exporter`, against the same real fixture
    /// `CompositionBuilderTests` already uses — `Tests/RenderParityFixtures/two-tone.mov` — run
    /// through the real `CompositionBuilder`/`StageCompositor`/`CoreImageFrameRenderer` stack,
    /// not a synthesised asset. Output goes under `FileManager.default.temporaryDirectory`, never
    /// `$HOME`, and is deleted in a `defer` regardless of how the test exits; nothing this test
    /// writes is committed.
    @Test func exportingTheFixtureNeverDropsAFrameAndFinishesWithinTheTestsOwnTimeout() async throws {
        // `nonisolated(unsafe) static var` on all four — `StageCompositorTests.swift`'s own
        // header explains why (`observationLogURL`/`overrides` published before playback starts,
        // read by any `StageCompositor` instance); `unsafe` here states that shape at this call
        // site, matching that file's own precedent for the two it already touches.
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

        // `resourceValues(forKeys:)`, not `fileExists(atPath:isDirectory:)` — the latter's
        // `isDirectory` out-parameter is an `UnsafeMutablePointer`, a `StrictMemorySafety`-flagged
        // construct (measured: `swift build` warns on it directly); this reaches the same fact
        // through a safe API.
        let resourceValues = try outputURL.resourceValues(forKeys: [.isDirectoryKey])
        #expect(FileManager.default.fileExists(atPath: outputURL.path)
                && resourceValues.isDirectory == false, "the exported file exists on disk")

        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let size = attributes[.size] as? Int ?? 0
        #expect(size > 0, "the exported file is non-empty")
    }

    /// **Distinguishable — the entry rule's own third requirement for the new case.** Not
    /// exercised by forcing a real stall inside `swift test`: that would need either shrinking
    /// the production `readinessDeadlineSeconds` for the test (changing the shipped constant to
    /// make a test pass) or genuinely hanging for 5 real seconds on every run, and the task's own
    /// instructions ask for the real stall to be observed BY HAND, once, with the deadline forced
    /// to zero, then reverted — see `task-7-report.md`'s "observed red" section — not re-run here
    /// on every `swift test`. Constructed directly instead: enough to prove the case exists,
    /// carries its own frame/elapsed payload, and does not collide with any other `ExportError`
    /// case's own pattern.
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

    /// **`ExportError`'s other six cases, unconstructed anywhere else `swift test` reaches —
    /// code review (Task 7).** `noVideoTrack`, `readerRefusedOutput`, `writerRefusedInput`,
    /// `readerFailed`, `writerFailed` and `appendRefused` became `public` with the type itself
    /// (Task 7's move set access levels per TYPE, not per case — an individual enum case cannot
    /// be made non-public while its enum is public, so narrowing access to only the two cases the
    /// other tests in this file already construct is not an option). `docs/ARCHITECTURE.md`
    /// D6a-V: unexercised public API is an unverified capability claim, not only a dead-code
    /// smell — so this constructs each of the six directly and checks that its `description`
    /// actually names what the case claims to, the same diagnostic a person hitting a real export
    /// failure would read. Chosen over a D6a-V table row because these are simple values with no
    /// external dependency to fake (no writer, no reader, no disk) — cheap enough that recording
    /// them as "unexercised, and here is why" would cost more than just exercising them.
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
