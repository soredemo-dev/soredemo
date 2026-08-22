import Testing
import Foundation
import Timeline
@testable import Overlays

/// Nanoseconds from a readable number of seconds. Written as an integer multiply rather than
/// `Int64(seconds * 1e9)`: the multiply through `Double` is where `4.1` becomes 4099999999.
private func ns(_ seconds: Double) -> Nanoseconds {
    Nanoseconds(Int64((seconds * 1000).rounded()) * 1_000_000)
}

private func word(_ text: String, _ start: Double, _ end: Double) -> TranscribedWord {
    TranscribedWord(text: text, start: ns(start), end: ns(end))
}

/// A `fits` that stands in for measuring text: at most `limit` characters.
private func fitting(_ limit: Int) -> (String) -> Bool {
    { $0.count <= limit }
}

@Suite struct CaptionBuilderTests {
    /// The first of the three ported ideas: break at the best boundary PRESENT, not at a
    /// character count. A greedy fill would put the break inside the first sentence.
    @Test func aLineTooLongBreaksAtTheSentenceEndBeforeAnywhereElse() {
        let segment = TranscribedSegment(text: "I clicked save. Then it crashed.",
                                         start: ns(0), end: ns(4))
        let cues = CaptionBuilder.cues(for: segment, fits: fitting(20))
        #expect(cues.map(\.text) == ["I clicked save.", "Then it crashed."])
    }

    /// A clause boundary when there is no sentence boundary.
    @Test func withNoSentenceEndItBreaksAtAClauseInstead() {
        let segment = TranscribedSegment(text: "first this, then that, finally the other",
                                         start: ns(0), end: ns(4))
        let cues = CaptionBuilder.cues(for: segment, fits: fitting(18))
        #expect(cues.map(\.text) == ["first this,", "then that,", "finally the other"])
    }

    /// And the middle word when there is no punctuation at all.
    @Test func withNoPunctuationAtAllItBreaksAtTheMiddleWord() {
        let segment = TranscribedSegment(text: "one two three four", start: ns(0), end: ns(4))
        let cues = CaptionBuilder.cues(for: segment, fits: fitting(10))
        #expect(cues.map(\.text) == ["one two", "three four"])
    }

    /// **The reason `breakOn` requires a following space.** A version that split on every `.`
    /// would cut "U.S." into "U." and "S." and "3.14" into "3." and "14".
    @Test func anAbbreviationOrADecimalIsNotASentenceEnd() {
        let segment = TranscribedSegment(text: "the U.S. build takes 3.14 seconds to finish",
                                         start: ns(0), end: ns(4))
        let cues = CaptionBuilder.cues(for: segment, fits: fitting(24))
        for cue in cues {
            #expect(!cue.text.hasSuffix("U."), "split inside an abbreviation: \(cue.text)")
            #expect(!cue.text.hasSuffix("3."), "split inside a decimal: \(cue.text)")
        }
        #expect(cues.joined() == segment.text)
    }

    /// A word longer than the box is kept whole. "transcrip" / "tion" is worse than an overflow.
    @Test func aSingleWordWiderThanTheBoxIsNotCutInHalf() {
        let segment = TranscribedSegment(text: "internationalisation", start: ns(0), end: ns(2))
        let cues = CaptionBuilder.cues(for: segment, fits: fitting(5))
        #expect(cues.map(\.text) == ["internationalisation"])
    }

    /// The third ported idea. The runs here do NOT split on spaces — "don't" arrives as three —
    /// so a word-index walk would put the break in the wrong place. Counting letters does not.
    @Test func phrasesAreTimedAgainstRunsThatDoNotSplitOnSpaces() {
        let segment = TranscribedSegment(text: "I don't know. Ask Sam.", start: ns(0), end: ns(4))
        let words = [
            word("I", 0.0, 0.2), word("don", 0.2, 0.5), word("'", 0.5, 0.5), word("t", 0.5, 0.7),
            word("know", 0.7, 1.2), word("Ask", 2.0, 2.4), word("Sam", 2.4, 3.0),
        ]
        let cues = CaptionBuilder.cues(for: segment, words: words, fits: fitting(14))
        #expect(cues.map(\.text) == ["I don't know.", "Ask Sam."])
        #expect(cues[0].start == ns(0))
        #expect(cues[0].end == ns(1.2))
        // The second line starts at "Ask", not at wherever an index walk had drifted to.
        #expect(cues[1].start == ns(2.0))
        #expect(cues[1].end == ns(3.0))
    }

