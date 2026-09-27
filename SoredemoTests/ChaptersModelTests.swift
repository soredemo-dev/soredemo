import Testing
import Foundation
import Overlays
import Timeline
@testable import Soredemo

private func ns(_ seconds: Double) -> Nanoseconds { Nanoseconds(Int64(seconds * 1_000_000_000)) }

private let transcript = Transcript(text: "", segments: [
    TranscribedSegment(text: "Install it first.", start: ns(2), end: ns(4)),
    TranscribedSegment(text: "Now record the screen.", start: ns(31), end: ns(34)),
    TranscribedSegment(text: "Then export it.", start: ns(75), end: ns(78)),
])

private func offered(_ pairs: (Int, String)..., existing: ChapterTrack = ChapterTrack())
-> (accepted: [ChapterSuggestion], refused: [SuggestionRefusal]) {
    ChapterSuggestions.validate(pairs.map { RawChapterSuggestion(sentence: $0.0, title: $0.1) },
                                transcript: transcript, timeline: nil, existing: existing)
}

@MainActor @Suite struct ChaptersModelTests {
    @Test func anAddedSuggestionIsAChapterThatSaysWhereItCameFrom() throws {
        let model = ChaptersModel()
        model.receive(offered((1, "Recording"), (2, "Export")))
        let first = try #require(model.suggestions.first)
        model.accept(first)
        #expect(model.track.chapters.map(\.title) == ["Recording"])
        #expect(model.track.chapters.first?.start == ns(31))
        #expect(model.track.chapters.first?.origin == .suggested(sentence: 1, text: "Now record the screen."))
        #expect(model.suggestions.map(\.sentence) == [2], "the added one leaves the list, the other stays")
    }

    /// The producer-value rule at the model: a chapter the person placed, then a new round of
    /// suggestions — the chapter is untouched, and only the suggestions changed.
    @Test func newSuggestionsNeverTouchAChapter() {
        let model = ChaptersModel()
        model.add(at: ns(50))
        model.retitle(model.track.chapters[0].id, to: "Mine")
        let before = model.track
        model.receive(offered((0, "Intro"), (2, "Export"), existing: before))
        #expect(model.track == before)
        #expect(model.suggestions.count == 2)
    }

    @Test func addingAllAddsEachInOrder() {
        let model = ChaptersModel()
        model.receive(offered((0, "Intro"), (1, "Recording"), (2, "Export")))
        model.acceptAll()
        #expect(model.track.chapters.map(\.title) == ["Intro", "Recording", "Export"])
        #expect(model.suggestions.isEmpty)
    }

    @Test func dismissingLeavesTheChaptersAlone() throws {
        let model = ChaptersModel()
        model.receive(offered((0, "Intro")))
        model.dismiss(try #require(model.suggestions.first))
        #expect(model.suggestions.isEmpty)
        #expect(model.track.isEmpty)
    }

    /// Suggestions belong to the recording they were made from; opening a project must not show
    /// another one's.
    @Test func openingAProjectClearsSuggestionsFromBefore() {
        let model = ChaptersModel()
        model.receive(offered((0, "Intro")))
        model.restore(ChapterTrack().adding(title: "Saved", start: ns(9)))
        #expect(model.suggestions.isEmpty && model.refusals.isEmpty)
        #expect(model.track.chapters.map(\.title) == ["Saved"])
    }
}
