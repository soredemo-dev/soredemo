import Foundation
import Testing
import Timeline
@testable import Overlays

private func ns(_ value: Int64) -> Nanoseconds { Nanoseconds(value) }

private func segment(_ text: String, _ start: Int64, _ end: Int64) -> TranscribedSegment {
    TranscribedSegment(text: text, start: ns(start), end: ns(end))
}

/// **Editing the video by editing what was said.** The two halves existed separately for a long
/// time — a transcript timed against the recording, and `EditTimeline.removing(sourceRange:)` —
/// and this is the rule that joins them: which span of the recording "delete this sentence"
/// actually removes.
@Suite struct TranscriptCuttingTests {
    private let spoken = Transcript(
        text: "One. Two. Three.",
        segments: [
            segment("One.", 1_000_000_000, 2_000_000_000),
            segment("Two.", 5_000_000_000, 6_000_000_000),
            segment("Three.", 6_200_000_000, 7_000_000_000),
        ])

    /// **The sentence and only the sentence, and the three-second pause after "One." is the
    /// argument.** Extending the cut to where the next sentence begins would leave one natural
    /// pause instead of two — but it would also swallow those three seconds, which can be a
    /// deliberate beat as easily as a breath. `SilenceFinder` and the Silence lane are this
    /// app's one owner for where the silences are and what to do about them; deciding it again
    /// here would be a second answer to a question already answered.
    @Test func deletingASentenceCutsItsOwnSpanAndNotThePauseAfterIt() throws {
        let range = try #require(spoken.removalRange(ofSegmentAt: 0))
        #expect(range == 1_000_000_000..<2_000_000_000)
        // Stated as the thing it must NOT be, because that was the first draft.
        #expect(range.upperBound != spoken.segments[1].start.rawValue,
                "the cut ran to the next sentence and took a three-second pause with it")
    }

    /// The last sentence has no next one; nothing about it is special.
    @Test func theLastSentenceCutsLikeEveryOther() throws {
        let range = try #require(spoken.removalRange(ofSegmentAt: 2))
        #expect(range == 6_200_000_000..<7_000_000_000)
    }

    /// **Source time, so deletions do not have to be re-mapped after each other.** A transcript
    /// is timed against the recording and `removing(sourceRange:)` takes source time too, so
    /// deleting two sentences in either order lands the same edit — which is what makes a list
    /// of scissors buttons safe to press repeatedly.
    @Test func twoDeletionsCommuteBecauseBothAreInTheRecordingsOwnTime() throws {
        let whole = EditTimeline.whole(duration: ns(10_000_000_000))
        let first = try #require(spoken.removalRange(ofSegmentAt: 0))
        let second = try #require(spoken.removalRange(ofSegmentAt: 1))

        let forwards = whole.removing(sourceRange: first).removing(sourceRange: second)
        let backwards = whole.removing(sourceRange: second).removing(sourceRange: first)
        #expect(forwards.outputDuration == backwards.outputDuration)
        #expect(forwards.clips.map(\.sourceStart) == backwards.clips.map(\.sourceStart))
        #expect(forwards.clips.map(\.duration) == backwards.clips.map(\.duration))

        // And both sentences really are gone afterwards.
        #expect(forwards.survival(ofSource: first) == .gone)
        #expect(forwards.survival(ofSource: second) == .gone)
        // …while the one nobody deleted is untouched.
        #expect(forwards.survival(ofSource: try #require(spoken.removalRange(ofSegmentAt: 2))) == .whole)
    }

    /// An index outside the segments is `nil`, not a crash and not an empty range that would
    /// cut nothing while a row said the sentence had been deleted.
    @Test func anIndexOutsideTheSegmentsIsRefused() {
        #expect(spoken.removalRange(ofSegmentAt: -1) == nil)
        #expect(spoken.removalRange(ofSegmentAt: 3) == nil)
        #expect(Transcript.empty.removalRange(ofSegmentAt: 0) == nil)
    }

    /// **A recogniser can report a zero-length run**, and cutting nothing while telling somebody
    /// their sentence was deleted is worse than refusing. Reversed times get the same answer for
    /// the same reason.
    @Test func aDegenerateSegmentIsRefusedRatherThanCuttingNothing() {
        let odd = Transcript(text: "", segments: [
            segment("", 3_000_000_000, 3_000_000_000),
            segment("backwards", 5_000_000_000, 4_000_000_000),
        ])
        #expect(odd.removalRange(ofSegmentAt: 0) == nil)
        #expect(odd.removalRange(ofSegmentAt: 1) == nil)
    }
}

private func word(_ text: String, _ start: Int64, _ end: Int64) -> TranscribedWord {
    TranscribedWord(text: text, start: ns(start), end: ns(end))
}

/// **Cutting by the word, which is the honest answer to "remove my filler words".**
///
/// The automatic version was researched and refused, and the reasons are worth having beside the
/// code that replaced it. macOS 26's `SpeechTranscriber.TranscriptionOption` has exactly ONE case,
/// `.etiquetteReplacements` — there is no verbatim mode and no way to ask the recogniser to keep
/// disfluencies. Measured against synthesised speech saying "So um I was uh thinking about this,
/// er, feature. Hmm. It is, like, useful.": `uh` and `Hmm` produced no token at all, and `um` came
/// back as **"am"** — a real word, and one a word-list matcher would either miss or, if somebody
/// added it, delete out of a legitimate sentence.
///
/// So the words a person wants gone are chosen by the person. A dictionary cannot tell "I like
/// this" from "it is, like, useful"; somebody reading their own sentence can, at a glance.
@Suite struct TranscriptWordCuttingTests {
    private let spoken = Transcript(
        text: "It is like useful. Really.",
        words: [
            word("It", 1_000_000_000, 1_200_000_000),
            word("is", 1_200_000_000, 1_400_000_000),
            word("like", 1_500_000_000, 1_900_000_000),
            word("useful.", 2_000_000_000, 2_600_000_000),
            word("Really.", 5_000_000_000, 5_800_000_000),
        ],
        segments: [
            segment("It is like useful.", 1_000_000_000, 2_600_000_000),
            segment("Really.", 5_000_000_000, 5_800_000_000),
        ])

