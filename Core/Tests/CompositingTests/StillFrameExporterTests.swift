import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import Testing
@testable import Compositing

/// The frame under the playhead as a PNG, through the real composition stack. In the serialized
/// suite, for `MP4ExporterTests`' reason: the export drives process-global compositor statics.
///
/// The fixture is red for its first second and blue for its second, so "the right frame" and
/// "some frame" read differently — an exporter that always wrote the first frame passes nothing.
extension StageCompositorTests {
    private func resetCompositor() throws {
        unsafe StageCompositor.renderer = try CoreImageFrameRenderer()
        unsafe StageCompositor.style = .default
        unsafe StageCompositor.observationLogURL = nil
        unsafe StageCompositor.overrides = []
        unsafe StageCompositor.editTimeline = nil
    }

    private var twoTone: AVAsset {
        AVURLAsset(url: repositoryRootFromTests.appending(path: "Tests/RenderParityFixtures/two-tone.mov"))
    }

    /// The centre pixel of a PNG, as (red, green, blue) 0…255.
    private func centre(of url: URL) throws -> (r: Int, g: Int, b: Int, width: Int, height: Int) {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.png")
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                                             bytesPerRow: 4, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2,
                                       width: image.width, height: image.height))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]), image.width, image.height)
    }

    @Test func aStillIsTheFrameAtThePlayheadNotTheFirstFrame() async throws {
        try resetCompositor()
        let early = FileManager.default.temporaryDirectory.appendingPathComponent("still-\(UUID()).png")
        let late = FileManager.default.temporaryDirectory.appendingPathComponent("still-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: early); try? FileManager.default.removeItem(at: late) }

        try await StillFrameExporter.export(asset: twoTone, at: CMTime(value: 5, timescale: 10),
                                            to: early, outputWidth: 160, outputHeight: 90)
        try await StillFrameExporter.export(asset: twoTone, at: CMTime(value: 15, timescale: 10),
                                            to: late, outputWidth: 160, outputHeight: 90)
        let red = try centre(of: early), blue = try centre(of: late)
        #expect(red.r > red.b + 80, "0.5 s is in the red second: \(red)")
        #expect(blue.b > blue.r + 80, "1.5 s is in the blue second: \(blue)")
        #expect(red.width == 160 && red.height == 90, "the still is the export's size: \(red)")
    }

    @Test func aTimePastTheEndIsRefusedAndLeavesNoFile() async throws {
        try resetCompositor()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("still-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: StillFrameExporter.ExportError.noFrameAtThatTime) {
            try await StillFrameExporter.export(asset: twoTone, at: CMTime(value: 30, timescale: 10),
                                                to: url, outputWidth: 160, outputHeight: 90)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
