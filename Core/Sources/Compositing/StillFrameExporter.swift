import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One composed frame, written as a PNG. See `docs/design/2026-09-27-one-frame-as-a-picture.md`.
public enum StillFrameExporter {
    /// Writes the composed frame at `time` — the asset's own time, which for the editor's cut is
    /// output time — at the given size. Nothing is left at `outputURL` if it fails.
    public nonisolated static func export(asset: AVAsset, at time: CMTime, to outputURL: URL,
                                          outputWidth: Int, outputHeight: Int) async throws {
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw ExportError.noVideoTrack }
        let duration = try await asset.load(.duration)
        guard time >= .zero, time < duration else { throw ExportError.noFrameAtThatTime }

        let composition = try await CompositionBuilder.composition(
            for: asset, outputWidth: outputWidth, outputHeight: outputHeight,
            frameDuration: CMTime(value: 1, timescale: 60))
        let reader = try AVAssetReader(asset: asset)
        // From the playhead to the end: the first frame the composition produces is the one on
        // screen at that moment. A range of one frame's length can come back empty when the
        // playhead sits between two source frames.
        reader.timeRange = CMTimeRange(start: time, end: duration)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.videoComposition = composition
        guard reader.canAdd(output) else { throw ExportError.readerRefusedOutput }
        reader.add(output)
        guard reader.startReading() else {
            throw ExportError.readerFailed(reader.error.map { String(describing: $0) }
                ?? "startReading() returned false")
        }
        defer { reader.cancelReading() }
        guard let buffer = output.copyNextSampleBuffer(),
              let pixels = CMSampleBufferGetImageBuffer(buffer) else {
            throw ExportError.noFrameAtThatTime
        }

        // sRGB in and out, for the GIF path's reason: the composed frame carries the master's
        // 709 tags over sRGB-rendered pixels, and a PNG with no profile is read as sRGB.
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)
        let context = CIContext(options: [.workingColorSpace: sRGB as Any])
        let canvas = HeadlessGeometryBridge.outputCanvas(width: outputWidth, height: outputHeight)
        guard let frame = context.createCGImage(CoreImageFrameRenderer.screenImage(pixels),
                                                from: canvas, format: .RGBA8, colorSpace: sRGB) else {
            throw ExportError.frameRenderFailed
        }
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ExportError.destinationRefused(outputURL.lastPathComponent)
        }
        CGImageDestinationAddImage(destination, frame, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: outputURL)
            throw ExportError.destinationRefused(outputURL.lastPathComponent)
        }
    }

    public nonisolated enum ExportError: Error, Sendable, Equatable {
        case noVideoTrack
        case noFrameAtThatTime
        case readerRefusedOutput
        case readerFailed(String)
        case destinationRefused(String)
        case frameRenderFailed
    }
}
