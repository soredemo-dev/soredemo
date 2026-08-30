import AVFoundation
import CoreMedia
import Foundation

/// **How loud a recording actually is, in LUFS, by ITU-R BS.1770-4.**
///
/// A demo's narration is recorded at whatever level the person's microphone happened to sit
/// at, and a peak meter cannot tell a quiet voice from a loud one — peaks are set by the
/// loudest consonant, not by how loud the speech reads. Every platform a demo is posted to
/// normalises by *loudness* instead (YouTube to −14 LUFS, Spotify to −14, Apple Podcasts to
/// −16), so a file that ignores loudness is a file the platform will change.
///
/// **Measured here and applied as a gain, so the master is never touched.** The recording is
/// evidence in this project; normalisation is a decision about the export. The measurement
/// comes out of this file, `AudioMix` carries the target a person chose, and
/// `AudioMixBuilder` turns the pair into the same per-track volume it already sets — so the
/// preview and the export normalise identically, by construction, and turning it off restores
/// the recorded level exactly.
///
/// **Pure, and over samples rather than over an asset.** Every constant below is from the
/// standard, and a function that took an `AVAsset` could not be tested against the standard's
/// own conformance signals. Reading the samples is the caller's job.
public enum Loudness {
    // MARK: - the standard's numbers

    /// The offset in the loudness equation, `L = −0.691 + 10·log₁₀(Σ G·z)`. BS.1770-4 §4.
    public static let referenceOffset: Double = -0.691

    /// One gating block is 400 ms and they overlap by 75%, so a new block starts every 100 ms.
    /// BS.1770-4 §5 and EBU Tech 3341.
    public static let blockSeconds: Double = 0.4
    public static let blockOverlap: Double = 0.75

    /// **Two gates, and they are not the same kind of thing.** The absolute one drops digital
    /// silence and room tone so a pause does not drag the answer down; the relative one, ten
    /// units below the ungated mean, drops the quiet parts of the programme so the number
    /// describes the speech rather than the gaps between it. BS.1770-4 §5.
    public static let absoluteGateLUFS: Double = -70
    public static let relativeGateLU: Double = -10

    /// **−16 LUFS, and the choice is between two defensible numbers.** YouTube and Spotify
    /// normalise to −14; podcast guidance and EBU R128's −23 bracket it on either side. A
    /// screen demo is narration over interface sound, watched in a browser tab beside other
    /// tabs, and −16 leaves ~2 LU of headroom under the platforms' own target — so a platform
    /// that renormalises turns it *up* slightly rather than pulling it down and squashing the
    /// peaks it was mixed against. **Uncalibrated** in this project's sense: chosen from the
    /// published targets, not from a measurement of this app's output.
    public static let defaultTargetLUFS: Double = -16

    /// The most a normalising gain may lift or cut, in decibels. A recording made with the
    /// microphone muted measures near silence, and a gain computed from it without a bound
    /// would multiply the noise floor into a roar; a bound turns that into "as far as this
    /// will go", which is audible as a decision rather than as damage.
    public static let maximumAdjustmentDB: Double = 24

    // MARK: - measuring

    /// The integrated loudness of interleaved `channels`-channel float samples, or `nil` when
    /// nothing passed the absolute gate — silence has no loudness, and returning a very
    /// negative number instead would invite a caller to compute a gain from it.
    ///
    /// **Implemented through `Meter`, not beside it.** A recording is read in sample buffers and
    /// a half-hour of stereo float PCM is most of a gigabyte, so the real measurement has to be
    /// streaming; having this convenience compute the answer a second way would be two answers
    /// that could drift. This is the same code with the whole signal handed over at once.
    public static func integrated(samples: [Float], sampleRate: Double,
                                  channels: Int) -> Double? {
        guard sampleRate > 0, channels > 0, !samples.isEmpty else { return nil }
        var meter = Meter(sampleRate: sampleRate, channels: channels)
        meter.append(samples)
        return meter.integrated()
    }

    /// **A running loudness meter, fed sample buffer by sample buffer.**
    ///
    /// Keeps the K-weighting filter's state and a sliding window of block power across calls,
    /// so a recording is measured in one pass without ever holding more than 400 ms of it. The
    /// per-frame quantity is `Σ_ch y²` rather than each channel's own mean square, which is the
    /// same number: `Σ G_i·z_i` with every weight 1 is `mean(Σ_i y_i²)`, so one running sum
    /// serves both channels.
    public struct Meter {
        private let channels: Int
        private let counted: Int
        private let blockLength: Int
        private let step: Int

