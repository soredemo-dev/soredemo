import Testing
import Foundation
import AVFoundation
import CoreMedia
import ImageIO
import Timeline
@testable import Compositing

/// The settings arithmetic, which is pure and does not need an asset.
@Suite struct GIFSettingsTests {
    /// **The claim this whole design rests on.** If a rate on `exactRates` did not survive the
    /// centisecond grid, `isExact` would be decoration.
    @Test func everyRateOnTheExactListPlaysBackAtTheRateItAsksFor() {
        for rate in GIFSettings.exactRates {
            let settings = GIFSettings(frameRate: rate)
            #expect(settings.playbackRate == Double(rate),
                    "\(rate) fps became \(settings.playbackRate)")
            #expect(settings.isExact)
        }
    }

    /// The two rates most recorders default to, measured. This is the finding the header
    /// cites, so it is checked rather than asserted in prose.
    @Test func theRatesTheOtherRecordersDefaultToDoNotSurviveTheFormatsGrid() {
        // 15 fps is 6.67 cs, written as 7.
        let fifteen = GIFSettings(frameRate: 15)
        #expect(fifteen.delayCentiseconds == 7)
        #expect(!fifteen.isExact)
        #expect(abs(fifteen.playbackRate - 14.2857) < 0.001)

        // 30 fps is 3.33 cs, written as 3 — which plays FASTER than asked.
        let cap = GIFSettings(frameRate: 30)
        #expect(cap.delayCentiseconds == 3)
        #expect(cap.playbackRate > 30)
        #expect(abs(cap.playbackRate - 33.3333) < 0.001)
    }

    /// A rate whose delay would round below the browsers' floor is clamped there, so asking for
    /// 100 fps produces a 50 fps GIF rather than a 10 fps one.
    @Test func aRateAboveTheFormatsFloorIsClampedRatherThanWrappingToTenFramesASecond() {
        #expect(GIFSettings(frameRate: 100).delayCentiseconds == 2)
        #expect(GIFSettings(frameRate: 1000).playbackRate == 50)
    }

    /// The sampling interval equals the playback interval — the repair the header claims.
    @Test func theSamplingIntervalIsTheIntervalTheFileWillPlayAt() {
        for rate in [10, 15, 20, 24, 25, 30, 50] {
            let settings = GIFSettings(frameRate: rate)
            #expect(settings.frameDuration.seconds == settings.delaySeconds,
                    "\(rate) fps samples at \(settings.frameDuration.seconds) and plays at \(settings.delaySeconds)")
        }
    }

    @Test func sizeFitsTheLongestEdgeInEitherOrientationAndNeverEnlarges() {
        let settings = GIFSettings(maximumLongestEdge: 640)
        let landscape = settings.size(fitting: 1920, height: 1080)
        #expect(landscape.width == 640)
        #expect(landscape.height == 360)

        // Portrait constrains on HEIGHT, which is why this is a longest-edge fit and not a
        // maximum width — a 1080×1920 recording fitted on width would be 1138 tall.
        let portrait = settings.size(fitting: 1080, height: 1920)
        #expect(portrait.height == 640)
        #expect(portrait.width == 360)

        let small = settings.size(fitting: 320, height: 200)
        #expect(small == (320, 200))
    }

    @Test func everyProducedSizeIsEvenOnBothEdges() {
        let settings = GIFSettings(maximumLongestEdge: 501)
        for (width, height) in [(1920, 1080), (1001, 667), (333, 999), (7, 3)] {
            let size = settings.size(fitting: width, height: height)
            #expect(size.width % 2 == 0, "\(width)x\(height) gave width \(size.width)")
            #expect(size.height % 2 == 0, "\(width)x\(height) gave height \(size.height)")
        }
    }

    /// The report's two derived numbers, which are what a UI shows after an export and what a
    /// person compares against the recording they just made.
    @Test func theReportsLengthAndRateComeFromTheDelayItActuallyWrote() {
        let report = GIFReport(outputURL: URL(fileURLWithPath: "/tmp/a.gif"), framesWritten: 45,
                               width: 640, height: 360, delayCentiseconds: 4)
        #expect(report.playbackRate == 25)
        #expect(abs(report.seconds - 1.8) < 0.0001)

        // The report carries the delay rather than the asked-for rate on purpose: a 30 fps
        // request writes 3 cs, and a report echoing "30" would be telling a person their GIF is
        // the length it is not.
        let asked = GIFSettings(frameRate: 30)
        let drifted = GIFReport(outputURL: URL(fileURLWithPath: "/tmp/b.gif"), framesWritten: 100,
                                width: 640, height: 360,
                                delayCentiseconds: asked.delayCentiseconds)
        #expect(drifted.playbackRate != Double(asked.frameRate))
        #expect(drifted.seconds == 3)
    }

    @Test func loopingIsZeroAndNotLoopingIsOnePass() {
        #expect(GIFSettings(loops: true).loopCount == 0)
        #expect(GIFSettings(loops: false).loopCount == 1)
    }

    @Test func theExportErrorCasesDescribeThemselves() {
        let cases: [GIFExporter.ExportError] = [
            .emptyTrim, .editTimelineMismatch, .noVideoTrack, .readerRefusedOutput,
            .readerFailed("why"), .destinationRefused("a.gif"), .frameRenderFailed(3),
            .noFrames, .finalizeFailed,
        ]
        // Distinct as well as non-empty: two cases sharing a description would make a failure
        // report name the wrong cause.
        #expect(Set(cases.map(\.description)).count == cases.count)
        for error in cases { #expect(!error.description.isEmpty) }
    }
}

