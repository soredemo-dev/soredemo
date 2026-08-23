import AVFoundation
import Foundation
import Testing
import Render
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
            EditClip(id: ClipID(rawValue: 0), sourceStart: Nanoseconds(0), duration: Nanoseconds(nanos / 2)),
            EditClip(id: ClipID(rawValue: 1), sourceStart: Nanoseconds(nanos / 2), duration: Nanoseconds(nanos - nanos / 2)),
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

/// The camera has to survive the trip from the preview to the file.
extension StageCompositorTests {
    /// **Why the order has to be cut-then-combine, pinned.** `EditedAsset.make` keeps the FIRST
    /// video track and drops the rest, so cutting an asset that already has a camera laid
    /// alongside it deletes the camera. This is the constraint that forced `assetIsAlreadyEdited`
    /// to exist: the exporter cuts what it is given, so a caller who needs a second video track
    /// in the output has to do the cut itself and tell the exporter not to repeat it.
    @MainActor
    @Test func cuttingAnAssetThatAlreadyHasACameraDropsTheCamera() async throws {
        let source = Self.cameraFixture()
        let nanos = Int64(try await source.load(.duration).seconds * 1_000_000_000)
        let edit = EditTimeline.whole(duration: Nanoseconds(nanos))
        let combined = try await CameraComposition.combine(screen: source, cameraURL: source.url)
        #expect(try await combined.asset.loadTracks(withMediaType: .video).count == 2)
        let cutAfterCombining = try await EditedAsset.make(from: combined.asset, by: edit)
        let survivors = try await cutAfterCombining.loadTracks(withMediaType: .video).count
        // If this is 2, the exporter may cut a combined asset and `assetIsAlreadyEdited` is no
        // longer needed for the reason it was added.
        #expect(survivors == 1)
    }

