import Foundation
import Testing
@testable import Overlays

/// The room-removal pass, on signals whose answer is known before the code runs.
///
/// **This is the argument for having written the DSP instead of taking a model.** A trained
/// denoiser can only be judged by listening; this one can be handed a sine wave plus a known hum
/// and asked, in numbers, whether the hum went and the sine stayed.
@Suite struct NoiseReductionTests {
    private let rate = 48_000.0

    /// A pure tone at `hz`, `seconds` long.
    private func tone(_ hz: Double, seconds: Double, amplitude: Double = 0.5) -> [Float] {
        (0..<Int(seconds * rate)).map {
            Float(amplitude * sin(2 * .pi * hz * Double($0) / rate))
        }
    }

    /// The energy in `samples` at `hz`, by direct projection onto that frequency — no FFT, so a
    /// bug in the transform cannot hide a bug in the subtraction.
    private func energy(of samples: [Float], at hz: Double) -> Double {
        var real = 0.0, imaginary = 0.0
        for (i, sample) in samples.enumerated() {
            let angle = 2 * Double.pi * hz * Double(i) / rate
            real += Double(sample) * cos(angle)
            imaginary += Double(sample) * sin(angle)
        }
        return (real * real + imaginary * imaginary).squareRoot() / Double(samples.count)
    }

    // MARK: - the transform itself