/// A real GIF written through the real composition stack. Extends the serialized suite for the
/// reason `MP4ExporterTests` gives: the export drives process-global `StageCompositor` statics.
extension StageCompositorTests {
    @Test func aRealExportWritesAGIFWhoseFramesAndDelayAreWhatTheSettingsAskedFor() async throws {
        StageCompositor.renderer = try CoreImageFrameRenderer()
        StageCompositor.style = .default
        StageCompositor.observationLogURL = nil
        StageCompositor.overrides = []
        StageCompositor.editTimeline = nil

        let asset = AVURLAsset(url: repositoryRootFromTests
            .appending(path: "Tests/RenderParityFixtures/two-tone.mov"))
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gifexporter-test-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let settings = GIFSettings(frameRate: 10, loops: true, maximumLongestEdge: 80)
        let report = try await GIFExporter.export(
            asset: asset, to: outputURL, outputWidth: 160, outputHeight: 90, settings: settings)

        #expect(report.framesWritten > 0)
        #expect(report.width == 80)
        #expect(report.height == 44)
        #expect(report.delayCentiseconds == 10)

        // Read the file back rather than trusting the report: the report is what we intended,
        // the file is what a person will open.
        let source = try #require(CGImageSourceCreateWithURL(outputURL as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == report.framesWritten)

        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let gif = try #require(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        let delay = try #require(gif[kCGImagePropertyGIFDelayTime] as? Double)
        #expect(abs(delay - 0.1) < 0.0001, "the file says \(delay)s per frame")

        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 80)
        #expect(image.height == 44)
    }

    /// An edit the compositor has not been told about is refused rather than exported with every
    /// cursor and zoom off by the difference — the MP4 path's check, on this path too.
    @Test func aGIFExportRefusesAnEditTheCompositorIsNotSetTo() async throws {
        StageCompositor.editTimeline = nil
        let asset = AVURLAsset(url: repositoryRootFromTests
            .appending(path: "Tests/RenderParityFixtures/two-tone.mov"))
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gifexporter-mismatch-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let edit = EditTimeline(clips: [EditClip(id: ClipID(rawValue: 0), sourceStart: Nanoseconds(0),
                                              duration: Nanoseconds(1_000_000_000))])
        await #expect(throws: GIFExporter.ExportError.editTimelineMismatch) {
            try await GIFExporter.export(asset: asset, to: outputURL,
                                         outputWidth: 160, outputHeight: 90, edit: edit)
        }
        #expect(!FileManager.default.fileExists(atPath: outputURL.path))
    }
}
