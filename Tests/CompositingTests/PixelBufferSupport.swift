import Foundation
import CoreVideo
import Testing

/// Saturated mid-blue on purpose: the arrow is white-filled and black-stroked and the stage
/// background is near-black, so this is far from all three and a differing pixel is attributable.
let sourceFill: (r: UInt8, g: UInt8, b: UInt8) = (32, 96, 224)

/// A 32BGRA buffer of the given size, every pixel set to `fill`. 32BGRA because that is what
/// `StageCompositor`'s own pixel-buffer attributes declare; another format is a path the app
/// never takes.
func makePixelBuffer(width: Int, height: Int,
                     fill: (r: UInt8, g: UInt8, b: UInt8)) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    // Safe here: `&buffer` outlives the call by scope, and CoreVideo writes it only
    // before returning.
    let status = unsafe CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
        &buffer)
    let created = try #require(buffer, "CVPixelBufferCreate failed with status \(status)")

    CVPixelBufferLockBaseAddress(created, [])
    defer { CVPixelBufferUnlockBaseAddress(created, []) }
    // Safe here: the base address is valid between the lock/unlock pair above, the
    // buffer was created 32BGRA four bytes per pixel two lines up, and every index
    // below stays inside height × bytes-per-row by construction of the loop bounds.
    let base = try unsafe #require(unsafe CVPixelBufferGetBaseAddress(created))
        .assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(created)
    for row in 0..<height {
        for column in 0..<width {
            let offset = row * stride + column * 4
            unsafe base[offset + 0] = fill.b
            unsafe base[offset + 1] = fill.g
            unsafe base[offset + 2] = fill.r
            unsafe base[offset + 3] = 255
        }
    }
    return created
}

/// Every pixel of a 32BGRA buffer as `(r, g, b)`, row-major.
func pixels(of buffer: CVPixelBuffer) throws -> [(r: UInt8, g: UInt8, b: UInt8)] {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    // Safe here: same argument as `makePixelBuffer` — reads happen between the
    // lock/unlock pair, and the loop bounds come from the buffer's own dimensions,
    // so every offset stays inside height × bytes-per-row.
    let base = try unsafe #require(unsafe CVPixelBufferGetBaseAddress(buffer))
        .assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    var out: [(r: UInt8, g: UInt8, b: UInt8)] = []
    out.reserveCapacity(width * height)
    for row in 0..<height {
        for column in 0..<width {
            let offset = row * stride + column * 4
            unsafe out.append((r: base[offset + 2], g: base[offset + 1], b: base[offset + 0]))
        }
    }
    return out
}

/// Paints the lower-left quadrant of a 32BGRA buffer, for tests that need a source with a
/// countable feature in a known place. Bottom-left in CoreVideo's top-left row order means
/// the LAST rows.
func paintQuadrant(_ buffer: CVPixelBuffer, width: Int, height: Int,
                   colour: (r: UInt8, g: UInt8, b: UInt8)) throws {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    // Safe here: same argument as `makePixelBuffer` — the writes sit between the lock pair
    // and every index stays inside height × bytes-per-row.
    let base = try unsafe #require(unsafe CVPixelBufferGetBaseAddress(buffer))
        .assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    for row in (height / 2)..<height {
        for column in 0..<(width / 2) {
            let offset = row * stride + column * 4
            unsafe base[offset + 0] = colour.b
            unsafe base[offset + 1] = colour.g
            unsafe base[offset + 2] = colour.r
            unsafe base[offset + 3] = 255
        }
    }
}
