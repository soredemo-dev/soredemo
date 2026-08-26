import Foundation

/// **Takes the room out of a recording, using the silences this app already knows how to find.**
///
/// A demo recorded in an ordinary room carries the room: a fan, a laptop under load, the hum of a
/// building's air handling. It is quiet enough to ignore while recording and loud enough to hear
/// on playback, and it is the single most common reason a good take sounds amateur.
///
/// ### Why this is written here rather than taken from a package
///
/// Apple ships nothing usable. Measured, in this order:
///
///   * `AVAudioInputNode.setVoiceProcessingEnabled(true)` is **refused in manual-rendering
///     mode** — `-10863` — and enabled only on a live device-rendering engine. An offline pass is
///     manual rendering by definition.
///   * The microphone arrives through **ScreenCaptureKit** (`captureMicrophone = true`), not
///     through `AVCaptureSession` or `AVAudioEngine`, so there is no graph to insert an audio
///     unit into even if one were allowed.
///   * `AVCaptureDevice`'s `voiceIsolation` microphone mode is a **system** setting. An app may
///     read it and may ask macOS to show the picker; it may not set it.
///
/// The obvious package — `soniqo/speech-swift`, which is what `a native editor` uses — was resolved
/// and measured rather than trusted. Its own page says the CoreML backend needs no MLX; its
/// manifest says `SpeechEnhancement` depends on `MLX` and `MLXNN` unconditionally, and resolving
/// it pulled **39 transitive packages** including an HTTP server framework, the whole NIO stack,
/// TLS, WhisperKit and a HuggingFace downloader. It also fails this package's own build:
/// `ARCHITECTURE.md` D6 rule 4 forbids any package dependency, because a dependency is the back
/// door around rule 1's import allow-list — and MLX plus an HTTP server is exactly what would
/// have come through it.
///
/// ### What this does, and what it cannot
///
/// Spectral subtraction. The recording is cut into overlapping windows; each is transformed;
/// an estimate of the noise's magnitude is subtracted from each bin; the phase is kept; the
/// windows are added back together.
///
/// **It removes STATIONARY noise — sound that is there the whole time and does not change
/// much.** Fans, hum, hiss, air conditioning. It does **not** remove a door slamming, a keyboard,
/// a cough, or someone talking in the next room: those are not in the profile, so they are not
/// subtracted, and a system that claimed otherwise would be lying about what it measured. This is
/// the honest limit of doing it without a trained model, and it is stated here rather than
/// discovered by somebody whose dog barked.
///
/// ### The profile comes from measured silence, not from the first half-second
///
/// The usual shortcut is to assume the first 500 ms is noise. It very often is not — people start
/// talking immediately, and the countdown means the first moment of a Soredemo recording is
/// whatever was on screen when they pressed record.
///
/// This app already knows where the quiet is: `SilenceFinder` finds it, for the feature that cuts
/// dead air. The same spans are the right place to measure a room, and they are spread across the
/// whole recording rather than concentrated at one end — so a fan that starts up halfway through
/// is still in the estimate.
///
/// **A recording with no measurable silence gets no profile and no processing**, and says so with
/// a `nil` rather than inventing a noise estimate from speech and subtracting it — which is how
/// this kind of code makes a voice sound like a robot.
///
/// ### Deterministic, and therefore in the pure tier
///
/// No clock, no randomness, no platform framework — D6 rule 3 and rule 1. The transform is
/// written out below rather than taken from Accelerate, because `Overlays` imports Foundation
/// only and because a transform that can be read is a transform that can be checked against a
/// direct DFT, which `NoiseReductionTests` does.
public enum NoiseReduction {
    // MARK: - the shape of the analysis

    /// Samples per analysis window. 1024 at 48 kHz is 21.3 ms — long enough for the bins to
    /// resolve a hum's fundamental (46.9 Hz per bin), short enough that a consonant is not
    /// smeared across the whole window. **Uncalibrated**, but bounded on both sides by that
    /// trade rather than picked.
    public static let windowSize = 1024
    /// Samples between window starts. Half the window: a Hann window at 50% overlap sums to
    /// exactly 1 everywhere (the COLA condition), so a pass that changes nothing returns the
    /// input unchanged rather than something that merely resembles it. `theIdentityPassIsExact`
    /// is that claim as a test.
    public static let hopSize = 512

    /// How much of the estimated noise to remove, and how much of the original to keep no matter
    /// what.
    public struct Settings: Hashable, Sendable, Codable {
        /// The over-subtraction factor. **Above 1 on purpose**: an average is exceeded half the
        /// time, so subtracting exactly the average leaves half the frames with audible residue.
        /// Higher values remove more noise and take more of the voice with it.
        public var strength: Double
        /// The spectral floor, as a fraction of the original bin. **This is the setting that
        /// decides whether the result sounds processed.** Subtracting down to zero leaves
        /// isolated surviving bins that flicker on and off between windows — "musical noise", a
        /// warbling that is more distracting than the hum it replaced. Keeping a small fraction
        /// of every bin gives the residue somewhere to sit.
        public var floor: Double

