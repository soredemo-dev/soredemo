import Testing
import Foundation
import Carbon.HIToolbox
import Geometry
import Overlays
import Project
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

// MARK: - marks placed while recording


private let markEpoch = BootEpoch(id: UUID(uuidString: "5A5A5A5A-1111-2222-3333-444444444444")!)

private func oneSegment() throws -> SegmentTable {
    try SegmentTable(segments: [
        MasterSegment(index: 0, mediaFilename: "a.mov",
                      hostRange: HostRange(epoch: markEpoch, start: ns(500), duration: ns(120)),
                      revision: GeometryRevision(id: 3), endedBy: .stopped),
    ])
}

private func mark(_ seconds: Double) -> HostInstant { HostInstant(epoch: markEpoch, hostTime: ns(seconds)) }

@MainActor @Suite struct ChapterMarkSeedingModelTests {
    @Test func aNewRecordingsMarksBecomeNumberedChapters() throws {
        let model = ChaptersModel()
        let refused = model.seed(fromMarks: [mark(560), mark(530), mark(499)], in: try oneSegment())
        #expect(model.track.chapters.map(\.start) == [ns(30), ns(60)])
        #expect(model.track.chapters.map(\.title)
                == [String(localized: "Chapter \(1)"), String(localized: "Chapter \(2)")])
        #expect(refused == 1)
    }

    /// The producer-value rule: marks are derived, a chapter already here is a person's. Seeding
    /// over it would put back what they removed or replace what they wrote.
    @Test func marksNeverReplaceChaptersAlreadyThere() throws {
        let model = ChaptersModel()
        model.add(at: ns(10))
        model.retitle(model.track.chapters[0].id, to: "Mine")
        let before = model.track
        _ = model.seed(fromMarks: [mark(560)], in: try oneSegment())
        #expect(model.track == before)
    }
}

/// **The mark key is ⌥⌘M, and that pair is the one `InputObserver`'s own test refuses to
/// approve** (`CaptureTests.theChapterMarkKeyIsNotAKeystrokeTheVideoShows`). Pinned here because
/// the two live in targets that cannot see each other; changing one without the other reddens this.
@Test func theChapterMarkKeyIsOptionCommandM() {
    #expect(GlobalHotkey.markChapterKeyCode == UInt32(kVK_ANSI_M))
    #expect(GlobalHotkey.markChapterModifiers == UInt32(cmdKey | optionKey))
}