    /// **Checked against a direct DFT, bin for bin.** The fast transform is the one piece here a
    /// person cannot check by reading, and a transposed sign in it would produce output that
    /// sounds plausible and is wrong.
    @Test func theFastTransformAgreesWithADirectOne() {
        let n = 64
        var real = (0..<n).map { sin(2 * Double.pi * 5 * Double($0) / Double(n)) + 0.3 * Double($0 % 7) }
        var imaginary = [Double](repeating: 0, count: n)
        let input = real

        NoiseReduction.transform(real: &real, imaginary: &imaginary, inverse: false)

        for bin in 0..<n {
            var directReal = 0.0, directImaginary = 0.0
            for i in 0..<n {
                let angle = -2 * Double.pi * Double(bin) * Double(i) / Double(n)
                directReal += input[i] * cos(angle)
                directImaginary += input[i] * sin(angle)
            }
            #expect(abs(real[bin] - directReal) < 1e-9,
                    "bin \(bin) real: fast \(real[bin]), direct \(directReal)")
            #expect(abs(imaginary[bin] - directImaginary) < 1e-9,
                    "bin \(bin) imaginary: fast \(imaginary[bin]), direct \(directImaginary)")
        }
    }

    /// Forward then inverse returns the input — so the inverse's `/ n` is there and is applied
    /// once. Without it every pass would multiply the recording by 1024.
    @Test func theInverseTransformUndoesTheForwardOne() {
        let n = 128
        let input = (0..<n).map { sin(Double($0) * 0.37) * 0.8 }
        var real = input
        var imaginary = [Double](repeating: 0, count: n)
        NoiseReduction.transform(real: &real, imaginary: &imaginary, inverse: false)
        NoiseReduction.transform(real: &real, imaginary: &imaginary, inverse: true)
        for i in 0..<n {
            #expect(abs(real[i] - input[i]) < 1e-9, "sample \(i): \(real[i]) vs \(input[i])")
        }
    }

    /// The window is the PERIODIC Hann, which is what sums to 1 at 50% overlap. The symmetric
    /// form — `/(n-1)`, the one written more often — does not, and a pass built on it leaves a
    /// ripple at the hop rate through the whole recording.
    @Test func theWindowIsThePeriodicHannSoOverlapAddSumsToOne() {
        let window = NoiseReduction.hann(NoiseReduction.windowSize)
        #expect(window[0] == 0)
        let hop = NoiseReduction.hopSize
        for offset in 0..<hop {
            let sum = window[offset] + window[offset + hop]
            #expect(abs(sum - 1) < 1e-12, "offset \(offset) sums to \(sum), not 1")
        }
    }

    // MARK: - measuring the room

    @Test func aRecordingWithNoMeasuredSilenceGetsNoProfile() {
        let speech = tone(440, seconds: 1)
        #expect(NoiseReduction.profile(samples: speech, quiet: []) == nil)
    }

    /// **A named refusal, not a weak answer.** Two windows of quiet is an estimate dominated by
    /// whatever happened to be in two windows, and subtracting it is closer to random than to
    /// noise removal.
    @Test func tooLittleMeasuredSilenceIsRefusedRatherThanAveraged() {
        let samples = tone(120, seconds: 1)
        let barelyEnough = NoiseReduction.windowSize + NoiseReduction.hopSize
        #expect(NoiseReduction.profile(samples: samples, quiet: [0..<barelyEnough]) == nil,
                "a two-window profile was accepted")
        let plenty = NoiseReduction.windowSize
            + NoiseReduction.hopSize * NoiseReduction.minimumProfileWindows
        let profile = NoiseReduction.profile(samples: samples, quiet: [0..<plenty])
        #expect(profile != nil, "enough quiet was still refused")
        #expect((profile?.windowsMeasured ?? 0) >= NoiseReduction.minimumProfileWindows)
    }

    /// **Only windows entirely inside the span.** One straddling the edge holds the attack of
    /// whatever ended the silence, and averaging that into the room means subtracting a fragment
    /// of somebody's voice from every window in the recording.
    @Test func aWindowStraddlingTheEdgeOfASilenceIsNotMeasured() {
        // Silent for exactly nine hops' worth, then a loud tone. A profile that included the
        // straddling window would carry the tone's energy.
        let quietLength = NoiseReduction.windowSize + NoiseReduction.hopSize * 9
        var samples = [Float](repeating: 0, count: quietLength)
        samples += tone(1000, seconds: 0.5, amplitude: 0.9)
        let profile = NoiseReduction.profile(samples: samples, quiet: [0..<quietLength])
        let measured = try? #require(profile)
        let total = measured?.magnitudes.reduce(0, +) ?? 1
        #expect(total < 1e-6, """
            the profile of pure digital silence has energy \(total) — a window overlapping the \
            tone that follows was averaged in
            """)
    }

    // MARK: - taking it out

    /// **The identity pass is exact.** With a zero profile every bin's gain is 1, so what comes
    /// back is the windowing and overlap-add alone. If reconstruction is wrong, it is wrong here,
    /// on a signal with no noise in it to blame.
    @Test func theIdentityPassReturnsTheRecordingUnchanged() {
        let input = tone(440, seconds: 0.5) 
        let zero = NoiseReduction.Profile(
            magnitudes: [Double](repeating: 0, count: NoiseReduction.windowSize / 2 + 1),
            windowsMeasured: 100)
        let output = NoiseReduction.reduced(samples: input, profile: zero)
        #expect(output.count == input.count)
        var worst = 0.0
        for i in input.indices { worst = max(worst, Double(abs(output[i] - input[i]))) }
        #expect(worst < 1e-5, "the identity pass changed a sample by \(worst)")
    }

    /// **Every sample is processed, including the first one.**
    ///
    /// This replaced a check that the first window was not quieter than the middle, which was
    /// testing the wrong property: the running weight divides the overlap-add sum back out, so
    /// the amplitude is right however few windows cover a sample. Setting the padding to zero
    /// left that check green.
    ///
    /// What zero padding really does: sample 0 is then covered by one window at its own first
    /// tap, a Hann window's first tap is 0, the weight is zero, and the guard hands back the
    /// INPUT sample untouched — so the recording keeps its noise, at full volume, for the first
    /// few milliseconds. Loud, not quiet, which is why the old check could not see it.
    @Test func theFirstSamplesAreProcessedRatherThanPassedThrough() {
        let input = tone(440, seconds: 0.5)
        // A profile with real energy in it, so processing visibly changes every sample.
        let loud = NoiseReduction.Profile(
            magnitudes: [Double](repeating: 20, count: NoiseReduction.windowSize / 2 + 1),
            windowsMeasured: 100)
        let output = NoiseReduction.reduced(samples: input, profile: loud)
        let untouched = (0..<NoiseReduction.hopSize).filter { output[$0] == input[$0] }
        #expect(untouched.isEmpty, """
            \(untouched.count) of the first \(NoiseReduction.hopSize) samples came back \
            byte-identical to the input — they fell through the zero-weight guard unprocessed, \
            keeping their noise at full volume
            """)
    }

    /// **The load-bearing test: the hum goes and the voice stays.**
    ///
    /// A 60 Hz hum runs through the whole recording; a 1 kHz tone stands in for speech and is
    /// present only in the second half. The profile is measured from the first half, which is
    /// hum alone — exactly what `SilenceFinder` hands over in the real pipeline.
    @Test func theHumIsRemovedAndTheVoiceSurvives() throws {
        let humOnly = tone(60, seconds: 1.0, amplitude: 0.2)
        let withVoice = zip(tone(60, seconds: 1.0, amplitude: 0.2),
                            tone(1000, seconds: 1.0, amplitude: 0.5)).map { $0 + $1 }
        let samples = humOnly + withVoice

        let profile = try #require(NoiseReduction.profile(samples: samples,
                                                          quiet: [0..<humOnly.count]),
                                   "a second of hum was not enough to measure")
        let output = NoiseReduction.reduced(samples: samples, profile: profile)

        let voiceHalf = { (s: [Float]) in Array(s[humOnly.count...]) }
        let humBefore = energy(of: voiceHalf(samples), at: 60)
        let humAfter = energy(of: voiceHalf(output), at: 60)
        let voiceBefore = energy(of: voiceHalf(samples), at: 1000)
        let voiceAfter = energy(of: voiceHalf(output), at: 1000)

        #expect(humAfter < humBefore * 0.25, """
            the 60 Hz hum went from \(humBefore) to \(humAfter) — less than the 4× reduction \
            this is for
            """)
        #expect(voiceAfter > voiceBefore * 0.8, """
            the 1 kHz tone went from \(voiceBefore) to \(voiceAfter) — the voice is being taken \
            out with the room
            """)
    }

    /// The floor is what stops the residue flickering between windows. At a floor of 1 nothing is
    /// ever removed; at the default something is. Both directions, so the setting is known to be
    /// connected rather than merely present.
    @Test func theSpectralFloorDecidesHowMuchSurvives() throws {
        let samples = tone(60, seconds: 1.0, amplitude: 0.2)
            + zip(tone(60, seconds: 0.5, amplitude: 0.2), tone(1000, seconds: 0.5, amplitude: 0.5))
                .map { $0 + $1 }
        let quiet = 0..<Int(1.0 * rate)
        let profile = try #require(NoiseReduction.profile(samples: samples, quiet: [quiet]))

        let keptEverything = NoiseReduction.reduced(samples: samples, profile: profile,
                                                    settings: .init(strength: 1.5, floor: 1))
        let normal = NoiseReduction.reduced(samples: samples, profile: profile)
        let tail = { (s: [Float]) in Array(s[quiet.upperBound...]) }
        #expect(energy(of: tail(keptEverything), at: 60) > energy(of: tail(normal), at: 60), """
            a floor of 1 removed as much as the default floor, so the floor is not connected
            """)
    }

    // MARK: - the settings

    @Test func settingsClampRatherThanTrapOnAnythingAnywhereNearThem() {
        #expect(NoiseReduction.Settings(strength: .nan, floor: .nan).strength == 1.5)
        #expect(NoiseReduction.Settings(strength: .nan, floor: .nan).floor == 0.06)
        #expect(NoiseReduction.Settings(strength: 99, floor: 99).strength == 4)
        #expect(NoiseReduction.Settings(strength: -1, floor: -1).strength == 0)
        // **Never zero.** A floor of zero is what produces musical noise, and a project file is
        // an untrusted input that could carry one.
        #expect(NoiseReduction.Settings(strength: 1, floor: 0).floor == 0.001)
    }

    /// D6 rule 8: the synthesised `Decodable` assigns stored properties directly, so without an
    /// explicit `init(from:)` a project file could carry the zero floor the initialiser refuses.
    @Test func aDecodedSettingIsValidatedRatherThanTrusted() throws {
        let hostile = Data(#"{"strength": 500, "floor": 0}"#.utf8)
        let decoded = try JSONDecoder().decode(NoiseReduction.Settings.self, from: hostile)
        #expect(decoded.strength == 4)
        #expect(decoded.floor == 0.001)
        // And a file written before this setting existed decodes to the default.
        let old = try JSONDecoder().decode(NoiseReduction.Settings.self, from: Data("{}".utf8))
        #expect(old == NoiseReduction.Settings.default)
    }

    /// A recording shorter than one window comes back untouched rather than crashing or
    /// returning a different length — a five-frame clip is a thing the timeline can produce.
    @Test func aRecordingShorterThanOneWindowIsReturnedUnchanged() {
        let tiny = [Float](repeating: 0.3, count: 100)
        let profile = NoiseReduction.Profile(
            magnitudes: [Double](repeating: 0.1, count: NoiseReduction.windowSize / 2 + 1),
            windowsMeasured: 50)
        #expect(NoiseReduction.reduced(samples: tiny, profile: profile) == tiny)
    }
}
