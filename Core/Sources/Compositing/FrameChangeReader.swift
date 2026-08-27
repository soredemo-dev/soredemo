import AVFoundation
import CoreVideo
import Foundation
import Framing
import Timeline

/// **Reduces a recording to how much each part of it changed, frame by frame.**
///
/// The decoding half of motion framing. `MotionActivity` decides where somebody tapped; this
/// gives it the numbers, and the split is what makes every rule over there testable against
/// grids written by hand.
///
/// **Decoded small, not decoded and then shrunk.** The reader asks AVFoundation for frames at
/// the grid's own size, so the hardware scaler does the downsampling on the way out of the
/// decoder. A full-size 4K frame — which is what a phone recording is, measured — is 33 MB, and
/// there are 60 of them a second.
///
/// **Luminance only.** A tap changes brightness wherever it changes anything; carrying three
/// channels triples the work to answer the same question, and a colour change with no
/// brightness change is not a thing a UI does.
public enum FrameChangeReader {
    /// The grid the frame is reduced to.
    ///
    /// **Tall by default, because phones are.** A square grid over a portrait screen makes each
    /// tile a wide rectangle, and a tap's target then comes out wider than it is tall for no
    /// reason but the grid. Callers with a landscape recording pass their own.
    public static let defaultColumns = 8
    public static let defaultRows = 12

    /// How many frames a second to look at. **Not every frame**: taps are events at human
    /// speed, thirty a second is more than enough to catch one, and halving the work halves how
    /// long somebody waits before their zooms appear.
    public static let defaultSamplesPerSecond: Double = 30

    public enum ReadError: Error, CustomStringConvertible, Sendable, Equatable {
        case noVideoTrack
        case readerRefusedOutput

        public var description: String {
            switch self {
            case .noVideoTrack: "this recording has no video to look at"
            case .readerRefusedOutput: "AVAssetReader refused a downscaled output"
            }
        }
    }

    /// Reads `asset` and reports how much each tile changed between consecutive sampled frames.
    ///
    /// `epoch` stamps the instants. A phone recording has no observation log and therefore no
    /// boot epoch of its own; the caller mints one and uses it consistently, which is all the
    /// framing machinery needs from it.
    /// **`onProgress` exists because this cannot be made fast, and measuring that is what
    /// settled it.** On a real 4K phone recording — 10.34 seconds — reading takes 4.9 seconds,
    /// and it takes the same 4.9 seconds whether 30, 10 or 5 frames a second are sampled. The
    /// cost is decoding H.264 at full resolution; the tiles are free. Roughly half real-time, so
    /// a five-minute recording is two and a half minutes of background work with nothing to show
    /// for it until the end.
    ///
    /// Reported as a fraction of the recording's duration, on whatever actor the caller is on.
    public nonisolated static func changes(
        from asset: AVAsset, epoch: BootEpoch,
        columns: Int = defaultColumns, rows: Int = defaultRows,
        samplesPerSecond: Double = defaultSamplesPerSecond,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [MotionActivity.Change] {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ReadError.noVideoTrack
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: columns,
            kCVPixelBufferHeightKey as String: rows,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ReadError.readerRefusedOutput }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? ReadError.readerRefusedOutput
        }

        let minimumGap = samplesPerSecond > 0 ? 1 / samplesPerSecond : 0
        // Zero when the duration is unknown or not finite, in which case no progress is
        // reported rather than a made-up fraction — an indeterminate spinner is honest and a
        // bar that jumps to 100% and stays there is not.
        let totalSeconds = (try? await asset.load(.duration).seconds) ?? 0
        var lastReported = -1.0
        var changes: [MotionActivity.Change] = []
        var previous: [Double]?
        var lastSampledSeconds = -Double.infinity

        while let buffer = output.copyNextSampleBuffer() {
            let seconds = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            guard seconds.isFinite, seconds - lastSampledSeconds >= minimumGap else { continue }
            guard let image = CMSampleBufferGetImageBuffer(buffer) else { continue }
            guard let luminance = tiles(of: image, columns: columns, rows: rows) else { continue }
            lastSampledSeconds = seconds

            if let earlier = previous {
                // Mean absolute difference per tile, already in 0…1 because the samples are.
                var difference = [Double](repeating: 0, count: luminance.count)
                for i in luminance.indices { difference[i] = abs(luminance[i] - earlier[i]) }
                changes.append(MotionActivity.Change(
                    instant: HostInstant(epoch: epoch,
                                         hostTime: Nanoseconds(Int64(seconds * 1_000_000_000))),
                    columns: columns, rows: rows, tiles: difference))
            }
            previous = luminance

            if let onProgress, totalSeconds > 0 {
                let fraction = Swift.min(Swift.max(seconds / totalSeconds, 0), 1)
                // Reported in percent steps: a callback per frame on a five-minute recording is
                // nine thousand hops to the main actor to move a bar by nothing.
                if fraction - lastReported >= 0.01 {
                    lastReported = fraction
                    onProgress(fraction)
                }
            }
        }
        if reader.status == .failed, let error = reader.error { throw error }
        return changes
    }

    /// One frame's tiles, as luminance in 0…1.
    ///
    /// The buffer has already been scaled to exactly `columns × rows` by the decoder, so this is
    /// a read rather than an average — which is the whole reason for asking for that size.
    static func tiles(of image: CVPixelBuffer, columns: Int, rows: Int) -> [Double]? {
        guard CVPixelBufferGetWidth(image) == columns,
              CVPixelBufferGetHeight(image) == rows else { return nil }
        guard CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        // Safe here: the buffer is locked for the whole of this function, the base address is
        // read only within it, and every index below is bounded by the width, height and
        // bytes-per-row the buffer itself reports.
        guard let base = unsafe CVPixelBufferGetBaseAddress(image) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(image)
        var result = [Double](repeating: 0, count: columns * rows)
        for row in 0..<rows {
            // BGRA: three channels then alpha, which is ignored — a UI is opaque and an alpha
            // that changed without any colour changing is not something to zoom to.
            let line = unsafe base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
            for column in 0..<columns {
                let pixel = column * 4
                let b = Double(unsafe line[pixel])
                let g = Double(unsafe line[pixel + 1])
                let r = Double(unsafe line[pixel + 2])
                // Rec. 601 luma, the same weighting `Loudness` would call an established figure
                // rather than a guess: it is what "brightness" means to an eye.
                result[row * columns + column] = (0.299 * r + 0.587 * g + 0.114 * b) / 255
            }
        }
        return result
    }
}
