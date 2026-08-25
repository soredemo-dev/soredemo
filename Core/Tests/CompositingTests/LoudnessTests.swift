import Testing
import Foundation
@testable import Compositing
import Project

/// **Measured against the standard's own numbers, not against itself.** Every expectation here
/// comes from ITU-R BS.1770-4 or EBU Tech 3341 — the published coefficient table, the −20 dBFS
/// conformance tone, the gates' behaviour — so a change to this file that still agreed with
/// itself would go red.

/// A sine at `amplitude`, interleaved across `channels` identical channels.
private func tone(hz: Double, amplitude: Double, seconds: Double,
                  sampleRate: Double = 48_000, channels: Int = 2) -> [Float] {
    let frames = Int(seconds * sampleRate)
    var samples = [Float](repeating: 0, count: frames * channels)
    for frame in 0..<frames {
        let value = Float(amplitude * sin(2 * .pi * hz * Double(frame) / sampleRate))
        for channel in 0..<channels { samples[frame * channels + channel] = value }
    }
    return samples
}

// MARK: - the filter

/// **The derivation reproduces the standard's published 48 kHz table.** BS.1770-4 prints the
/// coefficients at 48 kHz only, and this file derives them for whatever rate the audio really
/// has — a master's microphone track is passthrough and can arrive at 44.1 kHz. Deriving is
/// only safe if it agrees with the table where the table exists.
@Test func theDerivedCoefficientsReproduceTheStandardsTableAt48k() {
    let shelf = Loudness.shelfCoefficients(sampleRate: 48_000)
    #expect(abs(shelf.b0 - 1.53512485958697) < 1e-12, "b0 was \(shelf.b0)")
    #expect(abs(shelf.b1 - -2.69169618940638) < 1e-12, "b1 was \(shelf.b1)")
    #expect(abs(shelf.b2 - 1.19839281085285) < 1e-12, "b2 was \(shelf.b2)")
    #expect(abs(shelf.a1 - -1.69065929318241) < 1e-12, "a1 was \(shelf.a1)")
    #expect(abs(shelf.a2 - 0.73248077421585) < 1e-12, "a2 was \(shelf.a2)")

    let highPass = Loudness.highPassCoefficients(sampleRate: 48_000)
    #expect(abs(highPass.a1 - -1.99004745483398) < 1e-10, "a1 was \(highPass.a1)")
    #expect(abs(highPass.a2 - 0.99007225036621) < 1e-10, "a2 was \(highPass.a2)")
}

/// And it really is rate-dependent: the same filter at 44.1 kHz is a different set of numbers.
/// Without this, a derivation that ignored `sampleRate` and returned the table would pass the
/// test above and be wrong for every 44.1 kHz recording.
@Test func theCoefficientsDependOnTheSampleRate() {
    let at48 = Loudness.shelfCoefficients(sampleRate: 48_000)
    let at44 = Loudness.shelfCoefficients(sampleRate: 44_100)
    #expect(abs(at48.b0 - at44.b0) > 1e-6, "the shelf is the same at both rates: \(at48.b0)")
}

// MARK: - the measurement

/// **A 1 kHz tone at −20 dBFS RMS, in ONE channel, reads −20.0 LUFS.** The whole chain lands
/// on the number it started from: `−0.691 + 10·log₁₀(0.01)` is −20.69, and K-weighting's +0.7 dB
/// at 1 kHz brings it back. It exercises the filter, the 400 ms blocking, both gates and the
/// offset at once, and it is not a number chosen here — it falls out of the standard's equation
/// and the standard's filter meeting.
///
/// **Mono, and the first draft of this test made it stereo and was wrong by exactly 3.017 dB.**
/// BS.1770 sums the weighted POWER of each channel, so the same signal in two channels is
/// `10·log₁₀2` louder than in one. That is the standard working, not a defect — and it is
/// pinned on its own below, because a reading that silently ignored the second channel would
/// otherwise pass this test.
@Test func aMinusTwentyDBFSToneReadsMinusTwentyLUFS() throws {
    let amplitude = pow(10.0, -20.0 / 20.0) * sqrt(2.0)   // −20 dBFS RMS, so peak is ×√2
    let measured = try #require(Loudness.integrated(samples: tone(hz: 1_000, amplitude: amplitude,
                                                                 seconds: 5, channels: 1),
                                                    sampleRate: 48_000, channels: 1))
    #expect(abs(measured - -20) < 0.15, "a −20 dBFS 1 kHz mono tone measured \(measured) LUFS")
}

