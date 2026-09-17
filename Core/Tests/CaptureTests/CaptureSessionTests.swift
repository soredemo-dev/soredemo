import Foundation
import Geometry
import Project
import Testing
import Timeline
@testable import Capture

// `CaptureSession` was the last file out of the app target, and the largest. Most of it
// is `SCStream` delegate plumbing that no test can reach: `SCStream`, `SCStreamOutput`
// callbacks and `CMSampleBuffer`s from a live display are not constructible, and a session
// needs Screen Recording granted to a bundled app. That does not change here, and this
// file says so rather than implying more from a green run — the real coverage for the
// stream half stays `scripts/run-cross-boundary-probe.sh` and a person recording.
//
// What the move DID make reachable is the part with the arithmetic in it: the segment
// ledger, and the accounting invariants the diagnostics promise. Those had never been
// executed by anything automatic.

private let epoch = BootEpoch(id: UUID(uuidString: "7F3E1A55-9C24-4D6B-8E70-2A1B4C6D8E90")!)
private let otherEpoch = BootEpoch(id: UUID(uuidString: "0BADC0DE-0000-4000-8000-00000000000A")!)

private func at(_ ns: Int64) -> HostInstant {
    HostInstant(epoch: epoch, hostTime: Nanoseconds(ns))
}

private func revision() -> GeometryRevision {
    DisplayGeometry(displayUUID: UUID(uuidString: "A1B2C3D4-0000-4000-8000-00000000000B")!,
                    pixelWidth: 1920, pixelHeight: 1080, scale: 2.0).revision
}

// MARK: - SegmentLedger: the open/close state machine

/// A ledger starts closed. `isSegmentOpen` is what `stop()` consults to decide whether it
/// has a segment to finalise, so a ledger that claimed one at construction would make
/// every session close a segment that never opened.
@Test func aFreshLedgerHasNoOpenSegment() {
    #expect(SegmentLedger().isSegmentOpen == false)
}

/// Open then close: the closed segment carries the media filename, the revision and a
/// `hostRange` spanning exactly the two instants. All four values are distinct so a
/// transposition shows up.
@Test func aClosedSegmentCarriesItsRangeFilenameAndRevision() {
    var ledger = SegmentLedger()
    ledger.openSegment(at: at(1_000), revision: revision(), mediaFilename: "master-00.mov")
    #expect(ledger.isSegmentOpen)

    let segment = ledger.closeSegment(at: at(5_000), endedBy: .stopped)
    #expect(segment.index == 0)
    #expect(segment.mediaFilename == "master-00.mov")
    #expect(segment.revision == revision())
    #expect(segment.hostRange.start == Nanoseconds(1_000))
    #expect(segment.hostRange.duration == Nanoseconds(4_000))
    #expect(segment.endedBy == .stopped)
    #expect(ledger.isSegmentOpen == false)
}

/// Indices count up from zero across segments, and each segment keeps the boundary that
/// ended it — `paused` and `stopped` are different facts about why a recording broke, and
/// a table that lost the distinction could not tell a pause from a crash.
@Test func segmentsAreIndexedInOrderAndKeepTheirOwnBoundary() throws {
    var ledger = SegmentLedger()
    ledger.openSegment(at: at(0), revision: revision(), mediaFilename: "master-00.mov")
    ledger.closeSegment(at: at(1_000), endedBy: .paused)
    ledger.openSegment(at: at(2_000), revision: revision(), mediaFilename: "master-01.mov")
    ledger.closeSegment(at: at(3_000), endedBy: .stopped)

    let table = try ledger.finish()
    #expect(table.segments.map(\.index) == [0, 1])
    #expect(table.segments.map(\.endedBy) == [.paused, .stopped])
    #expect(table.segments.map(\.mediaFilename) == ["master-00.mov", "master-01.mov"])
}

/// `finish()` on an empty ledger produces an empty table rather than throwing: a session
/// that started and stopped without a frame recorded nothing, which is a legitimate
/// outcome and not a malformed one.
@Test func anEmptyLedgerFinishesToAnEmptyTable() throws {
    #expect(try SegmentLedger().finish().segments.isEmpty)
}

