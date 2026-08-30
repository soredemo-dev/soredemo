import Foundation
import Testing
import Timeline
@testable import Overlays

private func ns(_ seconds: Double) -> Nanoseconds { Nanoseconds(Int64(seconds * 1_000_000_000)) }

private func cue(_ text: String, _ start: Double, _ end: Double,
                 words: [TranscribedWord] = []) -> CaptionCue {
    CaptionCue(text: text, start: ns(start), end: ns(end), words: words)
}

// MARK: - what a caption's numbers say

/// **The two scripts are judged by different numbers**, and the split is on word gaps rather
/// than on a language list, because that is the only thing the text itself can answer.
@Test func aDenseScriptIsHeldToItsOwnReadingSpeed() {
    // 16 Latin characters in one second is comfortable; 16 Chinese characters is not.
    let latin = CaptionMeasurement(text: "sixteen chars ok", duration: ns(1))
    #expect(latin.script == .spaced)
    #expect(latin.fault == nil)

    let dense = CaptionMeasurement(text: String(repeating: "字", count: 16), duration: ns(1))
    #expect(dense.script == .dense)
    #expect(dense.fault == .tooFast,
            "16 characters a second of CJK passed — it is nearly twice the published rate")

    // And the same CJK line with enough time on screen is fine.
    #expect(CaptionMeasurement(text: String(repeating: "字", count: 16),
                              duration: ns(2)).fault == nil)
}

/// **Order matters: the floor is checked before the reading speed.** A 200 ms cue is also
/// technically far too fast, and reporting that would send somebody to shorten a line whose real
/// problem is that it is barely on screen.
@Test func aCueTooBriefToReadSaysSoRatherThanSayingTooFast() {
    let brief = CaptionMeasurement(text: "hello there", duration: ns(0.2))
    #expect(brief.fault == .tooBrief)
    #expect(brief.charactersPerSecond > 17, "the test's premise is gone — this is not also fast")

    #expect(CaptionMeasurement(text: "a", duration: ns(9)).fault == .tooLong)
    #expect(CaptionMeasurement(text: "a", duration: ns(0)).charactersPerSecond == .infinity,
            "a zero-length cue divided by zero into something a panel would print")
}

/// The builder and the panel use ONE number for the floor. Two would mean the panel warning
/// about lines the builder had just produced.
@Test func theBuilderAndTheMeasurementAgreeOnTheFloor() {
    #expect(CaptionBuilder.minimumDisplay == CaptionMeasurement.shortestDisplay)
    #expect(CaptionMeasurement.shortestDisplay.rawValue == 833_333_333,
            "five-sixths of a second is the published minimum for one subtitle event")
}

// MARK: - retiming, which could not be done at all before

/// A boundary stops at its neighbour rather than crossing it, and stops a gap short of touching.
@Test func aRetimedCueCannotCrossItsNeighbours() {
    let track = CaptionTrack(cues: [cue("one", 0, 1), cue("two", 2, 3), cue("three", 4, 5)])

    // Dragged far too early and far too late at once.
    let stretched = track.retiming(at: 1, start: ns(0), end: ns(10))
    let middle = stretched.cues[1]
    #expect(middle.start.rawValue >= track.cues[0].end.rawValue + CaptionTrack.shortestGap.rawValue,
            "the start crossed into the cue before it")
    #expect(middle.end.rawValue <= track.cues[2].start.rawValue - CaptionTrack.shortestGap.rawValue,
            "the end crossed into the cue after it")
    // The neighbours are untouched — retiming one cue is one edit.
    #expect(stretched.cues[0] == track.cues[0])
    #expect(stretched.cues[2] == track.cues[2])
}

/// A start dragged past its own end gives the shortest legal cue, not a backwards one.
@Test func aStartDraggedPastItsOwnEndDoesNotInvertTheCue() {
    let track = CaptionTrack(cues: [cue("only", 1, 3)])
    let inverted = track.retiming(at: 0, start: ns(2.9), end: ns(1.1))
    let result = inverted.cues[0]
    #expect(result.end.rawValue > result.start.rawValue, "the cue ends before it starts")
    #expect(result.duration.rawValue >= CaptionMeasurement.shortestDisplay.rawValue)
}

/// A cue with nowhere to go is left alone. Clamping cannot answer "no legal span exists", and
/// returning something illegal would be worse than returning nothing.
@Test func aCueWithNoRoomIsReturnedUnchanged() {
    // Neighbours 0.3 s apart: less than the floor plus two gaps.
    let track = CaptionTrack(cues: [cue("a", 0, 1), cue("b", 1.1, 1.2), cue("c", 1.3, 2)])
    #expect(track.retiming(at: 1, start: ns(0.5), end: ns(1.9)) == track)
}

// MARK: - splitting and merging

