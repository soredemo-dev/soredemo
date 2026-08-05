// Regenerates the committed `two-tone.mov` fixture: 64×64 ProRes4444, 10 fps, 2 seconds,
// first second solid red and second solid blue, so a parity check can tell "the right
// frame was read" from "any plausible frame was read". Colour tags are pinned to
// ITU_R_709_2 because an untagged AVAssetWriter/AVAssetReader round trip shifts colour.
//
// Not a SwiftPM target; run it directly:
//
//     unset SDKROOT
//     xcrun swift Tests/RenderParityFixtures/generate-fixture.swift Tests/RenderParityFixtures/two-tone.mov
import AVFoundation
import CoreVideo
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(
        Data("usage: swift generate-fixture.swift <output-path>\n".utf8))
    exit(1)
}
let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.removeItem(at: outputURL)

let width = 64
let height = 64
let fps: Int32 = 10
let seconds = 2
let frameCount = Int(fps) * seconds

func run() async throws {
    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
    let settings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.proRes4444,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ],
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    let attributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                        sourcePixelBufferAttributes: attributes)
    guard writer.canAdd(input) else { fatalError("canAdd refused") }
    writer.add(input)
    guard writer.startWriting() else {
        fatalError("startWriting failed: \(String(describing: writer.error))")
    }
    writer.startSession(atSourceTime: .zero)
    guard let pool = adaptor.pixelBufferPool else { fatalError("no pixel buffer pool") }

    let frameDuration = CMTime(value: 1, timescale: fps)
    for frame in 0..<frameCount {
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        var raw: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &raw)
        guard let buffer = raw else { continue }
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        // BGRA memory order — first half red (r:255,g:0,b:0), second half blue (r:0,g:0,b:255).
        let bgra: [UInt8] = frame < frameCount / 2 ? [0, 0, 255, 255] : [255, 0, 0, 255]
        for row in 0..<height {
            let rowBase = base.advanced(by: row * bytesPerRow)
            for column in 0..<width {
                rowBase.advanced(by: column * 4).copyMemory(from: bgra, byteCount: 4)
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let pts = CMTimeMultiply(frameDuration, multiplier: Int32(frame))
        guard adaptor.append(buffer, withPresentationTime: pts) else {
            fatalError("append failed at frame \(frame)")
        }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else {
        fatalError("writer finished with status \(writer.status.rawValue), error \(String(describing: writer.error))")
    }
    print("wrote \(frameCount) frames to \(outputURL.path)")
}

let semaphore = DispatchSemaphore(value: 0)
Task {
    do {
        try await run()
    } catch {
        print("ERROR: \(error)")
    }
    semaphore.signal()
}
semaphore.wait()
