import Testing
import Foundation
import Timeline
@testable import Overlays

// The envelope a music bed follows under narration. Every test here names a property that
// would go red on its own: the ramps being applicable at all (ordered, abutting, inside the
// timeline), the duck arriving before the voice, the level being held through it, and the
// pumping that merging exists to prevent.

private func ns(_ seconds: Double) -> Nanoseconds { Nanoseconds(Int64(seconds * 1_000_000_000)) }
private func span(_ from: Double, _ to: Double) -> Range<Nanoseconds> { ns(from)..<ns(to) }
private let settings = MusicDucking.Settings.default

/// The volume the ramps imply at `seconds`, by finding the ramp that covers it and
/// interpolating — the same reading `AVAudioMix` performs.
private func level(_ ramps: [MusicDucking.Ramp], at seconds: Double) -> Double? {
    let time = ns(seconds).rawValue
    guard let ramp = ramps.first(where: { $0.start.rawValue <= time && time < $0.end.rawValue })
        ?? ramps.last(where: { $0.end.rawValue == time }) else { return nil }
    let width = ramp.end.rawValue - ramp.start.rawValue
    guard width > 0 else { return ramp.to }
    let f = Double(time - ramp.start.rawValue) / Double(width)
    return ramp.from + (ramp.to - ramp.from) * f
}

// MARK: - the ramps are applicable

/// **`AVAudioMix` requires ordered, non-overlapping ramps**, and it fails silently rather than
/// loudly when they are not — a volume automation that overlaps simply does not do what it
/// says. They must also cover the whole timeline and nothing beyond it, so no stretch of the
/// music is left at whatever the last ramp happened to end on.
@Test func theRampsTileTheTimelineInOrderWithoutOverlapping() {
    let ramps = MusicDucking.ramps(speech: [span(2, 4), span(9, 11)], over: ns(20),
                                   settings: settings)
    #expect(!ramps.isEmpty)
    #expect(ramps.first?.start.rawValue == 0, "the first ramp does not start at zero")
    #expect(ramps.last?.end == ns(20), "the last ramp does not reach the end")
    for (a, b) in zip(ramps, ramps.dropFirst()) {
        #expect(a.end == b.start, "a gap or an overlap between \(a) and \(b)")
        #expect(a.end.rawValue > a.start.rawValue, "an empty ramp: \(a)")
    }
    // And the level is continuous across every join — a jump would be an audible click.
    for (a, b) in zip(ramps, ramps.dropFirst()) {
        #expect(abs(a.to - b.from) < 1e-9, "the level jumps from \(a.to) to \(b.from)")
    }
}

/// With nobody speaking the music is simply the bed, as one ramp.
@Test func silenceThroughoutLeavesTheMusicAtTheBed() {
    let ramps = MusicDucking.ramps(speech: [], over: ns(10), settings: settings)
    #expect(ramps.count == 1)
    #expect(ramps.first?.from == settings.bedGain && ramps.first?.to == settings.bedGain)
}

// MARK: - the duck itself

/// **The music is already down when the first syllable lands.** A drop that begins when the
/// voice begins is a drop the first word happens during — so the attack sits in front of the
/// span, and at the instant speech starts the level is the ducked one.
@Test func theDuckIsCompleteByTheTimeTheVoiceStarts() throws {
    let ramps = MusicDucking.ramps(speech: [span(5, 7)], over: ns(15), settings: settings)
    let attack = Double(settings.attack.rawValue) / 1e9
    let before = try #require(level(ramps, at: 5 - attack - 0.05))
    let atStart = try #require(level(ramps, at: 5))
    #expect(abs(before - settings.bedGain) < 1e-9, "the level was \(before) before the attack")
    #expect(abs(atStart - settings.duckedGain) < 1e-9,
            "at the first syllable the music was still at \(atStart)")
    // And it really moved: a settings pair that ducked nowhere would pass neither.
    #expect(settings.duckedGain < settings.bedGain)
}

/// It stays down for the whole span and for the hold after it, then comes back over the
/// release — slower than it went down, which is what a bed that does not draw attention does.
@Test func theMusicHoldsDownThenReturnsOverTheLongerRelease() throws {
    let ramps = MusicDucking.ramps(speech: [span(3, 6)], over: ns(20), settings: settings)
    let hold = Double(settings.hold.rawValue) / 1e9
    let release = Double(settings.release.rawValue) / 1e9
    #expect(try #require(level(ramps, at: 4.5)) == settings.duckedGain, "not held mid-speech")
    #expect(try #require(level(ramps, at: 6 + hold / 2)) == settings.duckedGain, "not held after")
    let midRise = try #require(level(ramps, at: 6 + hold + release / 2))
    #expect(midRise > settings.duckedGain && midRise < settings.bedGain,
            "mid-release the level was \(midRise)")
    #expect(abs(try #require(level(ramps, at: 6 + hold + release + 0.1)) - settings.bedGain) < 1e-9)
    #expect(settings.release.rawValue > settings.attack.rawValue,
            "the release is not slower than the attack; the bed will spring back")
}

