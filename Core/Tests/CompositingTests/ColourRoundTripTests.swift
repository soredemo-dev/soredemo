import Testing
import Foundation
import AVFoundation
import CoreVideo
import Render
@testable import Compositing

/// **The export must hand back the source's pixel values, and this is the instrument that
/// says whether it does.** The chain is tagged Rec.709 at both ends and works in sRGB in
/// the middle (design doc 2026-08-24), and the two share primaries but NOT a transfer
/// curve: a decoder that presents 709-tagged pixels to a Core Image context working in
/// sRGB converts them through 709's curve into sRGB's, and the writer then tags the result
/// 709 again without converting back. Every frame would come out lighter in the mids —
/// mid grey 128 leaves as ~140 — and every tag would still agree with every other tag.
///
/// Measured rather than reasoned: the fixture goes through the REAL exporter with the card
/// covering the whole output (inset 0, no corner), and the centre pixel of the first frame
/// is read back the same way the source's is — an `AVAssetReader` decoding to BGRA — so the
/// two numbers are produced by the same decoder and differ only by what the export did.
extension StageCompositorTests {
    @Test func theExportPreservesTheSourcesPixelValues() async throws {
        StageCompositor.renderer = try CoreImageFrameRenderer()
        unsafe StageCompositor.style = StageStyle(
            insetFraction: 0, cornerRadius: 0, shadowRadius: 0, shadowOpacity: 0,
            background: .solid(red: 0, green: 0, blue: 0))
        StageCompositor.observationLogURL = nil
        StageCompositor.overrides = []
        StageCompositor.editTimeline = nil
        defer { StageCompositor.style = .default }

        let sourceURL = repositoryRootFromTests.appending(path: "Tests/RenderParityFixtures/two-tone.mov")
        let asset = AVURLAsset(url: sourceURL)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let natural = try await track.load(.naturalSize)
        let width = Int(natural.width), height = Int(natural.height)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("colour-round-trip-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        // ProRes 4444 so the comparison is not muddied by 4:2:0 chroma or H.264's quantiser:
        // the question is the transfer curve, and an intra codec at 4:4:4 leaves it alone.
        _ = try await MP4Exporter.export(asset: asset, to: outputURL,
                                         outputWidth: width, outputHeight: height,
                                         frameRate: 10, codec: .proRes4444)

        let before = try await centrePixels(of: sourceURL)
        let after = try await centrePixels(of: outputURL)
        // Two probes: a mid tone, where a transfer-curve mismatch is largest, and whatever
        // the fixture's centre is. Both within the rounding a 4:4:4 intra codec introduces.
        for (b, a) in zip(before, after) {
            #expect(abs(Int(b.r) - Int(a.r)) <= 2 && abs(Int(b.g) - Int(a.g)) <= 2
                    && abs(Int(b.b) - Int(a.b)) <= 2, """
                a source pixel \(b) came back as \(a) — the export changed the picture's \
                values, which is a transfer-curve mismatch between the tags and the working space
                """)
        }
    }
}

/// The first frame's pixels at the centre and at the centre of each quadrant, decoded to
/// BGRA by `AVAssetReader` — the same decoder for the source and the export.
private func centrePixels(of url: URL) async throws -> [(r: UInt8, g: UInt8, b: UInt8)] {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ])
    reader.add(output)
    #expect(reader.startReading())
    let sample = try #require(output.copyNextSampleBuffer())
    let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
    reader.cancelReading()
    let all = try pixels(of: buffer)
    let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
    return [(w / 2, h / 2), (w / 4, h / 4), (3 * w / 4, h / 4), (w / 4, 3 * h / 4), (3 * w / 4, 3 * h / 4)]
        .map { all[$0.1 * w + $0.0] }
}

// MARK: - the mid tones, where a transfer-curve mismatch is largest

