import AVFoundation
import Foundation
import Testing
import Timeline
@testable import Compositing

/// `EditedAsset` is what the preview and the export both cut with. It was extracted from
/// `MP4Exporter` the moment the preview needed it rather than copied into it — two
/// implementations of a cut would be two videos, one reviewed and one shipped.
extension StageCompositorTests {
    private static func fixture() -> AVURLAsset {
        AVURLAsset(url: repositoryRootFromTests
            .appending(path: "Tests/RenderParityFixtures/two-tone.mov"))
    }

    @Test func anUneditedTimelineProducesAnAssetOfTheSameLength() async throws {
        let source = Self.fixture()
        let duration = try await source.load(.duration)
        let nanos = Int64(duration.seconds * 1_000_000_000)
        let cut = try await EditedAsset.make(from: source,
                                             by: EditTimeline.whole(duration: Nanoseconds(nanos)))
        let cutDuration = try await cut.load(.duration)
        #expect(abs(cutDuration.seconds - duration.seconds) < 0.05)
    }

    /// The asset's own timeline IS the edited one, so everything downstream counts in output
    /// time without knowing an edit happened.
    @Test func aCutAssetIsShorterByExactlyWhatWasRemoved() async throws {
        let source = Self.fixture()
        let duration = try await source.load(.duration)
        let nanos = Int64(duration.seconds * 1_000_000_000)
        let edit = EditTimeline.whole(duration: Nanoseconds(nanos))
            .removing(sourceRange: (nanos / 4)..<(nanos * 3 / 4))
        let cut = try await EditedAsset.make(from: source, by: edit)

        let expected = Double(edit.outputDuration.rawValue) / 1_000_000_000
        let actual = try await cut.load(.duration).seconds
        #expect(abs(actual - expected) < 0.05, "cut asset runs \(actual)s, timeline says \(expected)s")
    }

    /// Two clips that abut in the source are one read for an exporter. The unmerged form is
    /// kept in the model so a reviewer's strip can show where a cut was made; this side has no
    /// use for that distinction and must not produce two segments where one will do.
    @Test func abuttingClipsBecomeOneInsertion() async throws {
        let source = Self.fixture()
        let nanos = Int64(try await source.load(.duration).seconds * 1_000_000_000)
        let split = EditTimeline(clips: [
            EditClip(sourceStart: Nanoseconds(0), duration: Nanoseconds(nanos / 2)),
            EditClip(sourceStart: Nanoseconds(nanos / 2), duration: Nanoseconds(nanos - nanos / 2)),
        ])
        let cut = try await EditedAsset.make(from: source, by: split)
        let actual = try await cut.load(.duration).seconds
        #expect(abs(actual - Double(nanos) / 1_000_000_000) < 0.05)
    }

    /// An asset with no video is not something a cut can be made of, and says so rather than
    /// producing an empty composition that fails further downstream.
    @Test func anAssetWithNoVideoTrackIsRefused() async throws {
        let audioOnly = AVMutableComposition()
        _ = audioOnly.addMutableTrack(withMediaType: .audio,
                                      preferredTrackID: kCMPersistentTrackID_Invalid)
        // `do`/`catch` rather than `#expect(throws:)`: the closure would have to RETURN the
        // non-`Sendable` `AVAsset` across an isolation boundary, which Swift 6 refuses. The
        // result is discarded here instead, so nothing crosses.
        do {
            _ = try await EditedAsset.make(from: audioOnly,
                                           by: EditTimeline.whole(duration: Nanoseconds(1_000)))
            Issue.record("a composition with no video track was accepted")
        } catch let error as EditedAssetError {
            #expect(error == .noVideoTrack)
        }
    }

    @Test func theEditedAssetErrorCasesDescribeThemselves() {
        #expect(EditedAssetError.noVideoTrack.description.contains("video track"))
        #expect(EditedAssetError.trackRefused.description.contains("AVMutableComposition"))
    }
}
