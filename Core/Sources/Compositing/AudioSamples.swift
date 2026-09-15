import AVFoundation
import Foundation

/// **Moving PCM between a file and memory, and nothing else.**
///
/// Split out from `NoiseReducedAudio` rather than living inside it, because reading an asset's
/// audio into `[Float]` and writing `[Float]` back out are useful to anything that processes
/// samples — and because a type that both reads files and does signal processing has two reasons
/// to change. `WaveformEnvelope` already reads audio for its own purpose; it reduces as it goes,
/// to peaks per slice, so it cannot be reused here and is not duplicated either: this keeps the
/// samples.
///
/// **Mono, deinterleaved, 32-bit float, at the file's own rate.** One channel because everything
/// downstream of this is speech processing and a room's noise is the same room in both ears;
/// the file's own rate because resampling is a second lossy step and `NoiseReduction` has no
/// opinion about rate.
public enum AudioSamples {
    public struct Track: Sendable {
        public let samples: [Float]
        public let sampleRate: Double

        public init(samples: [Float], sampleRate: Double) {
            self.samples = samples
            self.sampleRate = sampleRate
        }

        public var seconds: Double { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }
    }

    /// Reads every audio track of `asset`, mixed down to one mono channel.
    ///
    /// **`AVAssetReaderAudioMixOutput`, the same reader `WaveformEnvelope` uses**, so a recording
    /// that one of them can read is a recording the other can read. A file with no audio track is
    /// a `nil` rather than an empty `Track`: "there is no microphone here" and "the microphone
    /// recorded silence" are different facts and a caller must not confuse them.
    public nonisolated static func read(from asset: AVAsset) async throws -> Track? {
        try await read(from: asset, trackIndex: nil)
    }

    /// Reads ONE of `asset`'s audio tracks.
    ///
    /// **This exists because a Soredemo recording has two, and they are not interchangeable.**
    /// The master writer lays down system audio and then the microphone — `AudioMixBuilder`
    /// .trackOrder is the named constant for that, and everything in the app that has to tell
    /// them apart reads it rather than writing `1`. Mixing them and handing back one signal, as
    /// the whole-asset read above does, is right for measuring a level and wrong for anything
    /// that will be written back: it would collapse two sources a person mixes separately into
    /// one, and their gain sliders would stop meaning anything.
    ///
    /// `nil` when the asset has no track at that index — a recording made with no microphone is
    /// ordinary, not an error.
    public nonisolated static func read(from asset: AVAsset, trackIndex: Int?)
    async throws -> Track? {
        let all = try await asset.loadTracks(withMediaType: .audio)
        let tracks: [AVAssetTrack]
        if let trackIndex {
            guard all.indices.contains(trackIndex) else { return nil }
            tracks = [all[trackIndex]]
        } else {
            tracks = all
        }
        guard !tracks.isEmpty else { return nil }

        // The rate is taken from the first track rather than assumed. A Soredemo recording is
        // 48 kHz, but this type is also handed imported files.
        let descriptions = try await tracks[0].load(.formatDescriptions)
        let rate = descriptions.first.flatMap { description -> Double? in
            guard let basic = description.audioStreamBasicDescription else { return nil }
            return basic.mSampleRate
        } ?? 48_000

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: rate,
        ])
        guard reader.canAdd(output) else { throw WaveformError.readerRefusedOutput }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? WaveformError.readerRefusedOutput
        }

        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            // **Cancellation is checked HERE or it does nothing.** These loops are awaited from
            // a SwiftUI `.task`, so closing the editor cancels them — and a loop that never
            // asks decodes the whole recording regardless. Worse than the wasted work: an
            // `AVAssetReader` still pulling after its caller is gone is one more CONCURRENT
            // reader, which is the exact condition of the `copyNextSampleBuffer` hang this
            // project has documented and cannot fix.
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            guard bytes >= MemoryLayout<Float>.size else { continue }
            var block32 = [Float](repeating: 0, count: bytes / MemoryLayout<Float>.size)
            // Safe here, and this is `Loudness.measure`'s own shape rather than a second way of
            // doing the same thing: the destination is exactly `bytes` long by construction one
            // line up, the pointer never leaves `withUnsafeMutableBytes`'s scope, and the copy is
            // the framework's bounded one rather than a raw read of the block's storage.
            let copied = block32.withUnsafeMutableBytes { buffer -> OSStatus in
                guard let base = buffer.baseAddress else { return -1 }
                return unsafe CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes,
                                                         destination: base)
            }
            guard copied == noErr else { continue }
            samples.append(contentsOf: block32)
        }
        if reader.status == .failed, let error = reader.error { throw error }
        return Track(samples: samples, sampleRate: rate)
    }

    /// Writes `track` to `url` as uncompressed CAF.
    ///
    /// **Uncompressed on purpose.** This file is an intermediate that gets encoded again by the
    /// exporter; compressing it here would be one generation of loss spent on a file nobody
    /// keeps. CAF rather than WAV because WAV's 32-bit length field caps it at 4 GB and a long
    /// recording at 48 kHz float can reach that.
    public nonisolated static func write(_ track: Track, to url: URL) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: track.sampleRate,
                                         channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(track.samples.count))
        else { throw WaveformError.readerRefusedOutput }
        buffer.frameLength = AVAudioFrameCount(track.samples.count)
        // Safe here: `floatChannelData` is a pointer-to-pointers the buffer owns and keeps alive
        // for its own lifetime, and `buffer` outlives every use of it below. `nil` means the
        // format is not float — impossible for a `standardFormat`, and refused rather than
        // assumed.
        guard let channel = unsafe buffer.floatChannelData else {
            throw WaveformError.readerRefusedOutput
        }
        // Safe here: the buffer was allocated with `frameCapacity` equal to `samples.count` and
        // `frameLength` set to the same number, so the destination is exactly as long as the
        // source; the pointer never leaves `withUnsafeBufferPointer`'s scope. One bulk copy
        // rather than a loop of subscripts — fewer unsafe expressions to justify, and the
        // framework's own bounded move.
        track.samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            unsafe channel[0].update(from: base, count: track.samples.count)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
