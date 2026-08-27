import AVFoundation
import CoreVideo
import Foundation
import Framing
import Testing
import Timeline
@testable import Compositing

/// The one motion-framing check that decodes a real file.
///
/// **In `StageCompositorTests`' extension, which is `.serialized`, and that is the project's own
/// answer rather than a new one.** `SmokeTests` and `CameraDodgeCompositorTests` live here for
/// the same reason: they write and read real media, and Swift Testing runs a suite's tests
/// concurrently.
///
/// It was in its own suite first. Alone it took 0.3 seconds; inside `CompositingTests` the whole
/// partition stopped — fourteen seconds became ten minutes, thirty-one unrelated tests never
/// finished, and nothing failed to point at. Marking its own suite `.serialized` did not help,
/// because that serialises within a suite and not against the rest of the process.
extension StageCompositorTests {
    private var motionEpoch: BootEpoch {
        BootEpoch(id: UUID(uuidString: "9A1F3C70-44D2-4E8B-8C05-22AB3D4E5F60")!)
    }

    /// **The one test that decodes.** Everything above is arithmetic; this is the only check
    /// that the reader, the decoder and the grid agree about what a file contains.
    @Test func aRealFileIsReadIntoWellFormedGridsWithChangeWhereItHappened() async throws {
        let directory = URL.temporaryDirectory.appending(path: "soredemo-motion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "tap.mov")

        let width = 64, height = 96, side = 16
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Black for ten frames, then a white square in the bottom-right quarter.
        for frame in 0..<24 {
            // **Bounded.** `isReadyForMoreMediaData` never comes back true once a writer has
            // failed, and `while !ready { await }` is then a hang with nothing to point at.
            var waited = 0
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
                waited += 1
                if waited > 500 {
                    Issue.record("the writer never became ready — status \(writer.status.rawValue)")
                    return
                }
            }
            var pixels: CVPixelBuffer?
            unsafe CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixels)
            guard let pixels else { continue }
            CVPixelBufferLockBaseAddress(pixels, [])
            if let base = unsafe CVPixelBufferGetBaseAddress(pixels) {
                let stride = CVPixelBufferGetBytesPerRow(pixels)
                let bytes = unsafe base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<height {
                    for x in 0..<width {
                        let lit = frame >= 10 && x >= 48 && x < 48 + side
                            && y >= 72 && y < 72 + side
                        let value: UInt8 = lit ? 255 : 0
                        let at = y * stride + x * 4
                        unsafe bytes[at] = value
                        unsafe bytes[at + 1] = value
                        unsafe bytes[at + 2] = value
                        unsafe bytes[at + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime:
                            CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }

        let changes = try await FrameChangeReader.changes(
            from: AVURLAsset(url: url), epoch: motionEpoch, columns: 8, rows: 12)
        try #require(!changes.isEmpty, "nothing was read at all, so this would be vacuous")
        for change in changes {
            #expect(change.columns == 8)
            #expect(change.rows == 12)
            #expect(change.tiles.count == 8 * 12)
            #expect(change.instant.epoch == motionEpoch)
        }
        let event = try #require(changes.max { $0.tiles.reduce(0, +) < $1.tiles.reduce(0, +) })
        let hottest = try #require(event.tiles.indices.max { event.tiles[$0] < event.tiles[$1] })
        #expect(hottest % 8 >= 4,
                "the loudest tile is at column \(hottest % 8), left of the square")
        #expect(hottest / 8 >= 6,
                "the loudest tile is at row \(hottest / 8), above the square")
    }

}
