import Accelerate
import AVFoundation
import Foundation

/// A recording's audio as a peak envelope — one value per short slice, for drawing.
///
/// **Why an envelope and not the samples.** A minute of 48 kHz stereo is 5.8 million numbers
/// and a timeline strip is a few hundred pixels wide. Reducing on read rather than on draw
/// means the expensive part happens once, off the main thread, and the view has an array it
/// can index.
///
/// `../opensource/Screen Record Opensource/a native editor`'s `WaveformExtractor` is the
/// shape this follows: mono float32, a fixed sample rate with a total cap, `vDSP_maxmgv` for
/// the peak magnitude of each hop, and a dB floor so quiet passages are visible rather than
/// flat. The one deliberate difference is the ORIENTATION — theirs returns 1 for silence and 0
/// for full scale, because their view draws distance from the top. Ours is the conventional
/// way round, 0 quiet and 1 loud, so a caller cannot mistake a silent recording for a loud one
/// by drawing it without reading this comment.
public struct WaveformEnvelope: Hashable, Sendable {
    /// Peak magnitude per slice, each 0…1 after the dB mapping. Empty when the asset has no
    /// audio — which is a real answer and not a failure.
    public let peaks: [Float]
    /// How long each slice covers. Held rather than assumed so a caller drawing against a
    /// timeline can place the envelope without knowing how it was sampled.
    public let sliceDuration: Double

    public init(peaks: [Float], sliceDuration: Double) {
        self.peaks = peaks
        self.sliceDuration = sliceDuration
    }

    public var isEmpty: Bool { peaks.isEmpty }

    /// The peak covering `seconds`, or `nil` outside the envelope. Clamped to nothing: a
    /// caller asking past the end has a bug, and returning the last value would hide it.
    public func peak(atSeconds seconds: Double) -> Float? {
        guard sliceDuration > 0, seconds >= 0 else { return nil }
        let index = Int(seconds / sliceDuration)
        return peaks.indices.contains(index) ? peaks[index] : nil
    }

    // MARK: - reading

    /// 200 slices a second. a native editor's rate, kept rather than re-guessed: fine enough that
    /// a syllable is visible at a normal timeline zoom, coarse enough that a ten-minute
    /// recording is 120,000 floats rather than 28 million.
    public static let slicesPerSecond: Double = 200

    /// The total cap. A recording long enough to exceed it is sampled more coarsely instead,
    /// so memory is bounded by the cap rather than by how long someone recorded for.
    public static let maxSlices = 240_000

    /// **−50 dB is the floor, and the mapping is logarithmic for a reason.** Linear peak
    /// amplitude makes ordinary speech — which sits around −20 dB, a tenth of full scale —
    /// draw as a barely visible line, and a person reading the strip concludes there is no
    /// audio. Mapping dB onto the height instead puts speech at three fifths of it.
    public static let noiseFloorDecibels: Float = -50