/// A zero-width segment — opened and closed at the same instant — is allowed through. The
/// ledger's job is bookkeeping, not judging whether a recording was long enough, and a
/// rejection here would lose the record that a segment was attempted at all.
@Test func aZeroWidthSegmentIsRecordedRatherThanRefused() {
    var ledger = SegmentLedger()
    ledger.openSegment(at: at(1_000), revision: revision(), mediaFilename: "master-00.mov")
    let segment = ledger.closeSegment(at: at(1_000), endedBy: .stopped)
    #expect(segment.hostRange.duration == Nanoseconds(0))
}

/// `displayReconfigured` carries the NEW revision, which is what makes a reconfiguration
/// distinguishable from a pause in the finished table — the boundary is where the next
/// segment's geometry comes from.
@Test func aReconfigurationBoundaryCarriesTheNewRevision() {
    var ledger = SegmentLedger()
    let next = DisplayGeometry(displayUUID: UUID(uuidString: "A1B2C3D4-0000-4000-8000-00000000000C")!,
                               pixelWidth: 3024, pixelHeight: 1964, scale: 2.0).revision
    ledger.openSegment(at: at(0), revision: revision(), mediaFilename: "master-00.mov")
    let segment = ledger.closeSegment(at: at(10), endedBy: .displayReconfigured(newRevision: next))
    guard case .displayReconfigured(let carried) = segment.endedBy else {
        Issue.record("the boundary lost its case")
        return
    }
    #expect(carried == next)
    #expect(carried != revision())
}

// MARK: - AudioTrackAccounting: the invariant the counters promise

/// **`balances` is the file's own stated invariant**: every delivered buffer leaves
/// `appendAudio` by exactly one path. A fresh accounting balances trivially, and the
/// non-trivial case below is what makes that assertion mean something.
@Test func afreshAudioAccountingBalances() {
    #expect(CaptureSession.Diagnostics.AudioTrackAccounting().balances)
}

/// Six exits accounted for, one delivery each: the sum matches. Then one delivery is added
/// without an exit and the invariant fails — a counter that always returned true would
/// pass the first half and not the second.
@Test func audioAccountingBalancesOnlyWhenEveryDeliveryHasAnExit() {
    var accounting = CaptureSession.Diagnostics.AudioTrackAccounting()
    accounting.delivered = 6
    accounting.appended = 1
    accounting.refused = 1
    accounting.skippedWriterNotWriting = 1
    accounting.skippedInputNotReady = 1
    accounting.skippedSessionNotStarted = 1
    accounting.uninterleavable = 1
    #expect(accounting.balances)

    accounting.delivered = 7
    #expect(accounting.balances == false,
            "a delivered buffer that left by no path must break the invariant")
}

// MARK: - the value types stop() hands back

/// `Outcome` distinguishes a session whose media all reached the package from one where
/// some did not, and the incomplete case carries the discarded entries — a stop that
/// collapsed the two would report a partial recording as a whole one.
@Test func anIncompleteOutcomeCarriesWhatWasDiscarded() throws {
    var ledger = SegmentLedger()
    ledger.openSegment(at: at(0), revision: revision(), mediaFilename: "master-00.mov")
    ledger.closeSegment(at: at(1_000), endedBy: .stopped)
    let table = try ledger.finish()

    let discarded = CaptureSession.Diagnostics.DiscardedSegment(
        mediaFilename: "master-00.mov", writerStatus: "failed",
        writerError: "disk full", retainedScratchPath: "/tmp/master-00.mov")
    let outcome = CaptureSession.Outcome.incomplete(table, discarded: [discarded])

    guard case .incomplete(_, let entries) = outcome else {
        Issue.record("an .incomplete outcome did not report as incomplete")
        return
    }
    #expect(entries.count == 1)
    // The scratch path is deliberately not deleted — these are the captured bytes.
    #expect(entries[0].retainedScratchPath == "/tmp/master-00.mov")
    #expect(entries[0].writerError == "disk full")
}

/// `SessionError` is `Equatable` including its associated values, so a caller can
/// distinguish two writer failures with different messages rather than treating every
/// `.writerFailed` as the same event.
@Test func twoWriterFailuresWithDifferentReasonsAreDifferentErrors() {
    #expect(CaptureSession.SessionError.writerFailed("a")
            != CaptureSession.SessionError.writerFailed("b"))
    #expect(CaptureSession.SessionError.notRunning != CaptureSession.SessionError.alreadyRunning)
}

