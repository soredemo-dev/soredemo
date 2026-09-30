import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import Compositing

/// **A screenshot becomes a short still movie the editor can open** — see
/// `docs/design/2026-09-30-a-screenshot-is-a-one-frame-take.md`. What matters is that the picture
/// survives: a screenshot is mostly text, and a codec that blurs one-pixel strokes or halves the
/// colour resolution loses exactly what was being shown.
@Suite struct StillMovieTests {
    /// Not a multiple of 16 in either direction, so a writer that rounded the frame to a codec's
    /// block size would change the picture's size and fail below.
    private let width = 642
    private let height = 362

    /// A picture that punishes the wrong codec: one-pixel black and white columns (blurred by any
    /// lossy low-pass), and one-pixel red columns on blue (averaged away by 4:2:0 chroma).
    private func pattern() throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for x in 0..<width {
            let top: (CGFloat, CGFloat, CGFloat) = x % 2 == 0 ? (0, 0, 0) : (1, 1, 1)
            let bottom: (CGFloat, CGFloat, CGFloat) = x % 2 == 0 ? (1, 0, 0) : (0.12, 0.38, 0.88)
            context.setFillColor(red: top.0, green: top.1, blue: top.2, alpha: 1)
            context.fill(CGRect(x: x, y: height / 2, width: 1, height: height - height / 2))
            context.setFillColor(red: bottom.0, green: bottom.1, blue: bottom.2, alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: 1, height: height / 2))
        }
        return try #require(context.makeImage())
    }

    private func written() async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "still-movie-\(ProcessInfo.processInfo.globallyUniqueString).mov")
        try await StillMovie.write(try pattern(), seconds: 4, to: url)
        return url
    }

    @Test func aScreenshotBecomesAMovieOfItsOwnSizeAndLength() async throws {
        let url = try await written()
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(Int(size.width) == width && Int(size.height) == height)
        let seconds = try await asset.load(.duration).seconds
        #expect(abs(seconds - 4) < 0.05, "a 4-second still came out \(seconds) s long")
    }

    @Test func theFirstFrameIsThePicture() async throws {
        let url = try await written()
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        #expect(reader.startReading())
        let sample = try #require(output.copyNextSampleBuffer())
        let frame = try pixels(of: try #require(CMSampleBufferGetImageBuffer(sample)))
        reader.cancelReading()

        // Frames are read top-down; the picture was drawn bottom-up, so the top half is the
        // black-and-white columns and the bottom half the red-on-blue ones.
        let upper = height / 4, lower = 3 * height / 4
        var worst = 0
        for x in 0..<width {
            let bw = frame[upper * width + x]
            let expectedBW: Int = x % 2 == 0 ? 0 : 255
            worst = max(worst, abs(Int(bw.r) - expectedBW), abs(Int(bw.g) - expectedBW), abs(Int(bw.b) - expectedBW))
            let rb = frame[lower * width + x]
            let expectedRB: (Int, Int, Int) = x % 2 == 0 ? (255, 0, 0) : (31, 97, 224)
            worst = max(worst, abs(Int(rb.r) - expectedRB.0), abs(Int(rb.g) - expectedRB.1),
                        abs(Int(rb.b) - expectedRB.2))
        }
        #expect(worst <= StillMovieTests.tolerance, "one-pixel detail came back \(worst) away from the picture")
    }

    /// A folder that is not there is a refusal with the writer's reason, not a crash and not a
    /// file half-written somewhere else.
    @Test func aPlaceThatCannotBeWrittenIsRefusedWithItsReason() async throws {
        let nowhere = FileManager.default.temporaryDirectory
            .appending(path: "no-such-folder-\(ProcessInfo.processInfo.globallyUniqueString)")
            .appending(path: "still.mov")
        await #expect {
            try await StillMovie.write(try pattern(), seconds: 1, to: nowhere)
        } throws: { error in
            guard case StillMovie.Failure.writerRefused(let reason) = error else { return false }
            return !reason.isEmpty
        }
        #expect(!FileManager.default.fileExists(atPath: nowhere.path))
    }

    /// **Measured, then set**: ProRes 4444 came back at most 1 away on every channel of this
    /// pattern (2026-09-30). 2 is the ±2 an 8-bit round trip is allowed elsewhere
    /// (`theMidTonesSurviveTheExport`); the master's H.264 blurs these columns by far more.
    static let tolerance = 2
}