    /// Reads `asset`'s audio into an envelope.
    ///
    /// Mono, because a waveform drawn from two channels is two waveforms and a timeline strip
    /// has room for one — and because the question it answers ("is anyone talking here") does
    /// not depend on which side they are on.
    public nonisolated static func read(from asset: AVAsset) async throws -> WaveformEnvelope {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return WaveformEnvelope(peaks: [], sliceDuration: 0) }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            return WaveformEnvelope(peaks: [], sliceDuration: 0)
        }

        let rate = min(slicesPerSecond, Double(maxSlices) / duration)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        guard reader.canAdd(output) else { throw WaveformError.readerRefusedOutput }
        reader.add(output)
        guard reader.startReading() else {
            throw WaveformError.readFailed(reader.error.map { String(describing: $0) }
                ?? "startReading() returned false")
        }

        var peaks: [Float] = []
        var carryPeak: Float = 0
        var carriedFrames = 0
        var hop = 0
        var sampleRate = 0.0

        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            if hop == 0 {
                guard let format = CMSampleBufferGetFormatDescription(buffer),
                      let asbd = unsafe CMAudioFormatDescriptionGetStreamBasicDescription(format)
                else { continue }
                sampleRate = unsafe asbd.pointee.mSampleRate
                hop = max(1, Int((sampleRate / rate).rounded()))
            }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard unsafe CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                                     totalLengthOut: &length,
                                                     dataPointerOut: &pointer) == noErr,
                  // `unsafe`: the block buffer's own storage, valid while `buffer` is alive,
                  // which it is for this whole iteration. `length` comes from the SAME call
                  // rather than from the format, so the rebind below cannot outrun what was
                  // actually returned.
                  let bytes = unsafe pointer
            else { continue }

            let frames = length / MemoryLayout<Float>.size
            unsafe bytes.withMemoryRebound(to: Float.self, capacity: frames) { samples in
                var index = 0
                while index < frames {
                    let take = min(hop - carriedFrames, frames - index)
                    var localPeak: Float = 0
                    // `vDSP_maxmgv` is the maximum MAGNITUDE, so a negative trough counts as
                    // loudly as a positive crest — which is what a peak envelope means.
                    unsafe vDSP_maxmgv(samples + index, 1, &localPeak, vDSP_Length(take))
                    carryPeak = max(carryPeak, localPeak)
                    carriedFrames += take
                    index += take
                    if carriedFrames == hop {
                        peaks.append(normalized(peak: carryPeak))
                        carryPeak = 0
                        carriedFrames = 0
                    }
                }
            }
        }
        // The tail is a partial slice, kept rather than dropped: dropping it would make the
        // envelope end slightly before the audio does, which shows as a gap at the right edge.
        if carriedFrames > 0 { peaks.append(normalized(peak: carryPeak)) }

        if reader.status == .failed {
            throw WaveformError.readFailed(reader.error.map { String(describing: $0) }
                ?? "reader failed after \(peaks.count) slice(s)")
        }
        return WaveformEnvelope(peaks: peaks, sliceDuration: hop > 0 && sampleRate > 0
                                ? Double(hop) / sampleRate : 0)
    }

    // MARK: - drawing

    /// The envelope reduced to one height per column of a strip, each 0…1.
    ///
    /// **Plain numbers, because no tier here may name a CoreGraphics geometry type.** Rule 5
    /// confines `CGRect`/`CGPoint`/`CGSize` to the two bridge files, and the app tier may not
    /// name them at all — that rule is not a formality: coordinate arithmetic re-derived inside
    /// a view is how the cursor came to be normalised against the wrong rectangle. So the
    /// reduction happens here, in the type that owns the envelope, and the view turns heights
    /// into bars with SwiftUI primitives that name nothing.
    ///
    /// **One column takes the MAXIMUM of the slices it covers.** The envelope is 200 slices a
    /// second and a strip is a few hundred points wide, so most columns cover several.
    /// Averaging them would flatten a transient — a click, the start of a word — into the quiet
    /// around it, and those are exactly what a person scans a waveform to find.
    ///
    /// A silent column is `0`, and the caller draws nothing for it rather than a hairline.
    public nonisolated func columnHeights(columns: Int, spanningSeconds seconds: Double) -> [Double] {
        guard columns > 0, seconds > 0, sliceDuration > 0, !peaks.isEmpty else { return [] }
        var heights: [Double] = []
        heights.reserveCapacity(columns)
        for column in 0..<columns {
            let from = Double(column) / Double(columns) * seconds
            let to = Double(column + 1) / Double(columns) * seconds
            var loudest: Float = 0
            var at = from
            // Stepped by the envelope's own slice so a wide column reads every slice it covers
            // rather than sampling one and calling it the answer.
            while at < to {
                loudest = max(loudest, peak(atSeconds: at) ?? 0)
                at += sliceDuration
            }
            heights.append(Double(loudest))
        }
        return heights
    }

    /// Full scale → 1, the noise floor and below → 0. See `noiseFloorDecibels` for why this is
    /// logarithmic.
    static func normalized(peak: Float) -> Float {
        guard peak > 0 else { return 0 }
        let decibels = 20 * log10(peak)
        guard decibels > noiseFloorDecibels else { return 0 }
        return (decibels - noiseFloorDecibels) / (-noiseFloorDecibels)
    }
}

public enum WaveformError: Error, CustomStringConvertible, Sendable, Equatable {
    case readerRefusedOutput
    case readFailed(String)

    public var description: String {
        switch self {
        case .readerRefusedOutput: "AVAssetReader refused the audio output"
        case .readFailed(let why): "reading the audio failed: \(why)"
        }
    }
}
