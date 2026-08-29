import Foundation
import Testing
@testable import Overlays

/// **Dragging a playhead in silence is the difference between finding a word and hunting for one.**
///
/// The engine belongs to the app tier; the arithmetic is here, because the two things that go
/// wrong are arithmetic: a grain cut past the end of what was read, and a grain that does not
/// fade. The second is the whole feature — without fades every grain begins and ends with a
/// click, and a drag is a click track.
@Suite("Scrub grains")
struct ScrubGrainTests {
    static let rate = 48_000.0

    /// A ramp, so a cut can be identified by its values: sample n has value n.
    static func ramp(_ count: Int) -> [Float] { (0..<count).map { Float($0) } }

    // MARK: - Where a grain comes from

    /// **Centred on the playhead, not started at it.** A grain that starts at the playhead plays
    /// the 50 ms AFTER where somebody is pointing, so the sound sits consistently ahead of the
    /// line they are dragging.
    @Test("a grain is centred on the playhead")
    func aGrainIsCentred() {
        let start = ScrubGrain.startSample(atSeconds: 1, sampleRate: Self.rate)
        // One second is sample 48000; half a 50 ms grain earlier is 48000 - 1200.
        #expect(start == 46_800)
    }

    /// The beginning of a recording would otherwise ask for samples before it.
    @Test("a grain at the very start does not ask for samples before the recording")
    func aGrainAtTheStartIsClamped() {
        #expect(ScrubGrain.startSample(atSeconds: 0, sampleRate: Self.rate) == 0)
        #expect(ScrubGrain.startSample(atSeconds: 0.001, sampleRate: Self.rate) == 0)
    }

    @Test("a nonsensical time or rate produces a grain rather than a crash")
    func degenerateInputs() {
        #expect(ScrubGrain.startSample(atSeconds: .nan, sampleRate: Self.rate) == 0)
        #expect(ScrubGrain.startSample(atSeconds: 1, sampleRate: 0) == 0)
        #expect(ScrubGrain.length(sampleRate: 0) == 1)
    }

    // MARK: - The cut

