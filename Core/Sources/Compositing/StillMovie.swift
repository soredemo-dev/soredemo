import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

/// One picture written as a short still movie, so a screenshot opens in the editor a recording
/// opens in — the stage, the crop, redaction and every annotation, drawn by the same renderer.
/// See `docs/design/2026-09-30-a-screenshot-is-a-one-frame-take.md`.
///
/// **ProRes 4444, not the master's H.264.** A screenshot is mostly text: 4:2:0 halves the colour
/// resolution and blurs a one-pixel red stroke on blue into purple, which is the picture a person
/// took a screenshot of. The colour tags are the master's, BT.709, and the picture is drawn into
/// sRGB on the way in — the working space the renderer declares its input to be.
public enum StillMovie {
    public enum Failure: Error, Equatable {
        case writerRefused(String)
        case noPixelBuffer
    }

    /// Writes `image` held for `seconds` at `url`, which must not exist.
    public static func write(_ image: CGImage, seconds: Double, to url: URL) async throws {
        let width = image.width, height = image.height
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes4444,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                           sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw Failure.writerRefused("canAdd(_:) refused the video input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw Failure.writerRefused(writer.error.map(String.init(describing:)) ?? "startWriting() returned false")
        }
        writer.startSession(atSourceTime: .zero)

        let buffer = try pixelBuffer(of: image)
        // **One sample, held to the end by `endSession`.** Measured by
        // `aScreenshotBecomesAMovieOfItsOwnSizeAndLength`: a single sample at zero with the session
        // ended at 4 s loads as 4 s. A second copy at the end was written first, on the belief
        // that one sample would be zero long; the mutation that removed it survived, and the
        // belief went with it.
        let end = CMTime(seconds: seconds, preferredTimescale: 600)
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        guard adaptor.append(buffer, withPresentationTime: .zero) else {
            throw Failure.writerRefused(writer.error.map(String.init(describing:)) ?? "append refused")
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw Failure.writerRefused(writer.error.map(String.init(describing:)) ?? "finishWriting did not complete")
        }
    }

    /// The picture drawn into a BGRA buffer in sRGB.
    private static func pixelBuffer(of image: CGImage) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let status = unsafe CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height,
                                                kCVPixelFormatType_32BGRA,
                                                [kCVPixelBufferCGImageCompatibilityKey: true,
                                                 kCVPixelBufferCGBitmapContextCompatibilityKey: true]
                                                    as CFDictionary, &created)
        guard status == kCVReturnSuccess, let buffer = created else { throw Failure.noPixelBuffer }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        // `unsafe`: the base address is used only between the lock and the unlock above, and the
        // context is told the buffer's own width, height and stride, so nothing writes past it.
        guard let context = unsafe CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw Failure.noPixelBuffer }
        context.draw(image, in: HeadlessGeometryBridge.rect(x: 0, y: 0, width: Double(image.width),
                                                            height: Double(image.height)))
        return buffer
    }
}
