import Overlays
import Testing
import Timeline
@testable import Soredemo

private func s(_ seconds: Int64) -> Nanoseconds { Nanoseconds(seconds * 1_000_000_000) }

/// Four lines in which the product's name, misheard, is in the SECOND, third and fourth — so the
/// first match is not at index 0 and a filtered position cannot pass for a track index.
private let track = CaptionTrack(cues: [
    CaptionCue(text: "Welcome to the demo", start: s(0), end: s(2)),
    CaptionCue(text: "Open Sore Demo now", start: s(2), end: s(4)),
    CaptionCue(text: "then sore demo records", start: s(4), end: s(6)),
    CaptionCue(text: "and Sore Demo edits", start: s(6), end: s(8)),
])

@MainActor @Suite struct CaptionListStateTests {
    // MARK: - the search

    @Test func theSearchIgnoresCaseAndSpacesAndKeepsTheTrackIndex() {
        let state = CaptionListState()
        state.search = "  SORE demo "
        #expect(state.visibleCues(of: track).map(\.index) == [1, 2, 3])
        state.search = ""
        #expect(state.visibleCues(of: track).count == 4, "no search is every line")
    }

    // MARK: - the offer to fix the rest

    /// The edited track: line 1 corrected to the product's name.
    private func corrected(_ text: String, at index: Int) -> CaptionTrack {
        var cues = track.cues
        cues[index] = CaptionCue(text: text, start: cues[index].start, end: cues[index].end)
        return CaptionTrack(cues: cues)
    }

    @Test func aCorrectionThatFitsOtherLinesIsOfferedWithTheCountAndTheWholeWord() throws {
        let state = CaptionListState()
        state.remember(1, in: track)
        state.noteCorrection(at: 1, in: corrected("Open Soredemo now", at: 1))
        let offer = try #require(state.offer)
        #expect(offer.others == 1, "only the fourth line has the same capitalisation; the third is lower-case")
        #expect(offer.word == "Soredemo", "the whole word, not the changed run")
    }

    @Test func aCorrectionNothingElseSharesOffersNothing() {
        let state = CaptionListState()
        state.remember(0, in: track)
        // "Welcome" is in no other line. ("demo" would not do: the third line says it.)
        state.noteCorrection(at: 0, in: corrected("Hello to the demo", at: 0))
        #expect(state.offer == nil)
    }

    /// The remembered text belongs to one row; comparing it with another's is two different lines.
    ///
    /// **The fixture is chosen so that comparing them WOULD make an offer.** The fourth line is
    /// remembered and the second is committed with text one run away from the fourth's, a run
    /// another line shares. A first version committed text nothing like the remembered line;
    /// `RunEdit` refused it as a rewrite, and the test passed with the row check deleted.
    @Test func aCommitOnARowThatWasNotRememberedOffersNothing() {
        let state = CaptionListState()
        state.remember(3, in: track)
        state.noteCorrection(at: 1, in: corrected("and Soredemo edits", at: 1))
        #expect(state.offer == nil)
    }

    // MARK: - the row's timecode

    @Test func theTimecodeIsMinutesSecondsAndTenths() {
        #expect(CaptionLines.timecode(Nanoseconds(7_450_000_000)) == "0:07.4")
        #expect(CaptionLines.timecode(Nanoseconds(83_900_000_000)) == "1:23.9")
    }
}
