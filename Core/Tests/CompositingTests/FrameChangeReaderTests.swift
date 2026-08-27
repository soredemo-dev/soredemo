import AVFoundation
import CoreVideo
import Foundation
import Framing
import Testing
import Timeline
@testable import Compositing

/// Reducing a frame to per-tile luminance, and one pass over a real file.
///
/// **Almost everything here is tested against a pixel buffer built in memory, not a movie.** An
/// earlier version wrote five H.264 movies with five `AVAssetWriter`s. Alone it took under a
/// second; inside `CompositingTests`, which is already full of AVFoundation, the whole partition
/// stopped — fourteen seconds became ten minutes, thirty-one unrelated tests never finished, and
/// nothing failed to point at. Serialising the suite did not fix it. Writing one movie instead
/// of five did.
///
/// The lesson is in the shape: the part that needs a decoder is one function, and the rest is
/// arithmetic over an array.
@Suite struct FrameChangeReaderTests {
    private let epoch = BootEpoch(id: UUID(uuidString: "9A1F3C70-44D2-4E8B-8C05-22AB3D4E5F60")!)
    private let columns = 8
    private let rows = 12

    /// A BGRA buffer of exactly `columns × rows`, `bright` where `isBright` says.
    private func buffer(isBright: (Int, Int) -> Bool) -> CVPixelBuffer? {
        var made: CVPixelBuffer?
        // Safe here: `&made` is an out-parameter CoreVideo fills, read only through the binding.
        unsafe CVPixelBufferCreate(nil, columns, rows, kCVPixelFormatType_32BGRA, nil, &made)
        guard let made else { return nil }
        CVPixelBufferLockBaseAddress(made, [])
        defer { CVPixelBufferUnlockBaseAddress(made, []) }
        // Safe here: locked across every write, and each index is bounded by the width, height
        // and bytes-per-row the buffer itself reports.
        guard let base = unsafe CVPixelBufferGetBaseAddress(made) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(made)
        let bytes = unsafe base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<rows {
            for x in 0..<columns {
                let value: UInt8 = isBright(x, y) ? 255 : 0
                let at = y * stride + x * 4
                unsafe bytes[at] = value
                unsafe bytes[at + 1] = value
                unsafe bytes[at + 2] = value
                unsafe bytes[at + 3] = 255
            }
        }
        return made
    }

    // MARK: - the pixel-level rule

    @Test func blackReadsAsZeroAndWhiteAsOne() throws {
        let black = try #require(buffer { _, _ in false })
        let dark = try #require(FrameChangeReader.tiles(of: black, columns: columns, rows: rows))
        #expect(dark.count == columns * rows)
        #expect(dark.allSatisfy { $0 == 0 })

        let white = try #require(buffer { _, _ in true })
        let light = try #require(FrameChangeReader.tiles(of: white, columns: columns, rows: rows))
        #expect(light.allSatisfy { abs($0 - 1) < 1e-9 })
    }

    /// **Row-major, and the index arithmetic is the whole thing.** `MotionActivity` turns an
    /// index into a column and a row with `% columns` and `/ columns`; a reader that filled the
    /// array the other way would put every zoom target on the wrong axis and nothing would say
    /// so — the numbers would all still be in range.
    @Test func theGridIsRowMajorSoATileIsWhereItsIndexSays() throws {
        // One bright pixel at column 5, row 2 — index 2 * 8 + 5 = 21.
        let one = try #require(buffer { x, y in x == 5 && y == 2 })
        let tiles = try #require(FrameChangeReader.tiles(of: one, columns: columns, rows: rows))
        let hottest = try #require(tiles.indices.max { tiles[$0] < tiles[$1] })
        #expect(hottest == 2 * columns + 5, """
            the bright pixel at column 5 row 2 landed at index \(hottest), not \
            \(2 * columns + 5) — the grid is not row-major and every zoom would be on the \
            wrong axis
            """)
    }

    /// A buffer that is not the size asked for is refused rather than read at the wrong stride.
    @Test func aBufferOfTheWrongSizeIsRefused() throws {
        let ok = try #require(buffer { _, _ in true })
        #expect(FrameChangeReader.tiles(of: ok, columns: columns + 1, rows: rows) == nil)
        #expect(FrameChangeReader.tiles(of: ok, columns: columns, rows: rows + 1) == nil)
    }

    /// Rec. 601 luma, not a mean of the channels: green weighs more than red, which weighs more
    /// than blue, because that is what brightness means to an eye.
    @Test func luminanceWeightsTheChannelsRatherThanAveragingThem() throws {
        func single(_ channel: Int) throws -> Double {
            var made: CVPixelBuffer?
            unsafe CVPixelBufferCreate(nil, columns, rows, kCVPixelFormatType_32BGRA, nil, &made)
            let b = try #require(made)
            CVPixelBufferLockBaseAddress(b, [])
            defer { CVPixelBufferUnlockBaseAddress(b, []) }
            // **A `guard`, not `#require`.** The macro expands into generated code that touches
            // its argument again, and `UnsafeMutableRawPointer` is an unsafe type — so the
            // expansion carries an unsafe expression that nothing in this file can mark. The
            // gate reads the expansion, not the source. Marking it here is the only way to say
            // why it is safe: the buffer is locked across every write below, and each index is
            // bounded by the width, height and bytes-per-row the buffer itself reports.
            guard let base = unsafe CVPixelBufferGetBaseAddress(b) else {
                Issue.record("CoreVideo gave a buffer with no base address")
                return 0
            }
            let stride = CVPixelBufferGetBytesPerRow(b)
            let bytes = unsafe base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<rows {
                for x in 0..<columns {
                    let at = y * stride + x * 4
                    for c in 0..<3 { unsafe bytes[at + c] = c == channel ? 255 : 0 }
                    unsafe bytes[at + 3] = 255
                }
            }
            return try #require(FrameChangeReader.tiles(of: b, columns: columns, rows: rows)).first ?? 0
        }
        let blue = try single(0), green = try single(1), red = try single(2)
        #expect(green > red && red > blue, """
            channel weights are green \(green), red \(red), blue \(blue) — not Rec. 601
            """)
        #expect(abs(green - 0.587) < 0.001)
    }

    /// A recording with no video is refused by name. An audio-only file reaching this is
    /// ordinary — somebody imports one — and a `nil` would look like "no taps found".
    @Test func aFileWithNoVideoIsRefusedByName() async throws {
        let directory = URL.temporaryDirectory.appending(path: "soredemo-motion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "audio.caf")
        try AudioSamples.write(
            AudioSamples.Track(samples: [Float](repeating: 0.1, count: 48_000),
                               sampleRate: 48_000),
            to: url)
        await #expect(throws: FrameChangeReader.ReadError.noVideoTrack) {
            _ = try await FrameChangeReader.changes(from: AVURLAsset(url: url), epoch: epoch)
        }
    }
}
