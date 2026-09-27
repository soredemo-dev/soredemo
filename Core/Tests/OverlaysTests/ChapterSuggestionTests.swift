import Testing
import Foundation
import Timeline
@testable import Overlays

private func ns(_ seconds: Double) -> Nanoseconds {
    Nanoseconds(Int64((seconds * 1000).rounded()) * 1_000_000)
}

/// Ten sentences, fifteen seconds apart, each four seconds long — starting at 3 s rather than 0,
/// so a suggestion's time cannot be confused with its sentence number times anything.
private let transcript = Transcript(
    text: "",
    segments: (0..<10).map { i in
        TranscribedSegment(text: "Sentence number \(i).", start: ns(3 + Double(i) * 15),
                           end: ns(7 + Double(i) * 15))
    })

private func raw(_ pairs: (Int, String)...) -> [RawChapterSuggestion] {
    pairs.map { RawChapterSuggestion(sentence: $0.0, title: $0.1) }
}

@Suite struct ChapterSuggestionTests {
    /// The model names a sentence; the time is the TRANSCRIPT's.
    @Test func aSuggestionStartsWhereItsSentenceWasSaidAndCarriesIt() {
        let result = ChapterSuggestions.validate(raw((0, "Intro"), (4, "Recording")),
                                                 transcript: transcript, timeline: nil,
                                                 existing: ChapterTrack())
        #expect(result.accepted.map(\.start) == [ns(3), ns(63)])
        #expect(result.accepted.map(\.evidence) == ["Sentence number 0.", "Sentence number 4."])
        #expect(result.refused.isEmpty)
    }

    @Test func aSentenceThatDoesNotExistIsRefused() {
        let result = ChapterSuggestions.validate(raw((0, "Intro"), (10, "Ghost"), (-1, "Before")),
                                                 transcript: transcript, timeline: nil,
                                                 existing: ChapterTrack())
        #expect(result.accepted.map(\.sentence) == [0])
        #expect(result.refused == [.noSuchSentence(10), .noSuchSentence(-1)])
    }

    @Test func aSentenceNotAfterThePreviousIsRefused() {
        let result = ChapterSuggestions.validate(raw((5, "Later"), (2, "Earlier"), (5, "Again")),
                                                 transcript: transcript, timeline: nil,
                                                 existing: ChapterTrack())
        #expect(result.accepted.map(\.sentence) == [5])
        #expect(result.refused == [.notAfterThePrevious(2), .notAfterThePrevious(5)])
    }

    @Test func aTitleIsTrimmedAndAnEmptyOrOverlongOneIsRefused() {
        let long = String(repeating: "x", count: ChapterSuggestions.longestTitle + 1)
        let result = ChapterSuggestions.validate(raw((0, "  Intro \n"), (3, "   "), (6, long)),
                                                 transcript: transcript, timeline: nil,
                                                 existing: ChapterTrack())
        #expect(result.accepted.map(\.title) == ["Intro"])
        #expect(result.refused == [.noTitle(sentence: 3), .titleTooLong(sentence: 6)])
        let exactly = String(repeating: "y", count: ChapterSuggestions.longestTitle)
        #expect(ChapterSuggestions.validate(raw((0, exactly)), transcript: transcript, timeline: nil,
                                            existing: ChapterTrack()).accepted.count == 1)
    }

    @Test func aSentenceTheEditCutEntirelyIsRefused() {
        // Sentence 2 is 33–37 s; cut 30–40.
        let timeline = EditTimeline(clips: [
            EditClip(id: ClipID(rawValue: 1), sourceStart: ns(0), duration: ns(30)),
            EditClip(id: ClipID(rawValue: 2), sourceStart: ns(40), duration: ns(120)),
        ])
        let result = ChapterSuggestions.validate(raw((0, "Intro"), (2, "Gone"), (3, "Kept")),
                                                 transcript: transcript, timeline: timeline,
                                                 existing: ChapterTrack())
        #expect(result.accepted.map(\.sentence) == [0, 3])
        #expect(result.refused == [.sentenceWasCut(2)])
    }

    /// The producer-value rule: a chapter the person placed is never displaced, and a
    /// suggestion on top of it is refused rather than added beside it.
    @Test func aSuggestionOnTopOfAnExistingChapterIsRefusedAndTheChapterIsUntouched() throws {
        let existing = ChapterTrack().adding(title: "Mine", start: ns(50))
        let mine = try #require(existing.chapters.first)
        // Sentence 3 starts at 48 s — 2 s from the chapter. Sentence 5 at 78 s is clear of it.
        let result = ChapterSuggestions.validate(raw((3, "Theirs"), (5, "Clear")),
                                                 transcript: transcript, timeline: nil,
                                                 existing: existing)
        #expect(result.accepted.map(\.sentence) == [5])
        #expect(result.refused == [.tooCloseToAChapter(sentence: 3, chapter: mine.id)])
        #expect(existing.chapters == [mine])
    }

    @Test func twoSuggestionsTooCloseTogetherKeepTheFirst() {
        // Sentences 0 and 1 are 15 s apart — clear. A transcript with a fast talker is not.
        let fast = Transcript(text: "", segments: [
            TranscribedSegment(text: "One.", start: ns(1), end: ns(2)),
            TranscribedSegment(text: "Two.", start: ns(6), end: ns(7)),
            TranscribedSegment(text: "Three.", start: ns(30), end: ns(31)),
        ])
        let result = ChapterSuggestions.validate(raw((0, "A"), (1, "B"), (2, "C")),
                                                 transcript: fast, timeline: nil,
                                                 existing: ChapterTrack())
        #expect(result.accepted.map(\.sentence) == [0, 2])
        #expect(result.refused == [.tooCloseToTheLastSuggestion(sentence: 1)])
    }

    @Test func sentencesAreSentInWindowsThatCoverEachExactlyOnce() {
        let windows = ChapterSuggestions.windows(of: transcript, maximumCharacters: 80)
        #expect(windows.count > 1)
        #expect(windows.flatMap { Array($0) } == Array(0..<10))
        for window in windows where window.count > 1 {
            #expect(ChapterSuggestions.numberedSentences(of: transcript, in: window).count <= 80)
        }
    }

    @Test func aSentenceLongerThanAWindowStillGetsOneOfItsOwn() {
        let windows = ChapterSuggestions.windows(of: transcript, maximumCharacters: 5)
        #expect(windows == (0..<10).map { $0..<($0 + 1) })
    }

    @Test func numberedSentencesUseTheTranscriptsOwnNumbers() {
        #expect(ChapterSuggestions.numberedSentences(of: transcript, in: 3..<5)
                == "[3] Sentence number 3.\n[4] Sentence number 4.")
    }
}
