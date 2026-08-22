import Foundation
import Testing
@testable import Project

/// A master carries system audio and the microphone separately, and a person editing a demo
/// needs to turn one down without touching the other — background music under narration, or a
/// notification chime that should not have been recorded.
@Suite struct AudioMixTests {
    @Test func anUntouchedMixIsTheRecording() {
        let mix = AudioMix.unchanged
        #expect(!mix.changesAnything)
        for source in AudioMix.Source.allCases {
            #expect(mix.gain(for: source) == 1)
            #expect(!mix.isMuted(source))
            #expect(mix.effectiveGain(for: source) == 1)
        }
    }

    /// **Muting and a zero gain are different facts**, and keeping them apart is what lets a
    /// person unmute back to the level they had. A model that collapsed them would lose it.
    @Test func mutingIsNotTheSameAsAZeroGain() {
        let quiet = AudioMix().setting(.microphone, gain: 0.4)
        let muted = quiet.setting(.microphone, muted: true)

        #expect(muted.effectiveGain(for: .microphone) == 0, "a muted source must be silent")
        #expect(muted.gain(for: .microphone) == 0.4, "the level a person set was forgotten")

        let unmuted = muted.setting(.microphone, muted: false)
        #expect(unmuted.effectiveGain(for: .microphone) == 0.4)
    }

    /// `effectiveGain` exists so a caller has ONE number and cannot apply muting and gain in
    /// the wrong order.
    @Test func theEffectiveGainAppliesMutingAfterTheLevel() {
        let mix = AudioMix().setting(.systemAudio, gain: 2).setting(.systemAudio, muted: true)
        #expect(mix.effectiveGain(for: .systemAudio) == 0)
        #expect(mix.effectiveGain(for: .microphone) == 1, "the other source was affected")
    }

    /// A negative gain inverts the waveform, and 4× is the ceiling: past it a recording quiet
    /// enough to need the boost is mostly amplified noise floor.
    @Test func gainIsClampedOnTheWayIn() {
        #expect(AudioMix(gains: [.microphone: -3]).gain(for: .microphone) == 0)
        #expect(AudioMix(gains: [.microphone: 99]).gain(for: .microphone) == AudioMix.maximumGain)
    }

    @Test func changingAnythingIsWhatDecidesIfTheExportBuildsAMix() {
        #expect(!AudioMix().changesAnything)
        #expect(AudioMix().setting(.microphone, gain: 1).changesAnything == false,
                "setting a source to the level it already had is not a change")
        #expect(AudioMix().setting(.microphone, gain: 0.5).changesAnything)
        #expect(AudioMix().setting(.systemAudio, muted: true).changesAnything)
    }

    // MARK: - coding

    /// **A dictionary keyed by an enum does not round-trip readably through JSON by default** —
    /// Swift writes an array of alternating keys and values, which is legal and unreadable in a
    /// project file a person may open.
    @Test func aMixEncodesAsNamedSourcesAndRoundTrips() throws {
        let mix = AudioMix().setting(.microphone, gain: 0.5).setting(.systemAudio, muted: true)
        let data = try JSONEncoder().encode(mix)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"microphone\""), "the source is not named in the file: \(text)")
        #expect(text.contains("\"systemAudio\""))
        #expect(try JSONDecoder().decode(AudioMix.self, from: data) == mix)
    }

    /// D6 rule 8: the synthesised decoder would never call the clamping initialiser, so a
    /// corrupt file has to be rejected explicitly rather than producing an inverted waveform.
    @Test func aCorruptMixIsADecodingErrorAndNotASilentWrongLevel() {
        for json in [#"{"gains":{"nosuchsource":1.0},"muted":[]}"#,
                     #"{"gains":{"microphone":-1.0},"muted":[]}"#,
                     #"{"gains":{},"muted":["nosuchsource"]}"#] {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(AudioMix.self, from: Data(json.utf8))
            }
        }
    }

    /// An empty file is the unchanged mix, so a project written before this existed opens.
    @Test func anEmptyMixDecodesAsUnchanged() throws {
        let mix = try JSONDecoder().decode(AudioMix.self, from: Data("{}".utf8))
        #expect(mix == .unchanged)
    }

    @Test func everySourceHasAName() {
        for source in AudioMix.Source.allCases {
            #expect(!source.displayName.isEmpty)
        }
        #expect(AudioMix.Source.allCases.count == 2)
    }
}