/// A synthetic source with known patches — the primaries, two greys and two mixed colours —
/// written tagged 709 the way the master is, exported through the real stack, and read back.
/// The greys are the point: a saturated primary survives a 709↔sRGB curve mismatch almost
/// untouched, and mid grey does not. Measured before the ingest declared sRGB: 128 → 141,
/// 200 → 208. After: within the ±2 an 8-bit video-range YCbCr round trip costs.
extension StageCompositorTests {
    @Test func theMidTonesSurviveTheExport() async throws {
        let patches: [(r: UInt8, g: UInt8, b: UInt8)] = [
            (255, 0, 0), (0, 255, 0), (0, 0, 255), (128, 128, 128), (200, 200, 200),
            (180, 60, 220), (32, 96, 224),
        ]
        let width = 448, height = 64
        StageCompositor.renderer = try CoreImageFrameRenderer()
        unsafe StageCompositor.style = StageStyle(
            insetFraction: 0, cornerRadius: 0, shadowRadius: 0, shadowOpacity: 0,
            background: .solid(red: 0, green: 0, blue: 0))
        StageCompositor.observationLogURL = nil
        StageCompositor.overrides = []
        StageCompositor.editTimeline = nil
        defer { StageCompositor.style = .default }

        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("patches-\(UUID().uuidString).mov")
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("patches-out-\(UUID().uuidString).mov")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputURL)
        }
        try await writePatchSource(patches, to: sourceURL, width: width, height: height)
        // The source itself must hold the patches, or the export is being compared to a
        // fixture that already lost them — the writer's own matrix inference is exactly the
        // failure this guards, so the precondition is asserted rather than assumed.
        let written = try await patchPixels(of: sourceURL, count: patches.count)
        for (want, got) in zip(patches, written) {
            try #require(abs(Int(want.r) - Int(got.r)) <= 2 && abs(Int(want.g) - Int(got.g)) <= 2
                         && abs(Int(want.b) - Int(got.b)) <= 2,
                         "the fixture writer lost a patch: \(want) became \(got)")
        }

        _ = try await MP4Exporter.export(asset: AVURLAsset(url: sourceURL), to: outputURL,
                                         outputWidth: width, outputHeight: height,
                                         frameRate: 10, codec: .proRes4444)
        let exported = try await patchPixels(of: outputURL, count: patches.count)
        for (want, got) in zip(patches, exported) {
            #expect(abs(Int(want.r) - Int(got.r)) <= 2 && abs(Int(want.g) - Int(got.g)) <= 2
                    && abs(Int(want.b) - Int(got.b)) <= 2,
                    "\(want) left the export as \(got)")
        }
    }
}

/// Five frames of vertical bands, one per patch, written ProRes 4444 with the master's own
/// colour properties so the file means what the master means.
private func writePatchSource(_ patches: [(r: UInt8, g: UInt8, b: UInt8)], to url: URL,
                              width: Int, height: Int) async throws {
    let buffer = try makePixelBuffer(width: width, height: height, fill: (0, 0, 0))
    CVPixelBufferLockBaseAddress(buffer, [])
    // Safe here: the base address is valid between the lock/unlock pair, the buffer is
    // 32BGRA four bytes per pixel, and every index stays inside height × bytes-per-row.
    let base = try unsafe #require(unsafe CVPixelBufferGetBaseAddress(buffer))
        .assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let bandWidth = width / patches.count
    for row in 0..<height {
        for column in 0..<width {
            let patch = patches[min(column / bandWidth, patches.count - 1)]
            let offset = row * stride + column * 4
            unsafe base[offset] = patch.b
            unsafe base[offset + 1] = patch.g
            unsafe base[offset + 2] = patch.r
            unsafe base[offset + 3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])

    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.proRes4444,
        AVVideoWidthKey: width, AVVideoHeightKey: height,
        AVVideoColorPropertiesKey: ExportQuality.colourProperties,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ])
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<5 {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed, "the fixture writer failed: \(String(describing: writer.error))")
}

/// The middle row's pixel at the centre of each band of the first frame, decoded to BGRA.
private func patchPixels(of url: URL, count: Int) async throws -> [(r: UInt8, g: UInt8, b: UInt8)] {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ])
    reader.add(output)
    #expect(reader.startReading())
    let sample = try #require(output.copyNextSampleBuffer())
    let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
    reader.cancelReading()
    let all = try pixels(of: buffer)
    let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
    let bandWidth = w / count
    return (0..<count).map { all[(h / 2) * w + $0 * bandWidth + bandWidth / 2] }
}