/// A `SegmentConfiguration` records what was ASKED FOR at the moment it was set. The
/// content-scale bounds are per segment rather than session-wide, because a session-wide
/// min/max cannot say which segment saw which scale.
@Test func aSegmentConfigurationRecordsItsOwnContentScaleBounds() {
    var configuration = CaptureSession.Diagnostics.SegmentConfiguration(
        bufferWidth: 3024, bufferHeight: 1964,
        destination: PixelRect(x: 0, y: 0, width: 1920, height: 1080), scale: 2.0)
    #expect(configuration.contentScaleMin == nil)
    #expect(configuration.contentScaleMax == nil)
    configuration.contentScaleMin = 1.0
    configuration.contentScaleMax = 2.0
    #expect(configuration.contentScaleMin != configuration.contentScaleMax)
    #expect(configuration.framesResampled == 0)
}

// MARK: - MediaSink

/// The protocol the app tier conforms to. Named and conformed to here so the seam is
/// exercised at all — `ProjectDocument` is the production conformer and needs an
/// `NSDocument`, which no package test can build.
@Test func aMediaSinkReceivesWhatItIsHanded() async {
    final class Recorder: MediaSink, @unchecked Sendable {
        var received: [(name: String, bytes: Int)] = []
        @MainActor var packageURL: URL? { nil }
        @MainActor func acceptMedia(_ data: Data, named name: String) throws {
            received.append((name, data.count))
        }
    }
    let recorder = Recorder()
    await MainActor.run {
        try? recorder.acceptMedia(Data([0, 1, 2]), named: "master-00.mov")
    }
    #expect(recorder.received.count == 1)
    #expect(recorder.received[0].name == "master-00.mov")
    #expect(recorder.received[0].bytes == 3)
}


// MARK: - a window that changed size while it was being recorded

/// **Counted since the session was written, and never said until 2026-09-18.** A window
/// source's frame size is fixed when its segment opens, so a resize mid-recording is carried
/// by scaling the content into the frame it already has. The counters below have existed all
/// along; nothing outside these tests read them, so somebody whose recording came out soft had
/// no way to find out why.
@Suite struct ResamplingRangeTests {
    private func configuration(resampled: Int, low: Double?, high: Double?)
    -> CaptureSession.Diagnostics.SegmentConfiguration {
        var configuration = CaptureSession.Diagnostics.SegmentConfiguration(
            bufferWidth: 1920, bufferHeight: 1080,
            destination: PixelRect(x: 0, y: 0, width: 1920, height: 1080), scale: 1)
        configuration.framesResampled = resampled
        configuration.contentScaleMin = low
        configuration.contentScaleMax = high
        return configuration
    }

    /// **Nothing scaled is `nil`, not a range of 1 to 1.** A recording that never resized must
    /// say nothing at all — a message on every take is a message people stop reading, which is
    /// the rule the recording-health wording already follows.
    @Test func aRecordingThatNeverResizedSaysNothing() {
        var diagnostics = CaptureSession.Diagnostics()
        diagnostics.segmentConfigurations = [configuration(resampled: 0, low: 1, high: 1)]
        #expect(diagnostics.resamplingRange == nil)
    }

    /// The range spans every segment, because a person who resized in the second one resized.
    @Test func theRangeSpansEverySegmentThatResampled() {
        var diagnostics = CaptureSession.Diagnostics()
        diagnostics.segmentConfigurations = [
            configuration(resampled: 0, low: 1, high: 1),
            configuration(resampled: 40, low: 0.62, high: 0.98),
            configuration(resampled: 7, low: 0.55, high: 1.10),
        ]
        let range = diagnostics.resamplingRange
        #expect(range?.low == 0.55)
        #expect(range?.high == 1.10)
    }

    /// **A segment with a count but no scales is not a range.** The two are written at
    /// different moments and a half-filled configuration must not become a message with a
    /// missing number in it.
    @Test func aCountWithNoScalesIsNotARange() {
        var diagnostics = CaptureSession.Diagnostics()
        diagnostics.segmentConfigurations = [configuration(resampled: 12, low: nil, high: nil)]
        #expect(diagnostics.resamplingRange == nil)
    }

    /// Nothing recorded at all is nothing to say.
    @Test func noSegmentsIsNoRange() {
        #expect(CaptureSession.Diagnostics().resamplingRange == nil)
    }
}