        private var shelf: [BiquadState]
        private var highPass: [BiquadState]
        /// Resolved once per meter rather than per frame — they depend only on the rate.
        private let shelfCoefficients: Biquad
        private let highPassCoefficients: Biquad

        /// The last `blockLength` frames' `Σ_ch y²`, as a ring, with their running total.
        private var window: [Double]
        private var writeIndex = 0
        private var filled = 0
        private var runningSum = 0.0
        private var sinceLastBlock = 0
        /// The largest absolute sample seen, unfiltered. See `Reading.peak`.
        private var observedPeak = 0.0

        /// One entry per emitted 400 ms block.
        private(set) public var blockPower: [Double] = []

        public init(sampleRate: Double, channels: Int) {
            self.channels = max(channels, 1)
            // BS.1770 weights left and right at 1.0; beyond stereo the weights depend on which
            // channel is which, and a master here has never carried more than two.
            self.counted = min(self.channels, 2)
            self.blockLength = max(Int((blockSeconds * sampleRate).rounded()), 1)
            self.step = max(Int((blockSeconds * (1 - blockOverlap) * sampleRate).rounded()), 1)
            self.shelf = Array(repeating: BiquadState(), count: self.channels)
            self.highPass = Array(repeating: BiquadState(), count: self.channels)
            self.window = Array(repeating: 0, count: blockLength)
            self.shelfCoefficients = Loudness.shelfCoefficients(sampleRate: sampleRate)
            self.highPassCoefficients = Loudness.highPassCoefficients(sampleRate: sampleRate)
        }

        public mutating func append(_ samples: [Float]) {
            guard !samples.isEmpty else { return }
            let frames = samples.count / channels
            guard frames > 0 else { return }
            let shelfC = shelfCoefficients, highPassC = highPassCoefficients
            for frame in 0..<frames {
                var sum = 0.0
                for channel in 0..<channels {
                    let x = Double(samples[frame * channels + channel])
                    // Before the filters, and over EVERY channel rather than the counted ones:
                    // a peak in a channel the loudness ignores still clips the file.
                    if abs(x) > observedPeak { observedPeak = abs(x) }
                    let stage1 = shelf[channel].step(x, shelfC)
                    let y = highPass[channel].step(stage1, highPassC)
                    if channel < counted { sum += y * y }
                }
                // Slide the window: the oldest frame leaves, this one enters.
                runningSum += sum - window[writeIndex]
                window[writeIndex] = sum
                writeIndex = (writeIndex + 1) % blockLength
                if filled < blockLength { filled += 1 }
                sinceLastBlock += 1
                if filled == blockLength, sinceLastBlock >= step {
                    sinceLastBlock = 0
                    // Clamped at zero: the sliding subtraction can leave a value a hair below
                    // it on a silent passage, and a negative power is not a power.
                    blockPower.append(max(runningSum, 0) / Double(blockLength))
                }
            }
        }

        /// Everything one pass saw. The peak is available even when the loudness is `nil`:
        /// a track can be too quiet to have a loudness and still have a sample in it.
        public func reading() -> Reading {
            Reading(integrated: integrated(), peak: observedPeak)
        }

        public func integrated() -> Double? {
            // Gate 1, absolute: blocks quieter than −70 LUFS are not programme.
            let aboveAbsolute = blockPower.filter { loudness(ofPower: $0) > absoluteGateLUFS }
            guard !aboveAbsolute.isEmpty else { return nil }
            // Gate 2, relative: ten units below the mean of what survived gate 1.
            let ungatedMean = aboveAbsolute.reduce(0, +) / Double(aboveAbsolute.count)
            let threshold = loudness(ofPower: ungatedMean) + relativeGateLU
            let counted = aboveAbsolute.filter { loudness(ofPower: $0) > threshold }
            guard !counted.isEmpty else { return nil }
            return loudness(ofPower: counted.reduce(0, +) / Double(counted.count))
        }
    }

    /// One biquad's delay line, in direct form I.
    struct BiquadState {
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        mutating func step(_ x0: Double, _ c: Biquad) -> Double {
            let y0 = c.b0 * x0 + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2
            x2 = x1; x1 = x0
            y2 = y1; y1 = y0
            return y0
        }
    }

    /// `L = −0.691 + 10·log₁₀(z)`. Zero power is `−infinity`, which both gates reject.
    static func loudness(ofPower power: Double) -> Double {
        power > 0 ? referenceOffset + 10 * log10(power) : -.infinity
    }

    // MARK: - the gain that follows from it