    @Test func aWordCutsItsOwnSpanAndNothingAroundIt() throws {
        let range = try #require(spoken.removalRange(ofWordAt: 2))
        #expect(range == 1_500_000_000..<1_900_000_000)
    }

    @Test func anIndexOutsideTheWordsIsRefusedRatherThanClamped() {
        #expect(spoken.removalRange(ofWordAt: -1) == nil)
        #expect(spoken.removalRange(ofWordAt: 5) == nil)
        #expect(Transcript.empty.removalRange(ofWordAt: 0) == nil)
    }

    /// A recogniser can report a zero-length run. Cutting nothing while telling somebody their
    /// word was deleted is worse than refusing.
    @Test func aWordWithNoDurationIsRefused() {
        let odd = Transcript(text: "x", words: [word("x", 500, 500), word("y", 900, 400)])
        #expect(odd.removalRange(ofWordAt: 0) == nil)
        #expect(odd.removalRange(ofWordAt: 1) == nil)
    }

    // MARK: - Runs

    /// **Two words chosen side by side are one thing being deleted.** Cutting them as two ranges
    /// would leave the 100 ms between "It" and "is"… here there is none, so the case that says it
    /// is the gap between "is" and "like": 1.4s to 1.5s, a tenth of a second of breath that must
    /// go with them rather than stay behind where a phrase used to be.
    @Test func adjacentWordsMergeAndTakeTheGapBetweenThemWithThem() {
        let ranges = spoken.removalRanges(ofWordsAt: [1, 2])
        #expect(ranges == [1_200_000_000..<1_900_000_000])
    }

    /// **Non-adjacent choices stay apart**, because the words between them are being KEPT and one
    /// merged span would delete them without being asked. This is the check that would catch a
    /// "merge everything from first to last" simplification.
    @Test func wordsWithAKeptWordBetweenThemStayTwoCuts() {
        let ranges = spoken.removalRanges(ofWordsAt: [0, 2])
        #expect(ranges == [1_000_000_000..<1_200_000_000, 1_500_000_000..<1_900_000_000])
    }

    @Test func theRangesComeBackInOrderWhateverOrderTheyWereChosenIn() {
        #expect(spoken.removalRanges(ofWordsAt: [4, 0]) == spoken.removalRanges(ofWordsAt: [0, 4]))
        #expect(spoken.removalRanges(ofWordsAt: [4, 0]).map(\.lowerBound)
                == [1_000_000_000, 5_000_000_000])
    }

    /// Choosing the same word twice is choosing it once. A `Set` inside says so; this says it
    /// outside, where a caller passing an array can rely on it.
    @Test func choosingAWordTwiceCutsItOnce() {
        #expect(spoken.removalRanges(ofWordsAt: [2, 2, 2]) == [1_500_000_000..<1_900_000_000])
    }

    /// **One unusable word does not refuse the run.** A zero-length word among four good ones is
    /// dropped; refusing the whole cut because of it would make a recogniser's hiccup into a
    /// feature somebody cannot use.
    @Test func anUnusableWordIsDroppedRatherThanRefusingTheWholeRun() {
        let mixed = Transcript(text: "a b", words: [word("a", 100, 100), word("b", 200, 300)])
        #expect(mixed.removalRanges(ofWordsAt: [0, 1]) == [200..<300])
    }

    @Test func choosingNothingCutsNothing() {
        #expect(spoken.removalRanges(ofWordsAt: []).isEmpty)
        #expect(spoken.removalRanges(ofWordsAt: [99]).isEmpty)
    }

    // MARK: - Pairing words with the sentences they were said in

    @Test func aSegmentOwnsTheWordsSaidInsideIt() {
        #expect(spoken.wordIndices(inSegmentAt: 0) == 0..<4)
        #expect(spoken.wordIndices(inSegmentAt: 1) == 4..<5)
    }

    /// **A word that straddles the join belongs to neither.** Rounding it into one sentence would
    /// let "cut this sentence's words" take a syllable of the next one.
    @Test func aWordAcrossTheJoinBelongsToNoSegment() {
        let straddling = Transcript(
            text: "a b",
            words: [word("across", 1_900_000_000, 5_100_000_000)],
            segments: [segment("a", 1_000_000_000, 2_000_000_000),
                       segment("b", 5_000_000_000, 6_000_000_000)])
        #expect(straddling.wordIndices(inSegmentAt: 0).isEmpty)
        #expect(straddling.wordIndices(inSegmentAt: 1).isEmpty)
    }

    /// A transcript with sentences and no word times is normal, not an error — the caller offers
    /// no word controls rather than pretending to.
    @Test func sentencesWithoutWordTimesOwnNoWords() {
        let noWords = Transcript(text: "One.", segments: [segment("One.", 0, 1_000_000_000)])
        #expect(noWords.wordIndices(inSegmentAt: 0).isEmpty)
    }

    @Test func anIndexOutsideTheSegmentsOwnsNoWords() {
        #expect(spoken.wordIndices(inSegmentAt: -1).isEmpty)
        #expect(spoken.wordIndices(inSegmentAt: 9).isEmpty)
    }
}
