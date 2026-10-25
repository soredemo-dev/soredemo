import Testing
import Foundation
import AVFoundation
import CoreMedia
@testable import Compositing

/// **Where an export's time goes, measured rather than guessed.** Not a check: it runs only when
/// `SOREDEMO_MEASURE_EXPORT` names a source movie (`scripts/measure-export.sh` makes two and sets
/// it), and otherwise passes having done nothing. It times three passes over the same source —
/// decode alone, decode and the stage's composite, decode and the encode with no composite (fed
/// BGRA as the export feeds it, and fed the encoder's own 4:2:0), and the whole export — so the
/// difference between passes prices a stage. Each pass runs three times; the minimum and the
/// median are printed, so the spread is visible beside the number.
/// `docs/design/2026-10-25-the-next-round.md`.
extension StageCompositorTests {
    @Test func exportSpeedBreakdown() async throws {
        guard let path = ProcessInfo.processInfo.environment["SOREDEMO_MEASURE_EXPORT"] else { return }
        let source = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: source)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        let frameRate = 60

        unsafe StageCompositor.renderer = try CoreImageFrameRenderer()
        unsafe StageCompositor.style = .default
        unsafe StageCompositor.observationLogURL = nil
        unsafe StageCompositor.overrides = []
        unsafe StageCompositor.editTimeline = nil

        let clock = ContinuousClock()
        let bgra: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]

        func drain(_ output: AVAssetReaderOutput, from reader: AVAssetReader) throws -> Int {
            reader.add(output)
            #expect(reader.startReading())
            var frames = 0
            while let buffer = output.copyNextSampleBuffer() {
                if CMSampleBufferGetImageBuffer(buffer) != nil { frames += 1 }
            }
            try #require(reader.status == .completed, "reader ended \(reader.status.rawValue): \(String(describing: reader.error))")
            return frames
        }

        func seconds(_ d: Duration) -> Double {
            Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
        /// Three runs of one pass; each must produce frames, and every run the same number.
        func thrice(_ name: String, _ pass: () async throws -> Int) async throws -> String {
            var times: [Double] = [], counts: Set<Int> = []
            for _ in 0..<3 {
                var frames = 0
                let elapsed = try await clock.measure { frames = try await pass() }
                times.append(seconds(elapsed)); counts.insert(frames)
            }
            // **A count of nothing is not a speed**, and runs that disagree are not one number.
            try #require(counts.count == 1 && counts.first! > 0, "\(name): frames per run \(counts)")
            let frames = Double(counts.first!)
            times.sort()
            func fixed(_ value: Double, _ places: Int, width: Int) -> String {
                let text = value.formatted(.number.precision(.fractionLength(places)).grouping(.never))
                return String(repeating: " ", count: max(0, width - text.count)) + text
            }
            return "  " + name.padding(toLength: 26, withPad: " ", startingAt: 0)
                + "\(Int(frames)) frames  \(fixed(times[1] * 1000 / frames, 2, width: 6)) ms/frame"
                + " (min \(fixed(times[0] * 1000 / frames, 2, width: 6)))  \(fixed(frames / times[1], 1, width: 6)) fps"
        }

        func drain(_ output: AVAssetReaderOutput, from reader: AVAssetReader,
                   into input: AVAssetWriterInput? = nil) throws -> Int {
            reader.add(output)
            #expect(reader.startReading())
            var frames = 0
            while let buffer = output.copyNextSampleBuffer() {
                guard CMSampleBufferGetImageBuffer(buffer) != nil else { continue }
                if let input {
                    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.0005) }
                    try #require(input.append(buffer), "the writer refused frame \(frames)")
                }
                frames += 1
            }
            try #require(reader.status == .completed, "reader ended \(reader.status.rawValue): \(String(describing: reader.error))")
            return frames
        }

        /// Decode and encode, no composite: the source's frames straight into the export's encoder.
        func encodeOnly(pixelFormat: OSType) async throws -> Int {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("measure-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: out) }
            let writer = try AVAssetWriter(url: out, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: ExportQuality.best.videoSettings(
                outputWidth: width, outputHeight: height, frameRate: frameRate, codec: .h264))
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            #expect(writer.startWriting())
            writer.startSession(atSourceTime: .zero)
            let frames = try drain(AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]),
                from: try AVAssetReader(asset: asset), into: input)
            input.markAsFinished()
            await writer.finishWriting()
            try #require(writer.status == .completed, "writer: \(String(describing: writer.error))")
            return frames
        }

        let composition = try await CompositionBuilder.composition(
            for: asset, outputWidth: width, outputHeight: height,
            frameDuration: CMTime(value: 1, timescale: CMTimeScale(frameRate)))
        let videoTracks = try await asset.loadTracks(withMediaType: .video)

        var lines = ["EXPORT SPEED — \(source.lastPathComponent), \(width)×\(height), output \(frameRate) fps"]
        lines.append(try await thrice("decode") {
            try drain(AVAssetReaderTrackOutput(track: track, outputSettings: bgra), from: try AVAssetReader(asset: asset))
        })
        lines.append(try await thrice("decode + composite") {
            let output = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: bgra)
            output.videoComposition = composition
            return try drain(output, from: try AVAssetReader(asset: asset))
        })
        lines.append(try await thrice("decode + encode, BGRA") {
            try await encodeOnly(pixelFormat: kCVPixelFormatType_32BGRA)
        })
        lines.append(try await thrice("decode + encode, 4:2:0") {
            try await encodeOnly(pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        })
        for codec in [ExportCodec.h264, .hevc, .proRes] {
            lines.append(try await thrice("export, \(codec.displayName)") {
                let out = FileManager.default.temporaryDirectory
                    .appendingPathComponent("measure-\(UUID().uuidString).\(codec.fileExtension)")
                defer { try? FileManager.default.removeItem(at: out) }
                return try await MP4Exporter.export(asset: asset, to: out, outputWidth: width,
                                                    outputHeight: height, frameRate: frameRate,
                                                    codec: codec).framesWritten
            })
        }
        print(lines.joined(separator: "\n"))
    }
}
