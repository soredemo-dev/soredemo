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
        // this file chunks rather than halving.
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

// MARK: - breaking, measured on a real narration

/// **The floor was applied per segment and a segment cannot see the one after it.**
///
/// `enforcing` caps a cue at its successor's start so two lines are never on screen at once, and
/// it was run once per segment — so the LAST cue of each segment had nothing to cap against and
/// ran into the first cue of the next. Measured on a 28-second narration: six of twenty-nine
/// cues overlapped, one by 700 ms. `CaptionTrack.cue(at:)` answers with one of an overlapping
/// pair, so a line flicked back to the previous sentence for a few frames.
@Test func noCueOutlastsTheNextOneAcrossASegmentBoundary() {
    // Two segments that abut, each ending in a word short enough to want the minimum display.
    let transcript = Transcript(
        text: "How to record your screen. Trim it.",
        words: [TranscribedWord(text: "How", start: ns(0), end: ns(0.3)),
                TranscribedWord(text: "to", start: ns(0.3), end: ns(0.5)),
                TranscribedWord(text: "record", start: ns(0.5), end: ns(0.9)),
                TranscribedWord(text: "your", start: ns(0.9), end: ns(1.1)),
                TranscribedWord(text: "screen.", start: ns(1.1), end: ns(1.3)),
                TranscribedWord(text: "Trim", start: ns(1.4), end: ns(1.7)),
                TranscribedWord(text: "it.", start: ns(1.7), end: ns(1.9))],
        segments: [TranscribedSegment(text: "How to record your screen.",
                                      start: ns(0), end: ns(1.3)),
                   TranscribedSegment(text: "Trim it.", start: ns(1.4), end: ns(1.9))])

    let cues = CaptionBuilder.cues(for: transcript, fits: fitting(14))
    #expect(cues.count > 1, "one cue cannot overlap anything — this test decided nothing")
    for (earlier, later) in zip(cues, cues.dropFirst()) {
        #expect(earlier.end.rawValue <= later.start.rawValue,
                """
                a cue ending at \(earlier.end.rawValue) runs past the next one's start at \
                \(later.start.rawValue) — two lines are on screen at once and `cue(at:)` picks one
                """)
    }
}

/// **A line can fit the frame and still be unreadable.** `fits` measures pixels; 42 characters
/// is the broadcast figure for a line of Latin script, and it is a SECOND limit rather than a
/// replacement. The measured case: "Trim the recording, and export it as a video file you can
/// share with your team." came out as one 79-character cue, on screen for 4.3 seconds, well
/// inside the pixel test.
@Test func aLineThatFitsThePixelsIsStillBrokenAtTheReadingLimit() {
    let long = "Trim the recording and export it as a video file you can share with your team"
    let segment = TranscribedSegment(text: long, start: ns(0), end: ns(5))
    // `fits` says yes to everything, so only the character limit can break this.
    let cues = CaptionBuilder.cues(for: segment, fits: { _ in true })

    #expect(cues.count > 1, "nothing broke a 76-character line — the reading limit is not applied")
    for cue in cues {
        // **Width, not characters, because that is what the rule measures.** Whitespace does
        // not count and a full-width character counts twice, so 42 is 42 Latin words' worth of
        // ink whatever the script — this assertion used to count characters and disagreed with
        // the rule by exactly the spaces in the line.
        let width = CaptionMeasurement.width(of: cue.text)
        #expect(width <= CaptionBuilder.longestLine,
                "a line of width \(width) survived: |\(cue.text)|")
    }
    #expect(cues.map(\.text).joined(separator: " ") == long, "breaking changed the words")
}

/// A script with no spaces is not broken by a limit derived from the Latin alphabet. Chinese
/// carries far more per character and has no gaps to break on; cutting at 42 would be a rule
/// applied where its reason does not hold.
@Test func aScriptWithNoWordGapsIsNotCutAtTheLatinLimit() {
    let dense = String(repeating: "字", count: 80)
    let cues = CaptionBuilder.cues(for: TranscribedSegment(text: dense, start: ns(0), end: ns(3)),
                                   fits: { _ in true })
    #expect(cues.map(\.text) == [dense])
}

/// **A one-word clause is an orphan; a one-word sentence is a line somebody said.**
///
/// The measured case: splitting at every comma left "First," alone on screen for 0.78 s. The
/// merge is applied to commas and never to full stops, because "Yes." is a caption and "First,"
/// is half of one.
@Test func aOneWordClauseIsMergedAndAOneWordSentenceIsNot() {
    let clause = CaptionBuilder.cues(
        for: TranscribedSegment(text: "First, open the app from the menu bar",
                                start: ns(0), end: ns(3)),
        fits: { _ in true })
    #expect(clause.first?.text.hasPrefix("First, open") == true,
            "the one-word clause is still alone: |\(clause.first?.text ?? "")|")

    // Long enough that it is split at all: a line inside the reading limit is returned whole,
    // which is what the first version of this test measured without meaning to.
    let sentence = CaptionBuilder.cues(
        for: TranscribedSegment(text: "Yes. Open the app from the menu bar and choose a display",
                                start: ns(0), end: ns(3)),
        fits: { _ in true })
    #expect(sentence.first?.text == "Yes.",
            "a one-word sentence was swallowed by the next one: |\(sentence.first?.text ?? "")|")
}

/// **Coalescing can collapse a split entirely, and the first version recursed forever on it.**
/// Two clauses whose first is one word join back into exactly the string that was handed in, and
/// splitting that finds the same comma. The test is that this returns at all.
@Test func aCommaSplitThatCollapsesBackDoesNotRecurseForever() {
    let cues = CaptionBuilder.cues(
        for: TranscribedSegment(text: "First, open it", start: ns(0), end: ns(2)),
        fits: { _ in true })
    #expect(cues.map(\.text) == ["First, open it"])
}

/// The break is chosen, not taken at the middle word.
@Test func theBreakIsBalancedByCharactersAndAvoidsEndingOnAWordThatBindsForward() {
    // Halving by WORD count puts the break after "you"; balancing by characters and penalising
    // an ending on "how" — which opens a clause and never closes one — moves it one word left.
    #expect(CaptionBuilder.breakAtMiddleWord("Today I'll show you how to record your screen.")
            == ["Today I'll show you", "how to record your screen."])

    // Word-count halving would split this 4/4 and leave the two halves at 25 and 9 characters.
    #expect(CaptionBuilder.breakAtMiddleWord("extraordinarily complicated arrangement here of it")
            .map(\.count).max()! <= 32)

    // And a single word is not broken: a caption reading "transcrip" then "tion" is worse than
    // one that overflows.
    #expect(CaptionBuilder.breakAtMiddleWord("supercalifragilistic")
            == ["supercalifragilistic"])
}

/// An orphan on either side is penalised, so a break that leaves one word alone loses to a
/// slightly less balanced one that does not.
@Test func theBreakDoesNotStrandASingleWord() {
    let halves = CaptionBuilder.breakAtMiddleWord("we recorded the entire session yesterday x")
    #expect(halves.count == 2)
    for half in halves {
        #expect(half.split(separator: " ").count > 1,
                "a break stranded a single word: |\(half)|")
    }
}