/// **The same signal in two channels is 10·log₁₀2 louder than in one**, because BS.1770 §4 sums
/// `G_i · z_i` over the channels and gives left and right a weight of 1.0 each. A measurement
/// that averaged the channels instead — the obvious alternative, and the one that "feels"
/// right — would read the same for both and fail here.
@Test func theStereoSumIsThreeDecibelsOverTheSameSignalInMono() throws {
    let amplitude = 0.2
    let mono = try #require(Loudness.integrated(samples: tone(hz: 1_000, amplitude: amplitude,
                                                              seconds: 4, channels: 1),
                                                sampleRate: 48_000, channels: 1))
    let stereo = try #require(Loudness.integrated(samples: tone(hz: 1_000, amplitude: amplitude,
                                                                seconds: 4, channels: 2),
                                                  sampleRate: 48_000, channels: 2))
    #expect(abs((stereo - mono) - 10 * log10(2.0)) < 0.01,
            "mono \(mono), stereo \(stereo) — the channels are not being summed")
}

/// Doubling the amplitude is +6 dB, and loudness is a decibel scale — so the reading moves by
/// six. A measurement that had the offset or the log base wrong would still pass the tone test
/// alone if it were wrong by a constant; this one would not.
@Test func doublingTheAmplitudeRaisesTheReadingBySixDecibels() throws {
    let quiet = try #require(Loudness.integrated(samples: tone(hz: 1_000, amplitude: 0.1, seconds: 4),
                                                 sampleRate: 48_000, channels: 2))
    let loud = try #require(Loudness.integrated(samples: tone(hz: 1_000, amplitude: 0.2, seconds: 4),
                                                sampleRate: 48_000, channels: 2))
    #expect(abs((loud - quiet) - 6.0206) < 0.05, "\(quiet) → \(loud)")
}

/// Silence has no loudness, and saying so with `nil` is what stops a caller computing a gain
/// from a very negative number and multiplying a noise floor into a roar.
@Test func silenceMeasuresNothingRatherThanSomethingVeryNegative() {
    let silence = [Float](repeating: 0, count: 48_000 * 2)
    #expect(Loudness.integrated(samples: silence, sampleRate: 48_000, channels: 2) == nil)
}

/// **The gates are what make this a measurement of the speech rather than of the file.** Two
/// seconds of tone followed by eight of silence reads as the tone, not as a tenth of it: the
/// absolute gate drops the silent blocks entirely. Without gating the answer would be about
/// 7 LU lower, which is the whole reason BS.1770 has gates.
@Test func aLongSilenceDoesNotDragTheReadingDown() throws {
    let speech = tone(hz: 1_000, amplitude: 0.2, seconds: 2)
    let quiet = [Float](repeating: 0, count: 48_000 * 8 * 2)
    let alone = try #require(Loudness.integrated(samples: speech, sampleRate: 48_000, channels: 2))
    let padded = try #require(Loudness.integrated(samples: speech + quiet,
                                                  sampleRate: 48_000, channels: 2))
    #expect(abs(padded - alone) < 0.5, "\(alone) alone, \(padded) with eight seconds of silence")
}

/// A recording too short to hold one 400 ms block has nothing to measure.
@Test func audioShorterThanOneBlockMeasuresNothing() {
    let brief = tone(hz: 1_000, amplitude: 0.5, seconds: 0.2)
    #expect(Loudness.integrated(samples: brief, sampleRate: 48_000, channels: 2) == nil)
}

// MARK: - the gain

/// The gain is the difference in decibels, as a linear multiplier — and it is bounded, so a
/// near-silent recording cannot ask for an enormous one.
@Test func theGainMovesTheMeasurementToTheTargetAndIsBounded() {
    #expect(abs(Loudness.gain(from: -22, to: -16) - pow(10, 6.0 / 20)) < 1e-9)
    #expect(abs(Loudness.gain(from: -10, to: -16) - pow(10, -6.0 / 20)) < 1e-9)
    #expect(abs(Loudness.gain(from: -16, to: -16) - 1) < 1e-9)

    let fromNearSilence = Loudness.gain(from: -80, to: -16)
    #expect(abs(fromNearSilence - pow(10, Loudness.maximumAdjustmentDB / 20)) < 1e-9,
            "a 64 dB lift was not bounded to \(Loudness.maximumAdjustmentDB): \(fromNearSilence)")

    // Nothing measured is nothing to correct.
    #expect(Loudness.gain(from: nil, to: -16) == 1)
    #expect(Loudness.gain(from: -.infinity, to: -16) == 1)
}

// MARK: - streaming

