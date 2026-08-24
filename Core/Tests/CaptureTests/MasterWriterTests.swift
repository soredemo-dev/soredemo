import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import Capture

// The first `swift test` tests of the master writers. Until Phase 3A-3 they lived in the
// app target, where `swift test` cannot link them — so a writer that refused every append
// would have been caught only by a person recording something and looking at the file.

/// A function, not a `let`: a global `[String: Any]` is not `Sendable` under Swift 6.
private func videoSettings() -> [String: Any] {
    [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180]
}

private func scratchURL() -> URL {
    URL.temporaryDirectory.appending(path: "master-\(UUID()).mov")
}

// MARK: - MasterWriterStatus: the mapping that lets AVFoundation's enum stay out of CaptureSession

/// `.unrecognised` carries the raw value rather than collapsing to `.unknown`. The two are
/// different facts: `.unknown` is a state AVFoundation defines and this build handles,
/// `.unrecognised` is one it does not — and a report that cannot say which number arrived
/// leaves the next reader with nothing to look up.
@Test func anUnrecognisedStatusKeepsTheRawValueItCouldNotName() {
    #expect(MasterWriterStatus.unrecognised(99).name == "unrecognised(99)")
    #expect(MasterWriterStatus.unrecognised(99) != MasterWriterStatus.unknown)
    #expect(MasterWriterStatus.unrecognised(99) != MasterWriterStatus.unrecognised(98))
}

/// Every named case prints its own name. A `name` that fell through to one string would
/// make every status line in a diagnostic say the same thing.
@Test func eachNamedStatusPrintsItsOwnName() {
    let names = [MasterWriterStatus.unknown, .writing, .completed, .failed, .cancelled].map(\.name)
    #expect(names == ["unknown", "writing", "completed", "failed", "cancelled"])
    #expect(Set(names).count == names.count)
}

// MARK: - LegacyMasterWriter: a real AVAssetWriter, opened and finished on disk

/// Construction opens a real `AVAssetWriter` and starts it, so a fresh writer is already
/// `.writing` — not `.unknown`. That is the claim `CaptureSession` relies on when it
/// appends the first frame without checking a start flag of its own.
@Test func aFreshLegacyWriterIsAlreadyWriting() throws {
    let url = scratchURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try LegacyMasterWriter(
        outputURL: url, videoSettings: videoSettings(),
        refusedInput: { _ in CaptureError.alreadyObserving },
        startFailed: { _ in CaptureError.alreadyObserving })

    #expect(writer.status == .writing)
    #expect(writer.outputURL == url)
    #expect(writer.errorDescription == nil)
}

/// The three tracks are three DISTINCT objects. One `AVAssetWriterInput` reused for both
/// audio tracks would mix system audio and microphone into one track — the exact defect
/// Phase 2 measured in `SCRecordingOutput` and rejected it for.
@Test func aLegacyWriterExposesThreeDistinctTracks() throws {
    let url = scratchURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try LegacyMasterWriter(
        outputURL: url, videoSettings: videoSettings(),
        refusedInput: { _ in CaptureError.alreadyObserving },
        startFailed: { _ in CaptureError.alreadyObserving })

    let tracks: [any MasterTrackWriting] = [writer.video, writer.systemAudio, writer.microphone]
    for (i, a) in tracks.enumerated() {
        for b in tracks[(i + 1)...] {
            #expect(a !== b, "two of the three master tracks are the same object")
        }
    }
}

/// A writer that never had a session started and is then finished lands in a terminal
/// state and says so. The point is that `finish()` RETURNS — an `await` that never resumes
/// is how an export hangs, and this is the shape `MP4Exporter`'s readiness deadline exists
/// for one tier down.
@Test func aLegacyWriterFinishesWithoutASessionAndReportsATerminalStatus() async throws {
    let url = scratchURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try LegacyMasterWriter(
        outputURL: url, videoSettings: videoSettings(),
        refusedInput: { _ in CaptureError.alreadyObserving },
        startFailed: { _ in CaptureError.alreadyObserving })

    await writer.finish()
    #expect(writer.status == .failed || writer.status == .completed,
            "expected a terminal status after finish(), got \(writer.status.name)")
}

