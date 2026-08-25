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