    /// With no word timings the segment's own span is shared out by character count, and the
    /// last piece takes the remainder so the set still ends where the segment did.
    @Test func withNoWordTimingsTheSegmentsSpanIsSharedOutAndStillEndsWhereItDid() {
        let segment = TranscribedSegment(text: "one two. three four.", start: ns(0), end: ns(10))
        let cues = CaptionBuilder.cues(for: segment, fits: fitting(12), minimumDisplay: ns(0))
        #expect(cues.count == 2)
        #expect(cues[0].start == ns(0))
        #expect(cues[1].end == ns(10))
        // Back to back, with no gap and no overlap.
        #expect(cues[0].end == cues[1].start)
    }

    /// The floor exists because a caption for one short word is unreadable at its spoken length.
    @Test func aCueShorterThanTheFloorIsExtendedToIt() {
        let segment = TranscribedSegment(text: "go", start: ns(0), end: ns(0.15))
        let cues = CaptionBuilder.cues(for: segment, words: [word("go", 0, 0.15)],
                                       fits: fitting(40))
        #expect(cues.count == 1)
        #expect(cues[0].end == CaptionBuilder.minimumDisplay)
    }

    /// **But never past the next cue's start**, or two lines are on screen and the one being
    /// spoken is underneath.
    @Test func theFloorNeverPushesACueOverTheNextOnesFirstWord() {
        let segment = TranscribedSegment(text: "go. now.", start: ns(0), end: ns(0.6))
        let words = [word("go", 0, 0.1), word("now", 0.3, 0.6)]
        let cues = CaptionBuilder.cues(for: segment, words: words, fits: fitting(4))
        #expect(cues.count == 2)
        #expect(cues[0].end.rawValue <= cues[1].start.rawValue)
        #expect(cues[0].end == ns(0.3))
    }

    /// A cap on top of `fits` is what produces the one-to-three-words-at-a-time look.
    @Test func aWordCapSplitsFurtherThanFitsAloneWould() {
        let segment = TranscribedSegment(text: "one two three four five six",
                                         start: ns(0), end: ns(6))
        let uncapped = CaptionBuilder.cues(for: segment, fits: fitting(100))
        #expect(uncapped.count == 1)

        // Three EVEN pairs, not one/two-three/four/five-six — see `split`'s comment on why
        // this file chunks where a native editor halves.
        let capped = CaptionBuilder.cues(for: segment, fits: fitting(100), maximumWords: 2)
        #expect(capped.map(\.text) == ["one two", "three four", "five six"])
    }

    /// A transcript's words cover the whole recording, so each segment must be timed against its
    /// OWN runs — otherwise the second segment is timed from the first one's.
    @Test func eachSegmentIsTimedAgainstOnlyTheWordsInsideIt() {
        let transcript = Transcript(
            text: "hello there",
            words: [word("hello", 0, 0.5), word("there", 9, 9.5)],
            segments: [TranscribedSegment(text: "hello", start: ns(0), end: ns(0.5)),
                       TranscribedSegment(text: "there", start: ns(9), end: ns(9.5))])
        let cues = CaptionBuilder.cues(for: transcript, fits: fitting(40))
        #expect(cues.count == 2)
        #expect(cues[0].start == ns(0))
        #expect(cues[1].start == ns(9))
    }

    /// A recogniser that reports runs but no segments still produces captions.
    @Test func aTranscriptWithWordsButNoSegmentsStillProducesCues() {
        let transcript = Transcript(text: "one two three",
                                    words: [word("one", 0, 0.4), word("two", 0.4, 0.8),
                                            word("three", 0.8, 1.4)])
        let cues = CaptionBuilder.cues(for: transcript, fits: fitting(8))
        #expect(!cues.isEmpty)
        #expect(cues.joined().contains("three"))
    }

    @Test func anEmptyTranscriptProducesNothingRatherThanAnEmptyCue() {
        #expect(CaptionBuilder.cues(for: Transcript.empty, fits: fitting(40)).isEmpty)
        #expect(Transcript.empty.isEmpty)
    }

    /// Transcribing a selection is how a long recording stays affordable; the result is useless
    /// if it is not put back where it came from.
    @Test func offsettingATranscriptMovesEveryWordAndSegment() {
        let transcript = Transcript(text: "hi", words: [word("hi", 1, 2)],
                                    segments: [TranscribedSegment(text: "hi", start: ns(1),
                                                                  end: ns(2))])
        let moved = transcript.offset(by: ns(30).rawValue)
        #expect(moved.words[0].start == ns(31))
        #expect(moved.segments[0].end == ns(32))
        #expect(transcript.offset(by: 0) == transcript)
    }
}

private extension Array where Element == CaptionCue {
    /// The cue texts rejoined, for asserting that breaking did not lose or duplicate anything.
    func joined() -> String { map(\.text).joined(separator: " ") }
}