    /// The linear gain that moves `measured` to `target`, bounded by `maximumAdjustmentDB`.
    /// `1` when there is nothing to move — a caller may pass a measurement it could not make.
    /// What one pass over a track saw: how loud it is, and how close it already is to the top.
    ///
    /// **Two numbers because levelling needs both and loudness alone cannot say the second.**
    /// Integrated loudness is an average over gated 400 ms blocks — by construction it says
    /// nothing about peaks, which is right for choosing a target and useless for staying under
    /// the ceiling on the way there. A track measured at −24 LUFS with a sample already at
    /// 0.98 has 8 dB of levelling to do and 0.2 dB of room to do it in.
    ///
    /// Measured in a real export before this existed: 544 samples over 1.0, peaking at 1.0292.
    /// Nothing reported it, because nothing was looking.
    public struct Reading: Hashable, Sendable {
        /// Integrated loudness in LUFS, or `nil` when nothing passed the gates — silence has
        /// no loudness, and a very negative number is not the same answer as no answer.
        public let integrated: Double?
        /// The largest absolute sample, on the UNFILTERED signal.
        ///
        /// Not the K-weighted one: the shelf lifts everything above 2 kHz by about 4 dB, so a
        /// peak taken after it is a peak of a signal no file contains. Zero for a silent track,
        /// which is honest — there is nothing to clip.
        public let peak: Double

        public init(integrated: Double?, peak: Double) {
            self.integrated = integrated
            self.peak = max(0, peak.isFinite ? peak : 0)
        }
    }

    /// How close to full scale a levelled track is allowed to come.
    ///
    /// **−1 dBFS, and this is a SAMPLE peak rather than a true peak.** A true-peak meter
    /// oversamples four times to catch what the reconstruction filter will do between samples,
    /// and broadcast practice asks for −1 dBTP against that. This measures the samples that are
    /// actually in the file, which is cheaper by a factor of four and is what the one pass this
    /// already makes can see. The claim is therefore the weaker one, and it is written here
    /// rather than implied: a track at exactly this ceiling may still exceed 0 dBTP after
    /// reconstruction. It cannot CLIP, which is what was happening.
    public static let peakCeilingDB: Double = -1
    public static var peakCeiling: Double { pow(10, peakCeilingDB / 20) }

    /// The levelling gain, capped so it cannot push a track into the ceiling.
    ///
    /// **The cap is on the DERIVED gain, never on the person's own.** Levelling is this app's
    /// arithmetic and may be overruled by arithmetic; a gain somebody set by hand is an authored
    /// value, and silently quietening it would be the producer-value rule broken. So a person
    /// who deliberately drives a track into clipping still can.
    ///
    /// `peak == 0` — a silent track — has no ceiling to hit and the loudness gain stands. It
    /// will be `1` anyway, since silence has no measured loudness.
    public static func levellingGain(for reading: Reading, to target: Double) -> Double {
        let wanted = gain(from: reading.integrated, to: target)
        guard reading.peak > 0 else { return wanted }
        return min(wanted, peakCeiling / reading.peak)
    }

    public static func gain(from measured: Double?, to target: Double) -> Double {
        guard let measured, measured.isFinite, target.isFinite else { return 1 }
        let decibels = min(max(target - measured, -maximumAdjustmentDB), maximumAdjustmentDB)
        return pow(10, decibels / 20)
    }

    // MARK: - K-weighting

    /// **K-weighting is two biquads**: a high shelf that lifts everything above ~2 kHz by about
    /// 4 dB, and a high-pass that removes what a listener does not hear as loudness. `Meter`
    /// runs them per channel and keeps their state across sample buffers.
    ///
    /// **Coefficients derived for the ACTUAL sample rate, not the standard's 48 kHz table.**
    /// BS.1770 publishes its coefficients at 48 kHz only, and a master's microphone track is
    /// written through by passthrough — so it can arrive at 44.1 kHz, where those numbers are
    /// the wrong filter. The analogue prototypes below are what the table was generated from,
    /// and `theDerivedCoefficientsReproduceTheStandardsTableAt48k` measures this against the
    /// published values rather than trusting the derivation.

    /// Normalised biquad coefficients — `a0` is already divided out. **Internal**: nothing
    /// outside this file has a use for one, and a public type nothing constructs is an
    /// unverified capability claim (D6a-V). The tests reach it through `@testable`.
    struct Biquad: Hashable, Sendable {
        let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    }

    /// Stage 1's analogue prototype: a 1681.97 Hz shelf of +4 dB at Q = 1/√2.
    static let shelfFrequency: Double = 1681.974450955533
    static let shelfGainDB: Double = 3.999843853973347
    static let shelfQ: Double = 0.7071752369554196