// MARK: - pumping

/// **Two words with a breath between them are one run.** Without merging, the gap would start
/// a release the next word interrupts, and the music would rise and fall between syllables —
/// the pumping that makes a ducked bed worse than no bed. Measured as the level in the gap: it
/// must not have moved.
@Test func aBreathBetweenWordsDoesNotLetTheMusicRise() throws {
    let gap = 0.2   // well inside hold + release
    let ramps = MusicDucking.ramps(speech: [span(2, 3), span(3 + gap, 5)], over: ns(12),
                                   settings: settings)
    #expect(try #require(level(ramps, at: 3 + gap / 2)) == settings.duckedGain,
            "the music rose during a \(gap) s gap between two words")
}

/// And a genuine pause does let it back up — merging that swallowed everything would pass the
/// test above and be wrong.
@Test func aRealPauseLetsTheMusicBackUp() throws {
    let ramps = MusicDucking.ramps(speech: [span(2, 3), span(9, 10)], over: ns(15),
                                   settings: settings)
    let recovered = try #require(level(ramps, at: 7))
    #expect(abs(recovered - settings.bedGain) < 1e-9,
            "six seconds after the voice stopped the music was still at \(recovered)")
}

// MARK: - edges

/// Speech from the very first instant has nowhere to put an attack, so it starts ducked
/// rather than ducking into a stretch of timeline that does not exist.
@Test func speechAtTheVeryStartBeginsAlreadyDucked() throws {
    let ramps = MusicDucking.ramps(speech: [span(0, 2)], over: ns(10), settings: settings)
    #expect(try #require(level(ramps, at: 0)) == settings.duckedGain)
    #expect(ramps.first?.start.rawValue == 0)
}

/// Speech running to the end leaves the music ducked at the end rather than inventing a
/// release past the last frame.
@Test func speechToTheEndLeavesTheMusicDucked() throws {
    let ramps = MusicDucking.ramps(speech: [span(8, 10)], over: ns(10), settings: settings)
    #expect(ramps.last?.end == ns(10))
    #expect(try #require(level(ramps, at: 9.9)) == settings.duckedGain)
}

/// Spans outside the timeline, reversed, or overlapping are data a caller can produce; none
/// of them may produce a ramp outside the timeline or out of order.
@Test func disorderedOrOutOfRangeSpansStillProduceAValidEnvelope() {
    let ramps = MusicDucking.ramps(
        speech: [span(9, 11), span(1, 3), span(2, 4), span(-5, -1), span(30, 40)],
        over: ns(12), settings: settings)
    #expect(ramps.first?.start.rawValue == 0 && ramps.last?.end == ns(12))
    for (a, b) in zip(ramps, ramps.dropFirst()) { #expect(a.end == b.start) }
    for ramp in ramps {
        #expect(ramp.start.rawValue >= 0 && ramp.end.rawValue <= ns(12).rawValue)
    }
}

/// A zero-length timeline has no envelope, rather than one ramp of nothing.
@Test func anEmptyTimelineHasNoRamps() {
    #expect(MusicDucking.ramps(speech: [span(0, 1)], over: ns(0), settings: settings).isEmpty)
}

// MARK: - where the speech comes from

/// Speech is the complement of `SilenceFinder`'s answer, so there is one decision about where
/// the voice is rather than two.
@Test func speechIsWhatTheSilencesLeaveBehind() {
    let silences = [SilenceFinder.Span(start: ns(0), end: ns(2)),
                    SilenceFinder.Span(start: ns(5), end: ns(6))]
    let speech = MusicDucking.speech(betweenSilences: silences, over: ns(10))
    #expect(speech == [ns(2)..<ns(5), ns(6)..<ns(10)])
}

/// Silence everywhere leaves no speech; no silence at all leaves the whole timeline.
@Test func theComplementHandlesBothExtremes() {
    #expect(MusicDucking.speech(betweenSilences: [SilenceFinder.Span(start: ns(0), end: ns(9))],
                                over: ns(9)).isEmpty)
    #expect(MusicDucking.speech(betweenSilences: [], over: ns(9)) == [ns(0)..<ns(9)])
}

/// The ducked level may never sit above the bed — "ducking" that raised the music would be a
/// slider a person could not make sense of.
@Test func theDuckedLevelIsHeldAtOrBelowTheBed() {
    let odd = MusicDucking.Settings(bedGain: 0.3, duckedGain: 0.9,
                                    attack: ns(0.1), release: ns(0.5), hold: ns(0.2))
    #expect(odd.duckedGain <= odd.bedGain)
    #expect(MusicDucking.Settings(bedGain: -1, duckedGain: -1, attack: Nanoseconds(-5),
                                  release: ns(0.5), hold: ns(0.2)).bedGain == 0)
}
