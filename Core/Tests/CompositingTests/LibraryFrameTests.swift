import AVFoundation
import CoreImage
import Foundation
import Testing
import Render
import Timeline
@testable import Compositing

// What the compositor draws inside a library clip, read from an exported file's pixels
// (`docs/design/2026-11-13-clips-from-the-library.md`).

/// A solid colour as a PNG, so the pixel a library frame must show is known independently.
private func solidPicture(red: Double, green: Double, blue: Double) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "library-solid-\(ProcessInfo.processInfo.globallyUniqueString).png")
    let image = CIImage(color: CIColor(red: red, green: green, blue: blue)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 36))
    try CIContext().writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    return url
}

/// The centre pixel of `image`, as 0–255 red, green, blue.
private func centre(_ image: CGImage) -> (Int, Int, Int) {
    let width = image.width, height = image.height
    var pixel = [UInt8](repeating: 0, count: 4)
    // Safe here: `pixel` is a local that outlives `context`, which draws into it once below and
    // is not kept — the four bytes are read only after the draw has returned.
    let context = unsafe CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
    return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
}

extension StageCompositorTests {
    /// **Inside a picture clip the card shows the picture; either side, the recording.**
    /// Measured, not assumed: the two-tone fixture is pure red for its first second and pure blue
    /// for its second (an earlier draft of this test used a red picture and could not tell). The
    /// picture is green, so each of the three frames has an answer known before anything renders.
    @Test func aPictureClipIsDrawnOnTheCardAndTheRecordingEitherSide() async throws {
        let source = AVURLAsset(url: repositoryRootFromTests.appending(path: "Tests/RenderParityFixtures/two-tone.mov"))
        let nanos = Int64(try await source.load(.duration).seconds * 1_000_000_000)
        let green = try solidPicture(red: 0, green: 1, blue: 0)
        defer { try? FileManager.default.removeItem(at: green) }
        let edit = try #require(EditTimeline.whole(duration: Nanoseconds(nanos))
            .inserting(.picture(item: 7), sourceStart: Nanoseconds(0), duration: Nanoseconds(1_000_000_000),
                       atOutput: Nanoseconds(nanos / 2)))

        let saved = StageCompositor.settings()
        defer { StageCompositor.apply(saved) }
        StageCompositor.renderer = try CoreImageFrameRenderer()
        StageCompositor.style = .default
        StageCompositor.observationLogURL = nil
        StageCompositor.editTimeline = edit
        StageCompositor.libraryPictures = [7: green]

        let cut = try await EditedAsset.make(from: source, by: edit)
        let output = FileManager.default.temporaryDirectory.appending(path: "library-frames-\(ProcessInfo.processInfo.globallyUniqueString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        _ = try await MP4Exporter.export(asset: cut, to: output, outputWidth: 320, outputHeight: 180,
                                         edit: edit, assetIsAlreadyEdited: true)

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let half = Double(nanos / 2) / 1e9
        // The picture is inserted at the recording's 1 s — the seam between its red and its blue.
        let before = centre(try await generator.image(at: CMTime(seconds: half - 0.3, preferredTimescale: 600)).image)
        let inside = centre(try await generator.image(at: CMTime(seconds: half + 0.5, preferredTimescale: 600)).image)
        let after = centre(try await generator.image(at: CMTime(seconds: half + 1.3, preferredTimescale: 600)).image)
        #expect(before.0 > 200 && before.1 < 60 && before.2 < 60, "before it, the recording's red: \(before)")
        #expect(inside.1 > 200 && inside.0 < 60 && inside.2 < 60, "inside the picture the card is green: \(inside)")
        #expect(after.2 > 200 && after.0 < 60 && after.1 < 60, "after it, the recording's blue, two seconds later in the output: \(after)")
    }
}