        /// **Uncalibrated.** 1.5 and 0.06 are the middle of the range the literature uses for
        /// speech; they were chosen to be conservative, because a recording that still has a
        /// faint fan is recoverable and one with a robot voice is not.
        public static let `default` = Settings(strength: 1.5, floor: 0.06)

        public init(strength: Double, floor: Double) {
            // Clamped rather than trapped: these arrive from a slider and from a decoder, and
            // D6 rule 8 forbids trapping on an untrusted input.
            self.strength = Swift.min(Swift.max(strength.isFinite ? strength : 1.5, 0), 4)
            self.floor = Swift.min(Swift.max(floor.isFinite ? floor : 0.06, 0.001), 1)
        }

        /// **Validated on decode** (D6 rule 8). The synthesised `Decodable` assigns stored
        /// properties directly and never calls the initialiser above, so a project file could
        /// otherwise carry a floor of zero and produce the musical noise the floor exists to
        /// prevent.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(strength: try container.decodeIfPresent(Double.self, forKey: .strength) ?? 1.5,
                      floor: try container.decodeIfPresent(Double.self, forKey: .floor) ?? 0.06)
        }
    }

    /// The room, measured: an average magnitude for each frequency bin.
    ///
    /// Half the window plus one, because a real signal's transform is symmetric and the second
    /// half carries nothing the first does not.
    public struct Profile: Hashable, Sendable {
        public let magnitudes: [Double]
        /// How many windows went into the average. Carried because a profile from two windows is
        /// a much weaker claim than one from two hundred, and a caller may want to refuse it.
        public let windowsMeasured: Int

        public init(magnitudes: [Double], windowsMeasured: Int) {
            self.magnitudes = magnitudes
            self.windowsMeasured = windowsMeasured
        }
    }

    /// The fewest quiet windows worth averaging. Below this the estimate is dominated by whatever
    /// happened to be in one or two windows, and subtracting it is closer to random than to noise
    /// removal. **Uncalibrated**; 8 windows is about 90 ms of measured quiet.
    public static let minimumProfileWindows = 8

    // MARK: - measuring the room

    /// Averages the magnitude spectrum over the windows that fall entirely inside `quiet`.
    ///
    /// `quiet` is half-open sample ranges — the caller converts from whatever it has, because a
    /// `Nanoseconds` span means nothing without a sample rate and this type deliberately has no
    /// opinion about time.
    ///
    /// **Entirely inside, not overlapping.** A window straddling the edge of a silence contains
    /// the attack of whatever ended it, and averaging that into the room's profile means
    /// subtracting a fragment of speech from every window in the recording.
    ///
    /// Returns `nil` when there is not enough measured quiet — a named refusal, so a caller
    /// cannot mistake "no noise found" for "no noise".
    public static func profile(samples: [Float], quiet: [Range<Int>]) -> Profile? {
        guard samples.count >= windowSize, !quiet.isEmpty else { return nil }
        let window = hann(windowSize)
        var sum = [Double](repeating: 0, count: windowSize / 2 + 1)
        var measured = 0

        for span in quiet {
            let lower = Swift.max(span.lowerBound, 0)
            let upper = Swift.min(span.upperBound, samples.count)
            guard upper - lower >= windowSize else { continue }
            var start = lower
            while start + windowSize <= upper {
                var real = [Double](repeating: 0, count: windowSize)
                var imaginary = [Double](repeating: 0, count: windowSize)
                for i in 0..<windowSize { real[i] = Double(samples[start + i]) * window[i] }
                transform(real: &real, imaginary: &imaginary, inverse: false)
                for bin in 0...(windowSize / 2) {
                    sum[bin] += (real[bin] * real[bin] + imaginary[bin] * imaginary[bin]).squareRoot()
                }
                measured += 1
                start += hopSize
            }
        }
        guard measured >= minimumProfileWindows else { return nil }
        return Profile(magnitudes: sum.map { $0 / Double(measured) }, windowsMeasured: measured)
    }

    // MARK: - taking it out

    /// Subtracts `profile` from `samples` and returns the result, the same length as the input.
    ///
    /// **The same length, always.** Callers line this up against a video track, and a pass that
    /// returned a slightly different number of samples would put the audio out of sync by however
    /// much padding the windowing happened to need.
    public static func reduced(samples: [Float], profile: Profile,
                               settings: Settings = .default) -> [Float] {
        guard samples.count >= windowSize,
              profile.magnitudes.count == windowSize / 2 + 1 else { return samples }
        let window = hann(windowSize)

        // **Padded at both ends so that every real sample is PROCESSED, not so that it is loud
        // enough.**
        //
        // The first draft of this comment said the padding prevents a fade-in at the start. It
        // does not — the running `weight` below divides the overlap-add sum back out, so the
        // amplitude is right however few windows cover a sample. A mutation test set `pad` to 0
        // and the fade-in check stayed green, which is how the claim was found to be wrong.
        //
        // What the padding actually prevents: with no lead-in, sample 0 is covered by exactly one
        // window, at its own first tap — and a Hann window's first tap is 0. The weight there is
        // zero, so the guard below hands back the INPUT sample untouched. The recording would
        // keep its noise for the first few milliseconds, at full volume, which is a defect that
        // no amplitude check can see.
        let pad = windowSize
        var padded = [Float](repeating: 0, count: pad + samples.count + pad + windowSize)
        for i in 0..<samples.count { padded[pad + i] = samples[i] }

        var output = [Double](repeating: 0, count: padded.count)
        var weight = [Double](repeating: 0, count: padded.count)

        var start = 0
        while start + windowSize <= padded.count {
            var real = [Double](repeating: 0, count: windowSize)
            var imaginary = [Double](repeating: 0, count: windowSize)
            for i in 0..<windowSize { real[i] = Double(padded[start + i]) * window[i] }
            transform(real: &real, imaginary: &imaginary, inverse: false)

            // The spectrum is symmetric for a real signal, so bins above the midpoint are set
            // from their mirror rather than computed — and must be, or the inverse transform
            // returns something complex.
            for bin in 0...(windowSize / 2) {
                let magnitude = (real[bin] * real[bin] + imaginary[bin] * imaginary[bin]).squareRoot()
                guard magnitude > 0 else { continue }
                let wanted = magnitude - settings.strength * profile.magnitudes[bin]
                // `max(wanted, floor × magnitude)`: the floor is a fraction of THIS bin, not an
                // absolute level, so a loud passage keeps proportionally more than a quiet one.
                let kept = Swift.max(wanted, settings.floor * magnitude)
                let gain = kept / magnitude
                real[bin] *= gain
                imaginary[bin] *= gain
                if bin > 0 && bin < windowSize / 2 {
                    real[windowSize - bin] = real[bin]
                    imaginary[windowSize - bin] = -imaginary[bin]
                }
            }
            transform(real: &real, imaginary: &imaginary, inverse: true)
            for i in 0..<windowSize {
                // Windowed again on the way out. Analysis-and-synthesis windowing squares the
                // Hann, which no longer sums to 1 — so the running weight below divides it back
                // out rather than assuming COLA holds.
                output[start + i] += real[i] * window[i]
                weight[start + i] += window[i] * window[i]
            }
            start += hopSize
        }

        var result = [Float](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            let w = weight[pad + i]
            // A weight of zero cannot happen inside the padded region with this hop, but a
            // caller changing `hopSize` could make it happen, and dividing by it would return
            // infinities into somebody's audio track.
            guard w > 1e-9 else { result[i] = samples[i]; continue }
            let value = output[pad + i] / w
            result[i] = Float(Swift.min(Swift.max(value, -1), 1))
        }
        return result
    }

    // MARK: - the transform, written out

    /// A Hann window. Periodic (`/ n`) rather than symmetric (`/ (n-1)`): the periodic form is
    /// the one that satisfies COLA at 50% overlap, and the symmetric form — the more commonly
    /// written of the two — does not.
    static func hann(_ n: Int) -> [Double] {
        (0..<n).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n)) }
    }

    /// In-place radix-2 Cooley-Tukey, forward and inverse.
    ///
    /// **Written out rather than taken from Accelerate**, because `Overlays` is the pure tier and
    /// imports Foundation only (D6 rule 1). It is also the only form in which the thing can be
    /// checked: `NoiseReductionTests` compares it bin for bin against a direct O(n²) DFT, which
    /// is slow, obviously correct, and would catch a transposed sign that no amount of listening
    /// would.
    ///
    /// The inverse divides by `n`, so `transform(inverse: true)` after `transform(inverse: false)`
    /// returns the input rather than the input times the window size.
    static func transform(real: inout [Double], imaginary: inout [Double], inverse: Bool) {
        let n = real.count
        guard n > 1, n & (n - 1) == 0 else { return }

        // Bit-reversal permutation.
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 { j ^= bit; bit >>= 1 }
            j |= bit
            if i < j {
                real.swapAt(i, j)
                imaginary.swapAt(i, j)
            }
        }

        var length = 2
        while length <= n {
            let angle = (inverse ? 2 : -2) * Double.pi / Double(length)
            let stepReal = cos(angle)
            let stepImaginary = sin(angle)
            var i = 0
            while i < n {
                var wReal = 1.0
                var wImaginary = 0.0
                for k in 0..<(length / 2) {
                    let a = i + k
                    let b = a + length / 2
                    let tReal = real[b] * wReal - imaginary[b] * wImaginary
                    let tImaginary = real[b] * wImaginary + imaginary[b] * wReal
                    real[b] = real[a] - tReal
                    imaginary[b] = imaginary[a] - tImaginary
                    real[a] += tReal
                    imaginary[a] += tImaginary
                    let nextReal = wReal * stepReal - wImaginary * stepImaginary
                    wImaginary = wReal * stepImaginary + wImaginary * stepReal
                    wReal = nextReal
                }
                i += length
            }
            length <<= 1
        }

        if inverse {
            for i in 0..<n {
                real[i] /= Double(n)
                imaginary[i] /= Double(n)
            }
        }
    }
}
