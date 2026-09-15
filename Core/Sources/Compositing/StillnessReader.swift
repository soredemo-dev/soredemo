import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import Overlays

/// Measures how much of the picture changes, slice by slice, for `StillnessFinder` to read.
///
/// `changes(contentsOf:sliceSeconds:onProgress:)` walks a recording and returns one number per
/// slice: the fraction of the frame whose grey differs from the previous slice's by more than
/// `pixelThreshold`. A still stretch measures 0.
///
/// **A frame difference, not optical flow, and that is measured rather than assumed.** Optical
/// flow answers a harder question — which way things moved — and costs 39 ms a pair against
/// 2.7 ms here. For "is anything happening" the two agree exactly: on 269 slices of a genuinely
/// idle recording both reported zero. See `docs/design/finding-dead-air.md`.
///
/// **Read through `AVAssetReader`, never `AVAssetImageGenerator`.** Asking the generator for exact
/// frames out of a movie written by a capture session hung past ten minutes for an eighteen-frame
/// clip, with no error. A reader walks the file in order, which is what this needs anyway.
public enum StillnessReader {
    /// How far one pixel's grey must move to count as changed, 0…255.
    ///
    /// **Eight, which sits above compression noise and below anything a person would see.** A
    /// recording is encoded, so a "still" frame is not bit-identical to the one before it; a
    /// threshold of zero measures the encoder rather than the picture.
    public static let pixelThreshold = 8

    /// The width frames are reduced to before comparison.
    ///
    /// **The measure is a FRACTION of the frame**, so the answer is the same at any width — which
    /// is what makes it safe to shrink. 480 keeps a moving cursor at about 0.15% of the frame,
    /// comfortably above the threshold `StillnessFinder` compares against, and turns a 4K frame
    /// into 150 KB of work.
    public static let analysisWidth = 480

    /// Why a recording could not be measured. **Named, never `nil`** — a caller told only that it
    /// failed cannot say whether to offer the feature again.
    public enum Refusal: String, Sendable, Equatable, Hashable {
        case theFileWillNotOpen
        case thereIsNoVideoTrack
        case theReaderWouldNotStart
        /// The caller went away — the editor was closed, or the search was stopped — while the
        /// recording was being walked. **A named refusal rather than an empty `changes([])`**,
        /// which would read as "nothing moved in this recording" and suppress every zoom.
        case theWorkWasCancelled
    }

    public enum Outcome: Sendable, Equatable {
        /// One change measure per slice, in order from the start of the recording.
        case changes([Double])
        case refused(Refusal)
    }

    /// Walks `url` and measures each slice.
    ///
    /// `onProgress` reports 0…1 as the recording is walked. **A recording is walked once and
    /// decoded once**, so this is as fast as decoding it — a few seconds for a few minutes of
    /// video, which is why it is asked for rather than run on every open.
    public static func changes(contentsOf url: URL, sliceSeconds: Double = 0.25,
                               onProgress: (@Sendable (Double) -> Void)? = nil) async -> Outcome {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.isNumeric else {
            return .refused(.theFileWillNotOpen)
        }
        guard let track = (try? await asset.loadTracks(withMediaType: .video))?.first else {
            return .refused(.thereIsNoVideoTrack)
        }
        guard let reader = try? AVAssetReader(asset: asset) else {
            return .refused(.theReaderWouldNotStart)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return .refused(.theReaderWouldNotStart) }
        reader.add(output)
        guard reader.startReading() else { return .refused(.theReaderWouldNotStart) }
        defer { reader.cancelReading() }

        let context = CIContext(options: [.useSoftwareRenderer: false])
        var changes: [Double] = []
        var previous: [UInt8]?
        var nextSliceAt = 0.0
        let total = max(duration.seconds, 0.000_001)

        while let sample = output.copyNextSampleBuffer() {
            // **Cancellation is checked HERE or it does nothing.** These loops are awaited from
            // a SwiftUI `.task`, so closing the editor cancels them — and a loop that never
            // asks decodes the whole recording regardless. Worse than the wasted work: an
            // `AVAssetReader` still pulling after its caller is gone is one more CONCURRENT
            // reader, which is the exact condition of the `copyNextSampleBuffer` hang this
            // project has documented and cannot fix.
            guard !Task.isCancelled else { return .refused(.theWorkWasCancelled) }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            // **One frame per slice, and the FIRST one at or after the boundary.** Averaging the
            // frames inside a slice would smear a short movement into stillness, which is the one
            // direction this must not be wrong in.
            guard time >= nextSliceAt else { continue }
            nextSliceAt += sliceSeconds
            guard let buffer = CMSampleBufferGetImageBuffer(sample),
                  let grey = greyscale(buffer, context: context) else { continue }
            if let previous, previous.count == grey.count {
                var moved = 0
                for index in 0..<grey.count where abs(Int(grey[index]) - Int(previous[index]))
                    > pixelThreshold {
                    moved += 1
                }
                changes.append(Double(moved) / Double(grey.count))
            }
            previous = grey
            onProgress?(min(time / total, 1))
        }
        onProgress?(1)
        return .changes(changes)
    }

    /// One frame as 8-bit grey at `analysisWidth`.
    ///
    /// Grey rather than colour: a change big enough to matter moves the luminance, and comparing
    /// one plane instead of three is three times less work for the same answer.
    private static func greyscale(_ buffer: CVPixelBuffer, context: CIContext) -> [UInt8]? {
        let image = CIImage(cvPixelBuffer: buffer)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scale = Double(analysisWidth) / Double(extent.width)
        let height = max(Int((Double(extent.height) * scale).rounded()), 1)
        let scaled = image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .applyingFilter("CIPhotoEffectMono")
        var pixels = [UInt8](repeating: 0, count: analysisWidth * height * 4)
        pixels.withUnsafeMutableBytes {
            // Through the bridge: D3 keeps CoreGraphics geometry out of this tier, and the
            // allow-list scan caught this line the moment it was written.
            unsafe context.render(scaled, toBitmap: $0.baseAddress!,
                                  rowBytes: analysisWidth * 4,
                                  bounds: HeadlessGeometryBridge.rect(
                                      x: 0, y: 0, width: Double(analysisWidth),
                                      height: Double(height)),
                                  format: .RGBA8, colorSpace: nil)
        }
        // The red channel of a mono image IS its grey; taking one of the three is a stride, not
        // a conversion.
        return stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] }
    }
}
