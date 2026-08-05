import Foundation
import CoreVideo
import Testing

/// **The source fill, and why it is this colour.**
///
/// `CursorArt` draws a WHITE-filled, BLACK-stroked arrow. A white or near-white source
/// frame makes "find the drawn pointer" fail for a reason that has nothing to do with
/// position — red for the wrong reason, which is the failure mode this whole phase is
/// about. A saturated mid-blue is far from both the fill and the stroke, and far from
/// `StageStyle.default`'s (0.09, 0.09, 0.11) background too, so a differing pixel is
/// attributable.
let sourceFill: (r: UInt8, g: UInt8, b: UInt8) = (32, 96, 224)

/// A 32BGRA buffer of the given size, every pixel set to `fill`.
///
/// 32BGRA because that is what `StageCompositor.sourcePixelBufferAttributes` and
/// `requiredPixelBufferAttributesForRenderContext` both declare; a test that composed
/// in another format would be exercising a path the app never takes.
func makePixelBuffer(width: Int, height: Int,
                     fill: (r: UInt8, g: UInt8, b: UInt8)) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
        &buffer)
    let created = try #require(buffer, "CVPixelBufferCreate failed with status \(status)")

    CVPixelBufferLockBaseAddress(created, [])
    defer { CVPixelBufferUnlockBaseAddress(created, []) }
    let base = try #require(CVPixelBufferGetBaseAddress(created)).assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(created)
    for row in 0..<height {
        for column in 0..<width {
            let offset = row * stride + column * 4
            base[offset + 0] = fill.b
            base[offset + 1] = fill.g
            base[offset + 2] = fill.r
            base[offset + 3] = 255
        }
    }
    return created
}

/// Every pixel of a 32BGRA buffer as `(r, g, b)`, row-major.
func pixels(of buffer: CVPixelBuffer) throws -> [(r: UInt8, g: UInt8, b: UInt8)] {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    var out: [(r: UInt8, g: UInt8, b: UInt8)] = []
    out.reserveCapacity(width * height)
    for row in 0..<height {
        for column in 0..<width {
            let offset = row * stride + column * 4
            out.append((r: base[offset + 2], g: base[offset + 1], b: base[offset + 0]))
        }
    }
    return out
}
