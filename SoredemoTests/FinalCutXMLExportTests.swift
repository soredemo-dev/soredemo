import Testing
import AVFoundation
import CoreGraphics
import Compositing
import Timeline
@testable import Soredemo

/// **What Final Cut XML is told about a file, read from the file** — step 3 of
/// `docs/design/2026-10-23-splitting-the-stage-window.md`. The screen and the camera were read by
/// two copies of the same dozen lines inside `StageWindow`; they are one function now, and it
/// is tested here against a real movie.
@MainActor @Suite struct FinalCutXMLExportTests {
    /// 240×136 for 2 seconds, no audio: none of those is a default anything would fall back to.
    private func movie() async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "fcpxml-source-\(ProcessInfo.processInfo.globallyUniqueString).mov")
        let context = try #require(CGContext(
            data: nil, width: 240, height: 136, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 240, height: 136))
        try await StillMovie.write(try #require(context.makeImage()), seconds: 2, to: url)
        return url
    }

    @Test func aMovieIsDescribedByItsOwnSizeLengthAndSound() async throws {
        let url = try await movie()
        defer { try? FileManager.default.removeItem(at: url) }
        let read = await FinalCutXMLExport.source(for: url, frameRate: 25)
        #expect(read.hasVideo)
        #expect(read.source.width == 240 && read.source.height == 136)
        #expect(abs(Double(read.source.duration.rawValue) / 1e9 - 2) < 0.05)
        #expect(read.source.frameRate == 25)
        #expect(!read.source.hasAudio, "a movie with no audio track was described as having one")
    }

    /// A file with no picture says so, and has no size — which `FinalCutXML` then refuses by
    /// name rather than writing a sequence with a zero dimension.
    @Test func aFileWithNoPictureHasNoSize() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "fcpxml-none-\(ProcessInfo.processInfo.globallyUniqueString).mov")
        let read = await FinalCutXMLExport.source(for: url, frameRate: 30)
        #expect(!read.hasVideo)
        #expect(read.source.width == 0 && read.source.height == 0)
    }

    /// Every refusal has its own sentence; two that read the same could not be told apart.
    @Test func everyRefusalIsSaidDifferently() {
        let refusals: [FinalCutXML.Refusal] = [.theEditKeepsNothing, .theFrameRateIsNotAFrameRate,
                                               .theRecordingHasNoSize]
        let sentences = Set(refusals.map(FinalCutXMLExport.message(for:)))
        #expect(sentences.count == refusals.count)
        #expect(sentences.allSatisfy { !$0.isEmpty })
    }
}