/// **The join is timed from the word runs, not by sharing the span out by character count.**
/// The recogniser gave a real time for the word the split lands on, and that is why the runs
/// are carried at all.
@Test func aSplitLandsOnTheWordTheRecogniserTimed() {
    let words = [TranscribedWord(text: "open", start: ns(0), end: ns(0.5)),
                 TranscribedWord(text: "the", start: ns(0.5), end: ns(0.7)),
                 TranscribedWord(text: "app", start: ns(2.0), end: ns(2.6))]
    let track = CaptionTrack(cues: [cue("open the app", 0, 3, words: words)])

    // Split before "app" — character 8 of "open the app".
    let split = track.splitting(at: 0, atCharacter: 8)
    #expect(split.cues.map(\.text) == ["open the", "app"])
    #expect(split.cues[1].start == ns(2.0),
            "the second half started at a share of the span rather than when its word was said")
    #expect(split.cues[0].end == split.cues[1].start, "the halves do not meet")
    #expect(split.cues[0].start == ns(0) && split.cues[1].end == ns(3),
            "splitting changed the span the pair covers")

    // The runs go with the half they fall in, so the karaoke pass still has them.
    #expect(split.cues[0].words.map(\.text) == ["open", "the"])
    #expect(split.cues[1].words.map(\.text) == ["app"])
}

/// A split that would leave either half unreadable is refused, rather than producing one legal
/// cue and one that immediately reports `tooBrief`.
@Test func aSplitThatWouldStrandAnUnreadableHalfIsRefused() {
    let short = CaptionTrack(cues: [cue("open the app", 0, 1.2)])
    #expect(short.splitting(at: 0, atCharacter: 8) == short)

    // And a caret at either end means nothing.
    let ordinary = CaptionTrack(cues: [cue("open the app", 0, 4)])
    #expect(ordinary.splitting(at: 0, atCharacter: 0) == ordinary)
    #expect(ordinary.splitting(at: 0, atCharacter: 12) == ordinary)
}

/// Merging joins the span and the words, and does NOT insert a space into a dense script — that
/// would be a visible edit to somebody's line.
@Test func mergingJoinsTheSpanAndRespectsTheScript() {
    let spaced = CaptionTrack(cues: [cue("open the", 0, 1), cue("app now", 1.2, 2)])
    let joined = spaced.merging(at: 0)
    #expect(joined.cues.count == 1)
    #expect(joined.cues[0].text == "open the app now")
    #expect(joined.cues[0].start == ns(0) && joined.cues[0].end == ns(2),
            "the merged cue does not span both")

    let dense = CaptionTrack(cues: [cue("開啟", 0, 1), cue("應用程式", 1.2, 2)])
    #expect(dense.merging(at: 0).cues[0].text == "開啟應用程式",
            "a space was inserted into a script that has none")

    // Nothing to merge with is not an edit.
    #expect(spaced.merging(at: 1) == spaced)
}

/// Split then merge is the identity on the text, which is what makes the pair safe to try.
@Test func splittingThenMergingGivesTheTextBack() {
    let words = [TranscribedWord(text: "open", start: ns(0), end: ns(0.9)),
                 TranscribedWord(text: "the", start: ns(1.0), end: ns(1.4)),
                 TranscribedWord(text: "app", start: ns(2.0), end: ns(2.6))]
    let track = CaptionTrack(cues: [cue("open the app", 0, 3, words: words)])
    let round = track.splitting(at: 0, atCharacter: 8).merging(at: 0)
    #expect(round.cues.count == 1)
    #expect(round.cues[0].text == "open the app")
    #expect(round.cues[0].start == track.cues[0].start)
    #expect(round.cues[0].end == track.cues[0].end)
}

// MARK: - stepping between cues

/// **The interesting case is a playhead in a GAP**, which is most of a recording: "next" has to
/// go forward to the cue after the gap and "previous" back to the one before it. Anchoring on
/// "the last cue that has started" is what gives both from one rule.
@Test func steppingFromAGapGoesForwardAndBackToTheRightNeighbours() {
    let track = CaptionTrack(cues: [cue("one", 0, 1), cue("two", 3, 4), cue("three", 6, 7)])

    // Inside a cue: an ordinary step.
    #expect(track.index(steppingFrom: ns(3.5), by: 1) == 2)
    #expect(track.index(steppingFrom: ns(3.5), by: -1) == 0)

    // In the gap between "one" and "two": forward is "two", back is "one".
    #expect(track.index(steppingFrom: ns(2), by: 1) == 1,
            "next from a gap went somewhere other than the cue ahead of it")
    #expect(track.index(steppingFrom: ns(2), by: -1) == 0)
}

/// Before the first cue and past the last, a step clamps. A wrap would move the playhead to the
/// other end of the recording, which is never what a repeated key press means.
@Test func steppingPastEitherEndStaysThere() {
    let track = CaptionTrack(cues: [cue("one", 1, 2), cue("two", 3, 4)])
    #expect(track.index(steppingFrom: ns(0), by: -1) == 0)
    #expect(track.index(steppingFrom: ns(0), by: 1) == 0,
            "next from before the first cue skipped it")
    #expect(track.index(steppingFrom: ns(9), by: 1) == 1)
    #expect(track.index(steppingFrom: ns(9), by: -1) == 0)

    #expect(CaptionTrack().index(steppingFrom: ns(0), by: 1) == nil,
            "an empty track produced an index into nothing")
}
