import Testing
import Foundation
@testable import Soredemo

/// **"Hears nothing" is no signal, not no speech.** The notch says so after five unbroken seconds
/// of either nothing arriving or everything arriving below −80 dBFS. `docs/design/2026-09-28-notch-
/// marks-and-audio-warnings.md`.
@Suite struct MicrophoneSilenceWatchTests {
    /// Twenty ticks a second, as `RecordingCoordinator.clock` runs.
    private let tick = 0.05

    private func run(_ watch: inout MicrophoneSilenceWatch, seconds: Double,
                     delivered: (Int) -> Int, rms: Double?) -> Bool {
        var silent = false
        for step in 0..<Int((seconds / tick).rounded()) {
            silent = watch.observe(delivered: delivered(step), latestRMS: rms, over: tick)
        }
        return silent
    }

    @Test func aMicrophoneHearingARoomIsNeverCalledSilent() {
        var watch = MicrophoneSilenceWatch()
        // −60 dBFS: a quiet room through a working microphone, well above the floor.
        #expect(!run(&watch, seconds: 30, delivered: { $0 + 1 }, rms: 0.001))
    }

    /// Digital silence — a muted interface, the wrong input — arrives as buffers of zeros.
    @Test func buffersOfNothingForFiveSecondsAreSilence() {
        var watch = MicrophoneSilenceWatch()
        // 99 ticks is 4.95 s — not yet. The hundredth reaches five seconds exactly.
        #expect(!run(&watch, seconds: 4.95, delivered: { $0 + 1 }, rms: 0.00005))
        let silent = watch.observe(delivered: 1_000, latestRMS: 0.00005, over: tick)
        #expect(silent)
    }

    /// **The case the level alone cannot see.** A device that stops delivering leaves the last
    /// buffer's RMS where it was — here a loud one — so only the count not moving says anything.
    @Test func noBuffersArrivingIsSilenceWhateverTheLastLevelWas() {
        var watch = MicrophoneSilenceWatch()
        // The first tick sees seven buffers arrive, loud; the hundred after it see none.
        #expect(!run(&watch, seconds: 0.05, delivered: { _ in 7 }, rms: 0.3))
        #expect(!run(&watch, seconds: 4.95, delivered: { _ in 7 }, rms: 0.3))
        let silent = watch.observe(delivered: 7, latestRMS: 0.3, over: tick)
        #expect(silent)
    }

    @Test func oneHeardBufferStartsThePatienceAgain() {
        var watch = MicrophoneSilenceWatch()
        #expect(!run(&watch, seconds: 4, delivered: { $0 + 1 }, rms: 0))
        let silent = watch.observe(delivered: 10_000, latestRMS: 0.01, over: tick)
        #expect(!silent)
        #expect(!run(&watch, seconds: 4, delivered: { 20_000 + $0 }, rms: 0))
    }

    /// A buffer this app could not read the level of says nothing either way, and unknown resolves
    /// to no warning — a warning that fires on a working microphone teaches people to ignore it.
    @Test func anUnreadableLevelIsNotCalledSilence() {
        var watch = MicrophoneSilenceWatch()
        #expect(!run(&watch, seconds: 10, delivered: { $0 + 1 }, rms: nil))
    }

    /// The clock does not tick while paused, and a resumed take starts its patience again.
    @Test func resettingForgetsTheQuietSoFar() {
        var watch = MicrophoneSilenceWatch()
        #expect(!run(&watch, seconds: 4, delivered: { _ in 3 }, rms: nil))
        watch.reset()
        #expect(!run(&watch, seconds: 4, delivered: { _ in 3 }, rms: nil))
    }
}

/// **What counts as "the speakers can be heard by the microphone"**, from the values Core Audio
/// reported on this machine (MacBook Pro, macOS 27, 2026-09-28): speakers `bltn`/`ispk`, the
/// microphone `bltn`. Headphones were not measured, so anything unread is `unknown` and gets no
/// hint.
@Suite struct EchoRiskTests {
    private func fourCC(_ text: String) -> UInt32 { text.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    @Test func theBuiltInSpeakersAreTheBuiltInTransportPlayingThroughTheInternalSpeaker() {
        #expect(AudioRoute.output(transport: fourCC("bltn"), dataSource: fourCC("ispk"), uid: nil) == .builtInSpeakers)
        // Built-in, but a different source — headphones on the jack report something other than ispk.
        #expect(AudioRoute.output(transport: fourCC("bltn"), dataSource: fourCC("hdpn"), uid: nil) == .other)
        #expect(AudioRoute.output(transport: fourCC("blue"), dataSource: nil, uid: nil) == .other)
        #expect(AudioRoute.output(transport: fourCC("bltn"), dataSource: nil, uid: nil) == .unknown)
        #expect(AudioRoute.output(transport: nil, dataSource: fourCC("ispk"), uid: nil) == .unknown)
    }

    /// **The identifier decides, because it is not translated.** Measured on this machine the
    /// speakers are `BuiltInSpeakerDevice` under the name "MacBook Pro的揚聲器"; a rule on the name
    /// works in one language. With the identifier, a data source that cannot be read no longer
    /// leaves the answer unknown.
    @Test func theSpeakersAreKnownByTheirIdentifierWhateverTheirName() {
        #expect(AudioRoute.output(transport: fourCC("bltn"), dataSource: nil,
                                  uid: "BuiltInSpeakerDevice") == .builtInSpeakers)
        // A built-in device that is not the speakers — the headphone jack is its own device on
        // Apple Silicon — is not the speakers, even with no data source to read.
        #expect(AudioRoute.output(transport: fourCC("bltn"), dataSource: nil,
                                  uid: "SomeOtherBuiltInOutput") == .other)
        // The measured source rule still holds when the identifier is something else.
        #expect(AudioRoute.output(transport: fourCC("bltn"), dataSource: fourCC("ispk"),
                                  uid: "SomeOtherBuiltInOutput") == .builtInSpeakers)
        // A virtual device in front of the speakers is not the speakers.
        #expect(AudioRoute.output(transport: fourCC("virt"), dataSource: nil,
                                  uid: "MSLoopbackDriverDevice_UID") == .other)
    }

    @Test func theMicrophoneIsBuiltInOnlyWhenItsTransportSaysSo() {
        #expect(AudioRoute.input(transport: fourCC("bltn")) == .builtIn)
        #expect(AudioRoute.input(transport: fourCC("usb ")) == .other)
        #expect(AudioRoute.input(transport: nil) == .unknown)
    }

    @Test func onlyBuiltInToBuiltInIsARisk() {
        #expect(AudioRoute.speakersReachTheMicrophone(input: .builtIn, output: .builtInSpeakers))
        #expect(!AudioRoute.speakersReachTheMicrophone(input: .builtIn, output: .other))
        #expect(!AudioRoute.speakersReachTheMicrophone(input: .builtIn, output: .unknown))
        #expect(!AudioRoute.speakersReachTheMicrophone(input: .other, output: .builtInSpeakers))
        #expect(!AudioRoute.speakersReachTheMicrophone(input: .unknown, output: .builtInSpeakers))
    }
}