    /// Stage 2's: a 38.14 Hz high-pass.
    static let highPassFrequency: Double = 38.13547087602444
    static let highPassQ: Double = 0.5003270373238773

    static func shelfCoefficients(sampleRate: Double) -> Biquad {
        let k = tan(.pi * shelfFrequency / sampleRate)
        let vh = pow(10, shelfGainDB / 20)
        // The shelf's mid-band term. The exponent is the standard's own, and it is what makes
        // the derived table match the published one to the digit.
        let vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / shelfQ + k * k
        return Biquad(b0: (vh + vb * k / shelfQ + k * k) / a0,
                      b1: 2 * (k * k - vh) / a0,
                      b2: (vh - vb * k / shelfQ + k * k) / a0,
                      a1: 2 * (k * k - 1) / a0,
                      a2: (1 - k / shelfQ + k * k) / a0)
    }

    static func highPassCoefficients(sampleRate: Double) -> Biquad {
        let k = tan(.pi * highPassFrequency / sampleRate)
        let a0 = 1 + k / highPassQ + k * k
        return Biquad(b0: 1, b1: -2, b2: 1,
                      a1: 2 * (k * k - 1) / a0,
                      a2: (1 - k / highPassQ + k * k) / a0)
    }
}

// MARK: - reading a recording

extension Loudness {
    /// **The recording's own level, read from the file rather than from a composed asset.**
    ///
    /// Two reasons, and the second matters more. `AVAsset` is not `Sendable`, so an asset a
    /// caller already holds cannot also be handed here without the compiler objecting. And
    /// levelling should not move every time an edit does: measuring the cut asset would change
    /// the answer when a loud passage is trimmed, so the microphone's level would drift as a
    /// person works. `AudioMixBuilder.trackOrder` is the order a composition keeps, so the
    /// indices line up either way.
    public nonisolated static func measure(contentsOf url: URL) async -> [Int: Reading] {
        await measure(AVURLAsset(url: url))
    }

    /// **The integrated loudness of each audio track of `asset`, by track index.**
    ///
    /// Keyed by index because that is the only thing identifying a master's audio tracks —
    /// `AVAssetTrack` carries no name, and the order is the writer's, which
    /// `AudioMixBuilder.trackOrder` names. A track that could not be read, or that is silence,
    /// is absent rather than present with a very negative number.
    ///
    /// **Streaming through `Meter`, so a long recording is never held in memory**: half an hour
    /// of stereo float PCM is over 600 MB, and this keeps 400 ms of it.
    ///
    /// `nonisolated` and taking a `sending` asset for `AudioMixBuilder.apply`'s reason.

    public nonisolated static func measure(_ asset: sending AVAsset) async -> [Int: Reading] {
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio) else { return [:] }
        var measured: [Int: Reading] = [:]
        for (index, track) in tracks.enumerated() {
            if let value = await measure(track: track, of: asset) { measured[index] = value }
        }
        return measured
    }

    /// One track, read start to finish. `nil` when the reader refuses, the format is not one
    /// this can describe, or nothing passed the gates.
    static func measure(track: AVAssetTrack, of asset: AVAsset) async -> Reading? {
        guard let descriptions = try? await track.load(.formatDescriptions),
              let description = descriptions.first,
              let basic = description.audioStreamBasicDescription else { return nil }
        let sampleRate = basic.mSampleRate
        let channels = Int(basic.mChannelsPerFrame)
        guard sampleRate > 0, channels > 0 else { return nil }

        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        // Interleaved 32-bit float, at the track's own rate: `Meter` derives its filter for
        // whatever rate it is given, so nothing here has to resample.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }

        var meter = Meter(sampleRate: sampleRate, channels: channels)
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            guard bytes >= MemoryLayout<Float>.size else { continue }
            var samples = [Float](repeating: 0, count: bytes / MemoryLayout<Float>.size)
            // Safe here: the destination is exactly `bytes` long by construction one line up,
            // the pointer is used only inside `withUnsafeMutableBytes`'s scope, and the copy is
            // the framework's own bounded one rather than a raw read of the block's storage.
            let copied = unsafe samples.withUnsafeMutableBytes { buffer -> OSStatus in
                guard let base = unsafe buffer.baseAddress else { return -1 }
                return unsafe CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes,
                                                         destination: base)
            }
            guard copied == noErr else { continue }
            meter.append(samples)
        }
        guard reader.status == .completed || reader.status == .cancelled else { return nil }
        return meter.reading()
    }
}