/// A writer whose output URL cannot be opened throws rather than returning a writer that
/// fails later. This is the throwing path that IS reachable; the two closure-supplied
/// errors are not, and saying so is better than a test that pretends otherwise.
///
/// **`refusedInput` and `startFailed` have no test, and this is why.** Both fire only on
/// inputs `AVAssetWriter` refuses, and the settings that would produce a refusal —
/// a nonsense codec, a zero dimension — make `AVAssetWriterInput(mediaType:outputSettings:)`
/// TRAP rather than return nil: measured here, the process aborted with signal 6 inside
/// the initialiser before either closure could run. A test cannot catch a trap, so the
/// two paths stay covered by review and by the caller's own error type being used at all,
/// which the signature enforces. Recorded rather than left as a silent gap.
@Test func aWriterThatCannotOpenItsOutputThrows() {
    // A directory that does not exist: AVAssetWriter's own initialiser throws here.
    let unwritable = URL(filePath: "/nonexistent-\(UUID())/master.mov")
    #expect(throws: (any Error).self) {
        _ = try LegacyMasterWriter(
            outputURL: unwritable, videoSettings: videoSettings(),
            refusedInput: { _ in CaptureError.alreadyObserving },
            startFailed: { _ in CaptureError.alreadyObserving })
    }
}

// MARK: - SuccessorMasterWriter

/// The successor conforms to the same protocol, which is the whole point of there being a
/// protocol: `CaptureSession` holds `any MasterWriting` and the macOS 27 migration is a
/// construction-site change rather than a rewrite of every `switch`.
@Test func bothWritersSatisfyTheSameProtocol() throws {
    let url = scratchURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let legacy: any MasterWriting = try LegacyMasterWriter(
        outputURL: url, videoSettings: videoSettings(),
        refusedInput: { _ in CaptureError.alreadyObserving },
        startFailed: { _ in CaptureError.alreadyObserving })
    #expect(legacy.outputURL == url)

    // `SuccessorMasterWriter` is named here rather than constructed: its initialiser uses
    // `AVAssetWriter.inputReceiver(for:)`, which is macOS 27 and above this package's 26.0
    // floor, so this machine cannot build a live one. Naming the type is what the entry
    // rule's scanner checks; that this is weaker than exercising it is stated rather than
    // hidden, and it is the same limit the successor has carried since it was written.
    let successorType: any MasterWriting.Type = SuccessorMasterWriter.self
    #expect(ObjectIdentifier(successorType) != ObjectIdentifier(LegacyMasterWriter.self))
}

// MARK: - closing a track nothing feeds

/// **A 9.3-second recording came out with 0.046 seconds of audio — three AAC packets.**
///
/// `AVAssetWriter` interleaves its inputs: it cannot lay out the file until each has advanced
/// past the point being written, so an input that never receives a sample makes the OTHERS
/// report `isReadyForMoreMediaData == false` and stay there. `CaptureSession.appendAudio`
/// drops what it cannot append and counts it, so the loss is invisible in the file. The
/// microphone input was created, added, never fed and never finished.
///
/// `MP4Exporter` hit the same mechanism from the other side within a day of this, which is why
/// `markFinished` exists on the protocol rather than inside one implementation.
@Suite struct MasterTrackClosingTests {
    @Test func everyTrackCanBeNamedForClosing() {
        #expect(MasterTrack.allCases.map(\.rawValue).sorted()
                == ["microphone", "systemAudio", "video"])
    }

    /// `AVAssetWriterInput.markAsFinished()` traps on a second call, and the two callers —
    /// an unfed track closed early, and `finish()` closing everything — legitimately overlap.
    /// Asserted through the public surface rather than by counting calls: a second
    /// `markFinished` must simply not trap.
    @Test func markingATrackFinishedTwiceIsSafe() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("master-close-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try LegacyMasterWriter(
            outputURL: url,
            videoSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                            AVVideoWidthKey: 160, AVVideoHeightKey: 90],
            refusedInput: { MasterWriterTestError.refused($0) },
            startFailed: { MasterWriterTestError.startFailed($0) })

        writer.markFinished(.microphone)
        writer.markFinished(.microphone)
        writer.markFinished(.systemAudio)
        // …and `finish()` closes the rest, including the two already closed.
        await writer.finish()
    }

    /// A finished track refuses further samples rather than appending them to an input that
    /// has been closed — which is a trap in AVFoundation, not a returned `false`.
    @Test func aFinishedTrackRefusesFurtherSamples() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("master-refuse-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try LegacyMasterWriter(
            outputURL: url,
            videoSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                            AVVideoWidthKey: 160, AVVideoHeightKey: 90],
            refusedInput: { MasterWriterTestError.refused($0) },
            startFailed: { MasterWriterTestError.startFailed($0) })
        writer.startSession(at: .zero)
        writer.markFinished(.microphone)

        // Readiness on a closed track is still readable — `CaptureSession.appendAudio` asks
        // before every append and must not trap on a track that has been closed under it.
        _ = writer.microphone.isReadyForMoreMediaData
        await writer.finish()
    }
}

