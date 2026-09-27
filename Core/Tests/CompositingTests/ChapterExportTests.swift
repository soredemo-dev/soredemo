import Testing
import Foundation
import AVFoundation
import CoreMedia
import Overlays
import Timeline
@testable import Compositing

/// Extends the serialized `StageCompositorTests` for `MP4ExporterTests`' reason: a real export
/// drives the compositor's process-global statics.
extension StageCompositorTests {
    private func exportTwoTone(chapters: [PlacedChapter], as codec: ExportCodec = .h264,
                               fixture: String = "two-tone.mov")
    async throws -> (URL, ExportReport) {
        unsafe StageCompositor.renderer = try CoreImageFrameRenderer()
        unsafe StageCompositor.style = .default
        unsafe StageCompositor.observationLogURL = nil
        unsafe StageCompositor.overrides = []
        unsafe StageCompositor.editTimeline = nil
        let asset = AVURLAsset(url: repositoryRootFromTests
            .appending(path: "Tests/RenderParityFixtures/\(fixture)"))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chapters-\(UUID().uuidString).\(codec == .h264 ? "mp4" : "mov")")
        let report = try await MP4Exporter.export(asset: asset, to: url, outputWidth: 160,
                                                  outputHeight: 90, codec: codec, chapters: chapters)
        return (url, report)
    }

    private static let threeChapters = [
        PlacedChapter(id: 0, name: "Install", start: Nanoseconds(0), duration: Nanoseconds(500_000_000)),
        PlacedChapter(id: 1, name: "錄影 ✓", start: Nanoseconds(500_000_000), duration: Nanoseconds(700_000_000)),
        PlacedChapter(id: 2, name: "Export", start: Nanoseconds(1_200_000_000), duration: Nanoseconds(800_000_000)),
    ]

    /// Read back through AVFoundation, asking for the language they are written under. The
    /// 2026-09-27 measurement also read them with ffprobe; this test is the half that runs
    /// without a tool nobody promised is installed.
    @Test func chaptersArriveInTheExportedFileWithTheirTitlesAndTimes() async throws {
        let (url, report) = try await exportTwoTone(chapters: Self.threeChapters)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(report.chaptersWritten == 3)
        let asset = AVURLAsset(url: url)
        let groups = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: ["und"])
        try #require(groups.count == 3, "read back \(groups.count) chapters")
        var titles: [String] = []
        for group in groups { titles.append(try await group.items.first?.load(.stringValue) ?? "") }
        #expect(titles == ["Install", "錄影 ✓", "Export"])
        #expect(groups.map { ($0.timeRange.start.seconds * 1000).rounded() } == [0, 500, 1200])
        // Not drawn as a subtitle: the chapter track is present and disabled.
        let text = try await asset.loadTracks(withMediaType: .text)
        #expect(text.count == 1)
        #expect(try await text.first?.load(.isEnabled) == false)
    }

    /// **Ten seconds, with audio, because two would prove nothing about interleaving.** The
    /// writer holds an input that runs ~2 s ahead of its siblings (`MP4Exporter`'s own
    /// measurement), and `two-tone.mov` is 2 s long — every chapter fits in that window whether
    /// or not the exporter waits for the frames to reach it.
    @Test func chaptersAcrossALongRecordingWithAudioAreAllWritten() async throws {
        let seconds: [Int64] = [0, 3_300, 7_100, 9_400]
        let chapters = seconds.enumerated().map { index, ms in
            let end = index + 1 < seconds.count ? seconds[index + 1] : 10_000
            return PlacedChapter(id: index, name: "Part \(index + 1)", start: Nanoseconds(ms * 1_000_000),
                                 duration: Nanoseconds((end - ms) * 1_000_000))
        }
        let (url, report) = try await exportTwoTone(chapters: chapters, fixture: "long-two-track-audio.mov")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(report.chaptersWritten == 4)
        #expect(report.audioSamplesWritten > 0, "the fixture must exercise the audio input too")
        let groups = try await AVURLAsset(url: url)
            .loadChapterMetadataGroups(bestMatchingPreferredLanguages: ["und"])
        #expect(groups.map { Int64(($0.timeRange.start.seconds * 1000).rounded()) } == seconds)
    }

    @Test func aQuickTimeExportCarriesChaptersToo() async throws {
        let (url, report) = try await exportTwoTone(chapters: Self.threeChapters, as: .proRes)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(report.chaptersWritten == 3)
        let groups = try await AVURLAsset(url: url)
            .loadChapterMetadataGroups(bestMatchingPreferredLanguages: ["und"])
        #expect(groups.count == 3)
    }

    @Test func anExportWithoutChaptersHasNoChapterTrack() async throws {
        let (url, report) = try await exportTwoTone(chapters: [])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(report.chaptersWritten == 0)
        #expect(try await AVURLAsset(url: url).loadTracks(withMediaType: .text).isEmpty)
    }

    /// A list the writer cannot honour is refused before anything is written, rather than
    /// written with a chapter silently missing.
    @Test(arguments: [
        ("out of order", [PlacedChapter(id: 0, name: "B", start: Nanoseconds(900_000_000), duration: Nanoseconds(500_000_000)),
                          PlacedChapter(id: 1, name: "A", start: Nanoseconds(0), duration: Nanoseconds(500_000_000))]),
        ("lasts no time", [PlacedChapter(id: 0, name: "Zero", start: Nanoseconds(0), duration: Nanoseconds(0))]),
        ("after the last frame", [PlacedChapter(id: 0, name: "Late", start: Nanoseconds(5_000_000_000),
                                                duration: Nanoseconds(1_000_000_000))]),
    ])
    func chaptersTheWriterCannotHonourAreRefusedByName(_ label: String, _ chapters: [PlacedChapter]) async throws {
        // The SPECIFIC case: any `ExportError` would also be thrown by a broken fixture.
        do {
            let (url, _) = try await exportTwoTone(chapters: chapters)
            try? FileManager.default.removeItem(at: url)
            Issue.record("\(label): exported")
        } catch MP4Exporter.ExportError.chaptersUnwritable {
        } catch {
            Issue.record("\(label): refused for another reason: \(error)")
        }
    }
}