    /// **The camera reaches the exported pixels.** The editor built `cut → combine(camera)` and
    /// played that; the export built a fresh `AVURLAsset` from the recording on disk, which has
    /// one video track. So the self-view showed a face for the whole recording and the export
    /// had none.
    ///
    /// Asserted by rendering the same asset twice — once with a camera style and once without —
    /// and requiring the pictures to differ. A duration check cannot see this: cutting an
    /// already-cut asset by the same edit is a no-op on length and still drops the second track,
    /// so the file would be the right length with the wrong content, which is precisely the
    /// failure that shipped.
    @MainActor
    @Test func theCameraIsInTheExportedPictureAndNotOnlyInThePreview() async throws {
        let source = Self.cameraFixture()
        let nanos = Int64(try await source.load(.duration).seconds * 1_000_000_000)
        let edit = EditTimeline.whole(duration: Nanoseconds(nanos))
        let cut = try await EditedAsset.make(from: source, by: edit)
        let combined = try await CameraComposition.combine(screen: cut, cameraURL: source.url)
        #expect(combined.cameraTrackID != nil)

        unsafe StageCompositor.renderer = try CoreImageFrameRenderer()
        unsafe StageCompositor.style = .default
        unsafe StageCompositor.observationLogURL = nil
        unsafe StageCompositor.overrides = []
        // The compositor is still told the edit — it maps the observation log through it, and
        // the exporter still checks the pairing. Saying "already cut" opts out of the CUT, not
        // out of the check.
        unsafe StageCompositor.editTimeline = edit
        unsafe StageCompositor.cameraTrackID = combined.cameraTrackID
        defer {
            unsafe StageCompositor.editTimeline = nil
            unsafe StageCompositor.cameraTrackID = nil
            unsafe StageCompositor.cameraStyle = nil
        }

        let withCamera = try await Self.exportFirstFrame(
            of: combined.asset, edit: edit, cameraStyle: .default)
        let without = try await Self.exportFirstFrame(
            of: combined.asset, edit: edit, cameraStyle: nil)
        #expect(withCamera != without,
                "the two renders are identical, so the camera track reached no pixel")
    }

    /// **A camera that started late is placed late, and one that started early is trimmed.**
    /// Both files used to be inserted at zero, and this file's own doc comment called that an
    /// approximation. A camera takes hundreds of milliseconds to wake, so the error is usually
    /// the camera being late by more than a frame — visible in a hand wave on an overlay.
    ///
    /// a Rust recorder records a `start_time` per track and aligns everything to whichever began last;
    /// an Electron recorder carries the same number as `timeOffsetMs`. This is that number applied at the
    /// one place a composition is built.
    @MainActor
    @Test func aCameraThatStartedLateIsPlacedLateRatherThanAtZero() async throws {
        let source = Self.cameraFixture()
        let screenDuration = try await source.load(.duration)
        let late = CMTime(value: 500_000_000, timescale: 1_000_000_000)

        let aligned = try await CameraComposition.combine(
            screen: source, cameraURL: source.url, cameraStartOffset: late)
        guard let id = aligned.cameraTrackID,
              let track = try await aligned.asset.loadTracks(withMediaType: .video)
                  .first(where: { $0.trackID == id })
        else { throw CameraParityError.noPixels }
        // **Asserted on the track's SEGMENTS, not its `timeRange`.** Inserting material at 0.5s
        // into an empty composition track leaves an EMPTY edit in front of it, and `timeRange`
        // covers the empty part too — so it reports a start of zero for a camera that correctly
        // begins half a second in. The segment list is where the gap is visible.
        let segments = try await track.load(.segments)
        let firstFilled = segments.first { !$0.isEmpty }
        #expect(segments.first?.isEmpty == true, "no empty leader, so the camera was not delayed")
        let start = firstFilled?.timeMapping.target.start.seconds ?? -1
        #expect(abs(start - 0.5) < 0.01, "camera starts at \(start)s, not 0.5s")
        // And it still ends with the recording rather than running past it.
        let end = firstFilled?.timeMapping.target.end.seconds ?? .infinity
        #expect(end <= screenDuration.seconds + 0.01)
    }

    /// The other direction: a camera that beat the screen has that much of its head cut off,
    /// because those frames are of a recording that had not begun.
    @MainActor
    @Test func aCameraThatStartedFirstHasItsHeadTrimmed() async throws {
        let source = Self.cameraFixture()
        let early = CMTime(value: -400_000_000, timescale: 1_000_000_000)
        let aligned = try await CameraComposition.combine(
            screen: source, cameraURL: source.url, cameraStartOffset: early)
        guard let id = aligned.cameraTrackID,
              let track = try await aligned.asset.loadTracks(withMediaType: .video)
                  .first(where: { $0.trackID == id })
        else { throw CameraParityError.noPixels }
        let segments = try await track.load(.segments)
        guard let filled = segments.first(where: { !$0.isEmpty }) else {
            throw CameraParityError.noPixels
        }
        #expect(abs(filled.timeMapping.target.start.seconds) < 0.01,
                "a trimmed camera still begins at zero")
        #expect(abs(filled.timeMapping.source.start.seconds - 0.4) < 0.01,
                "the trim should read from 0.4s into the camera file")
        let cameraDuration = try await source.load(.duration).seconds
        let kept = filled.timeMapping.target.duration.seconds
        #expect(abs(kept - (cameraDuration - 0.4)) < 0.05,
                "kept \(kept)s of a \(cameraDuration)s camera, expected \(cameraDuration - 0.4)s")
    }

    /// A camera whose whole life is outside the recording is no camera. Reported as `nil` rather
    /// than as a zero-length track the compositor would still be told to draw.
    @MainActor
    @Test func aCameraEntirelyPastTheRecordingIsNoCameraAtAll() async throws {
        let source = Self.cameraFixture()
        let past = try await source.load(.duration) + CMTime(value: 1, timescale: 1)
        let aligned = try await CameraComposition.combine(
            screen: source, cameraURL: source.url, cameraStartOffset: past)
        #expect(aligned.cameraTrackID == nil)
    }

    private static func cameraFixture() -> AVURLAsset {
        AVURLAsset(url: repositoryRootFromTests
            .appending(path: "Tests/RenderParityFixtures/two-tone.mov"))
    }

    /// Exports and returns the first frame's bytes. Small on purpose: this is a comparison, not
    /// a picture anybody looks at, and 160×90 decodes in a fraction of the time.
    @MainActor
    private static func exportFirstFrame(of asset: sending AVAsset, edit: EditTimeline,
                                         cameraStyle: CameraOverlayStyle?) async throws -> Data {
        unsafe StageCompositor.cameraStyle = cameraStyle
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("camera-parity-\(cameraStyle == nil ? "off" : "on").mp4")
        try? FileManager.default.removeItem(at: outputURL)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        _ = try await MP4Exporter.export(
            asset: asset, to: outputURL, outputWidth: 160, outputHeight: 90,
            edit: edit, assetIsAlreadyEdited: true)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: outputURL))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let image = try await generator.image(at: .zero).image
        guard let data = image.dataProvider?.data as Data? else {
            throw CameraParityError.noPixels
        }
        return data
    }

    private enum CameraParityError: Error { case noPixels }
}
