import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import Render
import Testing
@testable import Compositing

/// The frame under the playhead as a PNG, through the real composition stack. In the serialized
/// suite, for `MP4ExporterTests`' reason: the export drives process-global compositor statics.
///
/// The fixture is red for its first second and blue for its second, so "the right frame" and
/// "some frame" read differently — an exporter that always wrote the first frame passes nothing.
extension StageCompositorTests {
    private func resetCompositor() throws {
        StageCompositor.renderer = try CoreImageFrameRenderer()
        StageCompositor.style = .default
        StageCompositor.observationLogURL = nil
        StageCompositor.overrides = []
        StageCompositor.editTimeline = nil
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
        // `unsafe`: a context over a local buffer that outlives every draw into it.
        let context = try #require(unsafe CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
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

/// **A picture annotation reaches the frame, where its box is, and nowhere else.** A 2:1 green
/// picture in a 2:1 box fills it exactly, so the whole box reads green and the frame outside it
/// reads as it did — pixels read back, never a call returning. In the serialized suite because
/// `CoreImageFrameRenderer.imageBaseURL` is process-global.
extension StageCompositorTests {
    private func greenPicture(in base: URL, named name: String) throws {
        let directory = base.appending(path: AnnotationOverlay.imageDirectory, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let width = 40, height = 20
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) { bytes[i + 1] = 220; bytes[i + 3] = 255 }
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        // `unsafe`: a context over a local buffer that outlives every draw into it.
        let context = try #require(unsafe CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let url = directory.appending(path: name)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func aPictureAnnotationIsDrawnInItsBoxAndNowhereElse() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "picture-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base); unsafe CoreImageFrameRenderer.imageBaseURL = nil }
        try greenPicture(in: base, named: "logo.png")
        unsafe CoreImageFrameRenderer.imageBaseURL = base

        let (width, height) = (640, 360)
        func frame(_ annotations: [AnnotationOverlay]) throws -> [(r: UInt8, g: UInt8, b: UInt8)] {
            let source = try makePixelBuffer(width: width, height: height, fill: sourceFill)
            let destination = try makePixelBuffer(width: width, height: height, fill: (0, 0, 0))
            let planned = StagePlanner.plan(outputWidth: width, outputHeight: height,
                                            sourceWidth: width, sourceHeight: height, style: .default)
            let plan = RenderPlan(outputWidth: width, outputHeight: height, card: planned.card,
                                  cornerRadius: planned.cornerRadius, style: planned.style,
                                  pointer: nil, annotations: annotations)
            try CoreImageFrameRenderer().render(plan, source: source, camera: nil, into: destination)
            return try pixels(of: destination)
        }
        func isGreen(_ p: (r: UInt8, g: UInt8, b: UInt8)) -> Bool { p.g > 170 && p.r < 90 && p.b < 90 }
        func at(_ f: [(r: UInt8, g: UInt8, b: UInt8)], _ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
            f[(height - 1 - y) * width + x]   // frames read top-down; the plan's y is bottom-up
        }

        // A 240 × 120 box, 2:1 like the picture.
        let picture = AnnotationOverlay(shape: .image, startX: 200, startY: 120, endX: 440, endY: 240,
                                        style: .default, imageName: "logo.png")
        let drawn = try frame([picture])
        let empty = try frame([])
        #expect(empty.count { isGreen($0) } == 0, "control: nothing green before the picture")
        #expect(isGreen(at(drawn, 320, 180)), "the box's centre shows the picture: \(at(drawn, 320, 180))")
        #expect(isGreen(at(drawn, 205, 125)) && isGreen(at(drawn, 435, 235)), "it fills the box to its corners")
        #expect(!isGreen(at(drawn, 190, 180)) && !isGreen(at(drawn, 320, 250)), "and stops at its edges")

        let missing = AnnotationOverlay(shape: .image, startX: 200, startY: 120, endX: 440, endY: 240,
                                        style: .default, imageName: "not-there.png")
        #expect(try frame([missing]).count { isGreen($0) } == 0, "a missing file draws nothing, and does not throw")
    }
}
