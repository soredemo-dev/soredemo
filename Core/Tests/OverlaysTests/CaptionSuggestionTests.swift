import Foundation
import Testing
import Timeline
@testable import Overlays

// Corrections proposed from what was on screen. The observation log's labels and application
// names are words a person was looking at while they spoke; a caption that misheard one of them
// is offered the on-screen spelling, with where it came from
// (`docs/design/2026-11-12-captions-that-know-what-was-on-screen.md`).

private func ns(_ seconds: Double) -> Nanoseconds { Nanoseconds(Int64(seconds * 1_000_000_000)) }

private func track(_ lines: String...) -> CaptionTrack {
    CaptionTrack(cues: lines.enumerated().map { index, text in
        CaptionCue(text: text, start: ns(Double(index) * 2), end: ns(Double(index) * 2 + 1.5))
    })
}

@Suite struct CaptionSuggestionTests {
    /// The measured mishearing, offered once for every line it is in, naming the step whose
    /// pressed element carried the right spelling.
    @Test func aMisheardLabelIsOfferedWithItsOriginForEveryLineItIsIn() {
        let suggestions = CaptionSuggestions.suggestions(
            for: track("click export to Cubernades", "then Cubernades deploys it", "and that is all"),
            evidence: [VocabularyEvidence(term: "Kubernetes", origin: .pressedLabel(step: 4))])
        #expect(suggestions == [CaptionSuggestion(was: "Cubernades", now: "Kubernetes",
                                                  lines: [0, 1], origin: .pressedLabel(step: 4))])
    }

    /// A word the recogniser got right except for its capital is not a correction: "export" said
    /// aloud is not the button "Export", and offering it would bury the real ones.
    @Test func aDifferenceOfCaseAloneIsNotACorrection() {
        let suggestions = CaptionSuggestions.suggestions(
            for: track("now click export and wait"),
            evidence: [VocabularyEvidence(term: "Export", origin: .pressedLabel(step: 2))])
        #expect(suggestions.isEmpty)
    }

    /// A line that already says the name is not offered it again.
    @Test func aLineThatAlreadySaysTheNameIsLeftAlone() {
        let suggestions = CaptionSuggestions.suggestions(
            for: track("open Soredemo from the menu bar"),
            evidence: [VocabularyEvidence(term: "Soredemo", origin: .application(step: 1))])
        #expect(suggestions.isEmpty)
    }

    /// The same spelling from two places is one suggestion, credited to the earliest step: what
    /// was on screen first is what the speaker was looking at when they first said it.
    @Test func oneCorrectionFromTwoPlacesIsOneSuggestionCreditedToTheFirst() {
        let suggestions = CaptionSuggestions.suggestions(
            for: track("open Sorodimo now"),
            evidence: [VocabularyEvidence(term: "Soredemo", origin: .application(step: 5)),
                       VocabularyEvidence(term: "Soredemo", origin: .pressedLabel(step: 2))])
        #expect(suggestions.map(\.origin) == [.pressedLabel(step: 2)])
    }

    /// A suggestion the person turned down is not offered again; the others still are.
    @Test func aDismissedSuggestionIsNotOfferedAgain() {
        let captions = track("Cubernades in Sorodimo")
        let evidence = [VocabularyEvidence(term: "Kubernetes", origin: .pressedLabel(step: 1)),
                        VocabularyEvidence(term: "Soredemo", origin: .application(step: 1))]
        let all = CaptionSuggestions.suggestions(for: captions, evidence: evidence)
        #expect(all.map(\.now) == ["Kubernetes", "Soredemo"])
        let rest = CaptionSuggestions.suggestions(for: captions, evidence: evidence, dismissed: [all[0].id])
        #expect(rest.map(\.now) == ["Soredemo"])
    }

    /// Accepting one rewrites exactly the run it named, in exactly the lines it listed.
    @Test func acceptingASuggestionRewritesTheRunEverywhereItWas() {
        let captions = track("click export to Cubernades", "then Cubernades deploys it")
        let suggestion = CaptionSuggestions.suggestions(
            for: captions, evidence: [VocabularyEvidence(term: "Kubernetes", origin: .pressedLabel(step: 4))])[0]
        let fixed = captions.replacing(suggestion.was, with: suggestion.now)
        #expect(fixed.cues.map(\.text) == ["click export to Kubernetes", "then Kubernetes deploys it"])
        #expect(fixed.cues.map(\.start) == captions.cues.map(\.start), "a correction does not move a line")
    }

    /// A sound-alike that is spelled far from the name stays as the person said it.
    @Test func aWordThatOnlySoundsLikeTheNameIsNotOffered() {
        let suggestions = CaptionSuggestions.suggestions(
            for: track("these words connote speed"),
            evidence: [VocabularyEvidence(term: "Keynote", origin: .application(step: 1))])
        #expect(suggestions.isEmpty)
    }
}
