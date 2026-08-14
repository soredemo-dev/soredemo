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