    /// **A real grain length, and the first version of this test used 100 samples.** At 48 kHz
    /// that is two milliseconds — shorter than two three-millisecond fades — so the grain was
    /// entirely fade and the "middle" was 98% of its value. The expectation was wrong, not the
    /// code, and the shape of the mistake is worth keeping: a grain shorter than its fades has no
    /// middle.
    @Test("a grain is cut from where it was asked for")
    func aGrainComesFromTheRightPlace() throws {
        let samples = Self.ramp(10_000)
        let length = ScrubGrain.length(sampleRate: Self.rate)   // 2400 at 48 kHz
        let grain = try #require(ScrubGrain.cut(from: samples, windowStart: 1_000,
                                                startSample: 2_000, length: length,
                                                sampleRate: Self.rate))
        #expect(grain.count == length)
        // The ramp's value IS its index in the window, so grain[i] carries `offset + i` — here
        // 1000 + 1200. Written out because the other reading, "the absolute sample number", is
        // the one that looks right and is off by the window's own start.
        #expect(grain[1_200] == 2_200)
    }

    /// **A fade is written in seconds, so it is a different number of samples at every rate.** A
    /// grain from a 44.1 kHz file faded as though it were 48 would be faded 9% short — a smaller
    /// click rather than none. The rate is passed through rather than assumed.
    @Test("the fade follows the file's own sample rate")
    func theFadeFollowsTheRate() {
        var at48 = [Float](repeating: 1, count: 4_800)
        var at44 = [Float](repeating: 1, count: 4_800)
        ScrubGrain.applyFades(to: &at48, sampleRate: 48_000)
        ScrubGrain.applyFades(to: &at44, sampleRate: 44_100)
        let firstFull48 = at48.firstIndex(of: 1) ?? -1
        let firstFull44 = at44.firstIndex(of: 1) ?? -1
        #expect(firstFull48 > firstFull44, "a lower rate needs fewer samples for the same 3 ms")
    }

    /// **A partial grain is refused rather than padded.** Padding is silence, and a burst of
    /// silence in the middle of a drag reads as a dropout — which is a fault, where a missing
    /// grain is just one frame with no new sound.
    @Test("a grain that runs past the window is refused, not padded")
    func aPartialGrainIsRefused() {
        let samples = Self.ramp(1_000)
        #expect(ScrubGrain.cut(from: samples, windowStart: 0, startSample: 950, length: 100) == nil)
        #expect(ScrubGrain.cut(from: samples, windowStart: 500, startSample: 400,
                               length: 100) == nil)
        #expect(ScrubGrain.cut(from: samples, windowStart: 0, startSample: 0, length: 0) == nil)
    }

    /// A drag to the left plays backwards. Speech reversed is unintelligible and that is not the
    /// point: what it carries is the rhythm, which is what somebody is navigating by.
    @Test("a backwards grain is the same samples in the other order")
    func aBackwardsGrainIsReversed() throws {
        let samples = Self.ramp(1_000)
        let forwards = try #require(ScrubGrain.cut(from: samples, windowStart: 0,
                                                   startSample: 100, length: 200))
        let backwards = try #require(ScrubGrain.cut(from: samples, windowStart: 0,
                                                    startSample: 100, length: 200,
                                                    backwards: true))
        #expect(forwards.count == backwards.count)
        // The fades are symmetric, so a reversed grain is the reverse of the forward one.
        #expect(Array(backwards.reversed()) == forwards)
    }

    // MARK: - The fades, which are the feature

    /// **Without fades every grain is two clicks.** A grain begins and ends at an arbitrary point
    /// in a waveform, so its first and last samples are almost never zero — and a step from
    /// silence to mid-waveform is audible.
    @Test("a grain starts and ends at zero")
    func aGrainIsFadedAtBothEnds() {
        var grain = [Float](repeating: 1, count: 4_800)
        ScrubGrain.applyFades(to: &grain, sampleRate: Self.rate)
        #expect(grain[0] == 0)
        #expect(grain[grain.count - 1] == 0)
        // And the middle is untouched: a fade that reached the middle would be a volume envelope.
        #expect(grain[2_400] == 1)
    }

    /// The ramp is monotonic — a fade that jumped would be a smaller click rather than none.
    @Test("the fade rises without a step")
    func theFadeIsMonotonic() {
        var grain = [Float](repeating: 1, count: 4_800)
        ScrubGrain.applyFades(to: &grain, sampleRate: Self.rate)
        let fade = Int(ScrubGrain.fadeSeconds * Self.rate)
        for index in 1..<fade {
            #expect(grain[index] >= grain[index - 1], "the fade steps back at \(index)")
        }
        #expect(grain[fade] == 1, "the fade should be over by \(fade)")
    }

    /// **A grain shorter than two fades is faded across its whole length**, rather than having
    /// its ends overlap — which would multiply the middle by two gains and make it quieter than
    /// the ends.
    @Test("a very short grain is not faded twice in the middle")
    func aShortGrainDoesNotOverlapItsFades() {
        var grain = [Float](repeating: 1, count: 10)
        ScrubGrain.applyFades(to: &grain, sampleRate: Self.rate)
        #expect(grain[0] == 0)
        #expect(grain[9] == 0)
        #expect(grain.allSatisfy { $0 <= 1 })
        // The middle is the loudest point rather than a dip.
        #expect(grain[5] >= grain[1])
    }

    @Test("a grain of one sample is left alone rather than divided by zero")
    func aSingleSampleGrain() {
        var grain: [Float] = [1]
        ScrubGrain.applyFades(to: &grain, sampleRate: Self.rate)
        #expect(grain == [1])
    }

    // MARK: - Windows

    /// **Aligned to a grid, not centred on the request.** A window centred on wherever the hand
    /// happens to be is a different window on every frame of a drag, so nothing is ever a cache
    /// hit and every frame decodes.
    @Test("a drag through one window's worth of recording reads one window")
    func windowsAreOnAGrid() {
        let first = ScrubGrain.window(atSeconds: 0.1, sampleRate: Self.rate)
        let later = ScrubGrain.window(atSeconds: 1.9, sampleRate: Self.rate)
        #expect(first.start == later.start, "both are inside the first two-second cell")
        let next = ScrubGrain.window(atSeconds: 2.1, sampleRate: Self.rate)
        #expect(next.start > first.start, "the third second is a different cell")
    }

    /// **A window is widened by a grain at each end**, so a grain centred anywhere inside its
    /// cell lies wholly within what was read — the case `cut` refuses. This is the check that
    /// would catch the widening being dropped as redundant.
    @Test("a grain anywhere in a window's cell can be cut from it")
    func everyGrainInACellFits() {
        let length = ScrubGrain.length(sampleRate: Self.rate)
        for tenth in 0...20 {
            let seconds = Double(tenth) / 10
            let window = ScrubGrain.window(atSeconds: seconds, sampleRate: Self.rate)
            let samples = [Float](repeating: 0.5, count: window.length)
            let start = ScrubGrain.startSample(atSeconds: seconds, sampleRate: Self.rate)
            #expect(ScrubGrain.cut(from: samples, windowStart: window.start,
                                   startSample: start, length: length) != nil,
                    "a grain at \(seconds)s does not fit its own window")
        }
    }

    @Test("a nonsensical time still produces a usable window")
    func aDegenerateWindow() {
        let window = ScrubGrain.window(atSeconds: .nan, sampleRate: Self.rate)
        #expect(window.length >= 1)
        #expect(window.start >= 0)
    }
}