/// **A recording arrives in sample buffers, and the answer must not depend on where they were
/// cut.** The filter carries state and the 400 ms blocks straddle buffer boundaries, so a meter
/// that reset either would read differently for the same audio depending on the decoder's
/// chunking — a difference nobody would ever see in a test that fed it one array. Fed in
/// awkward, uneven chunks, it agrees with the whole-signal reading to the last decimal.
@Test func theMeterAgreesWhateverTheBufferBoundariesAre() throws {
    let signal = tone(hz: 440, amplitude: 0.3, seconds: 3, channels: 2)
    let whole = try #require(Loudness.integrated(samples: signal, sampleRate: 48_000, channels: 2))

    var meter = Loudness.Meter(sampleRate: 48_000, channels: 2)
    // Uneven, deliberately: chunk sizes that are not multiples of the block or the step, so a
    // boundary lands inside a block rather than tidily between two.
    var offset = 0
    var size = 997 * 2
    while offset < signal.count {
        let end = min(offset + size, signal.count)
        meter.append(Array(signal[offset..<end]))
        offset = end
        size = size == 997 * 2 ? 4_099 * 2 : 997 * 2
    }
    let streamed = try #require(meter.integrated())
    #expect(abs(streamed - whole) < 1e-9, "whole \(whole), streamed \(streamed)")
}

/// A meter that has been given nothing has measured nothing — and an empty buffer is not an
/// error, because a decoder can hand one back at the end of a track.
@Test func aMeterGivenNothingMeasuresNothing() {
    var meter = Loudness.Meter(sampleRate: 48_000, channels: 2)
    #expect(meter.integrated() == nil)
    meter.append([])
    #expect(meter.integrated() == nil)
}

// MARK: - the volume a mix ends up setting

/// **Levelling multiplies the person's gain; it does not replace it.** Someone who levels and
/// then pulls the microphone to half means both, and a rule that took one or the other would
/// silently discard a slider they had just moved.
@Test func levellingMultipliesTheChosenGain() {
    let levelled = AudioMix(gains: [.microphone: 0.5], targetLoudness: -16)
    let volume = AudioMixBuilder.volume(for: .microphone, in: levelled, measured: -22)
    // −22 → −16 is +6 dB, and the slider is at a half.
    #expect(abs(volume - 0.5 * pow(10, 6.0 / 20)) < 1e-9, "volume was \(volume)")
}

/// Off, or unmeasured, is the recorded level — and a muted source stays silent whatever it
/// measures, because muting is applied before levelling can multiply it.
@Test func levellingOffOrUnmeasuredLeavesTheLevelAlone() {
    let plain = AudioMix(gains: [.microphone: 0.8])
    #expect(abs(AudioMixBuilder.volume(for: .microphone, in: plain, measured: -30) - 0.8) < 1e-9)

    let levelled = AudioMix(gains: [.microphone: 0.8], targetLoudness: -16)
    #expect(abs(AudioMixBuilder.volume(for: .microphone, in: levelled, measured: nil) - 0.8) < 1e-9,
            "an unmeasured source was levelled from a measurement that does not exist")

    let muted = AudioMix(muted: [.microphone], targetLoudness: -16)
    #expect(AudioMixBuilder.volume(for: .microphone, in: muted, measured: -40) == 0,
            "a muted source was levelled back into audibility")
}

/// A track the recorder did not write is passed through untouched.
@Test func aTrackWithNoKnownSourceIsLeftAtUnity() {
    let levelled = AudioMix(gains: [.microphone: 0.2], targetLoudness: -16)
    #expect(AudioMixBuilder.volume(for: nil, in: levelled, measured: -40) == 1)
}

// MARK: - the target on the model

/// The target round-trips, is absent from a project that never levelled, and is clamped to a
/// range no published target sits outside — a value out of range is a corrupt file or a typo.
@Test func theLoudnessTargetRoundTripsAndIsClamped() throws {
    let levelled = AudioMix.unchanged.settingTargetLoudness(-14)
    let data = try JSONEncoder().encode(levelled)
    #expect(try JSONDecoder().decode(AudioMix.self, from: data) == levelled)
    #expect(levelled.changesAnything, "a levelled mix reports itself unchanged")

    let off = AudioMix.unchanged
    let offData = try JSONEncoder().encode(off)
    #expect(!String(decoding: offData, as: UTF8.self).contains("targetLoudness"),
            "a project that never levelled wrote a target anyway")

    #expect(AudioMix(targetLoudness: 100).targetLoudness == AudioMix.loudestTarget)
    #expect(AudioMix(targetLoudness: -999).targetLoudness == AudioMix.quietestTarget)
    #expect(AudioMix(targetLoudness: .nan).targetLoudness == nil)
}

/// Setting a gain or a mute keeps the target — the first draft of `setting(_:gain:)` rebuilt
/// the mix without it, which silently turned levelling off the moment a slider moved.
@Test func changingAGainKeepsTheTarget() {
    let levelled = AudioMix.unchanged.settingTargetLoudness(-16)
    #expect(levelled.setting(.microphone, gain: 0.5).targetLoudness == -16)
    #expect(levelled.setting(.microphone, muted: true).targetLoudness == -16)
}