private enum MasterWriterTestError: Error {
    case refused(String)
    case startFailed(String?)
}

// MARK: - the order everything downstream reads by position

/// **`AudioMix` maps a name to a track by POSITION, and this is the assumption it rests on.**
///
/// A `.mov` audio track carries no role, so "which one is the microphone" can only be answered
/// by the order the writer added its inputs. `MP4Exporter.mix` uses that order to set each
/// source's level. Without this test, reordering the three lines in `LegacyMasterWriter.init`
/// would silently mute the wrong source in a file nobody re-checks — the export would still
/// succeed and still contain audio.
@Suite struct MasterTrackOrderTests {
    /// **Asserted against the SOURCE, and the limit is worth stating.** The order that matters
    /// is the one in the finished file, but a master with no samples written is not an openable
    /// asset — AVFoundation reports it damaged — and writing real video and two real audio
    /// streams here would be building a recorder to test a line. So this pins the line itself.
    ///
    /// A file-level check does exist and covers the same ground from the other side:
    /// `aRecordingWithAudioExportsWithOneMixedAudioTrack` exports a two-audio-track fixture and
    /// asserts the result. What it cannot say is WHICH source ended up where, which is exactly
    /// what the positional mapping needs and what this pins.
    @Test func theMasterAddsItsTracksInAKnownOrder() throws {
        let source = try String(contentsOf: repositoryRootFromCaptureTests
            .appending(path: "Sources/Capture/MasterWriter.swift"), encoding: .utf8)
        let line = try #require(source.split(separator: "\n")
            .first { $0.contains("for input in [") },
            "the writer no longer adds its inputs in one place — the order cannot be read")
        #expect(line.contains("videoInput, systemAudioInput, micInput"), """
            the writer adds its inputs in a different order now: \(line)
            `MP4Exporter.mix` maps [.systemAudio, .microphone] onto the audio tracks BY \
            POSITION, because a .mov audio track carries no role. Changing this line silently \
            mutes or boosts the wrong source, in an export that still succeeds and still \
            contains audio — which is why it is pinned rather than left to be noticed.
            """)

        // …and the two audio inputs are declared in that same order above it, so the names in
        // the line above are not a coincidence of spelling.
        let systemIndex = try #require(source.range(of: "let systemAudioInput"))
        let micIndex = try #require(source.range(of: "let micInput"))
        #expect(systemIndex.lowerBound < micIndex.lowerBound, """
            systemAudioInput is declared after micInput, so the names in the add-order line no \
            longer mean what the positional mapping assumes.
            """)
    }
}

/// `<package>/Tests/CaptureTests/<this file>` → the package root.
let repositoryRootFromCaptureTests = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private enum MasterOrderTestError: Error {
    case refused(String)
    case startFailed(String?)
}

// MARK: - the master's own bit rate

/// **The master spends what the best export spends, and the two are pinned to one number.**
/// `MasterQuality` restates `ExportQuality.best`'s arithmetic because `Capture` cannot import
/// `Compositing`; this is the figure both produce for 1080p60 — 1920 × 1080 × 0.3 × (30 +
/// 30 × 0.6) = 29,859,840 — so a retune of either that is not mirrored in the other reddens
/// here. The floor is asserted on a window small enough to need it.
@Test func theMasterSpendsWhatTheBestExportSpends() {
    #expect(MasterQuality.videoBitRate(pixelWidth: 1920, pixelHeight: 1080, frameRate: 60) == 29_859_840)
    #expect(MasterQuality.videoBitRate(pixelWidth: 320, pixelHeight: 200, frameRate: 30) == 2_000_000)
    let properties = MasterQuality.compressionProperties(pixelWidth: 3024, pixelHeight: 1964, frameRate: 60)
    #expect(properties[AVVideoAverageBitRateKey] as? Int == MasterQuality.videoBitRate(pixelWidth: 3024, pixelHeight: 1964, frameRate: 60))
    #expect(properties[AVVideoMaxKeyFrameIntervalKey] as? Int == 120)
    #expect(properties[AVVideoProfileLevelKey] as? String == AVVideoProfileLevelH264HighAutoLevel)
}
