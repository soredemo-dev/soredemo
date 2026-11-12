import Foundation
import Testing
import Timeline
@testable import Overlays

// MARK: - correcting a term the recogniser has never heard

/// Nanoseconds, spelled once so the fixtures read as times rather than as digits.
private func ns(_ seconds: Double) -> Nanoseconds { Nanoseconds(Int64(seconds * 1_000_000_000)) }

/// The measured case, kept as a test so the thing this feature exists for cannot quietly stop
/// working. `say`-ing "Soredemo" and transcribing it returns "Sora demo" — the same phonemes,
/// split into two words — and both of Apple's biasing mechanisms leave it that way
/// (`docs/design/teaching-the-recogniser-a-word.md`).
@Test func aTermSplitIntoTwoWordsIsPutBackTogether() {
    let heard = Transcript(
        text: "Sora demo records the screen",
        words: [TranscribedWord(text: "Sora", start: ns(0), end: ns(0.4)),
                TranscribedWord(text: "demo", start: ns(0.4), end: ns(0.9)),
                TranscribedWord(text: "records", start: ns(0.9), end: ns(1.4)),
                TranscribedWord(text: "the", start: ns(1.4), end: ns(1.5)),
                TranscribedWord(text: "screen", start: ns(1.5), end: ns(2.0))],
        segments: [TranscribedSegment(text: "Sora demo records the screen",
                                      start: ns(0), end: ns(2.0))])

    let fixed = heard.correcting(terms: ["Soredemo"])

    #expect(fixed.text == "Soredemo records the screen")
    #expect(fixed.segments.map(\.text) == ["Soredemo records the screen"])
    #expect(fixed.words.map(\.text) == ["Soredemo", "records", "the", "screen"])

    // **The span the two words covered is the span the one word covers.** Nothing is
    // re-recognised, so a rewritten run must keep the first start and the last end or every
    // caption after it is timed against a word that no longer exists.
    let term = fixed.words[0]
    #expect(term.start == ns(0) && term.end == ns(0.9))
    #expect(fixed.words.last?.end == heard.words.last?.end)
}

/// **The failure mode this feature is one threshold away from.**
///
/// A pass willing to rewrite at distance 1 with no length floor turns every "cat", "cup" and
/// "can" into a three-letter product name. That is worse than the misspelling anybody minded, so a
/// term shorter than `shortestFuzzyTerm` letters has to match exactly.
@Test func aShortTermNeverSwallowsANeighbouringWord() {
    let heard = Transcript(
        text: "the cat sat on the cog",
        words: [TranscribedWord(text: "the", start: ns(0), end: ns(0.1)),
                TranscribedWord(text: "cat", start: ns(0.1), end: ns(0.4)),
                TranscribedWord(text: "sat", start: ns(0.4), end: ns(0.7)),
                TranscribedWord(text: "on", start: ns(0.7), end: ns(0.8)),
                TranscribedWord(text: "the", start: ns(0.8), end: ns(0.9)),
                TranscribedWord(text: "cog", start: ns(0.9), end: ns(1.2))])

    let fixed = heard.correcting(terms: ["Cog"])

    #expect(fixed.words.map(\.text) != ["the", "Cog", "sat", "on", "the", "Cog"],
            "a three-letter term rewrote a word at distance 1 — 'cat' became the name")
    #expect(fixed.words.map(\.text) == ["the", "cat", "sat", "on", "the", "Cog"])
    #expect(fixed.text == "the cat sat on the Cog")
}

/// Running it twice is running it once. A term matches its own spelling at distance zero, which
/// is what lets the pass re-run after an edit without compounding into something else.
@Test func correctingACorrectedTranscriptChangesNothing() {
    let heard = Transcript(
        text: "open sora demo",
        words: [TranscribedWord(text: "open", start: ns(0), end: ns(0.3)),
                TranscribedWord(text: "sora", start: ns(0.3), end: ns(0.6)),
                TranscribedWord(text: "demo", start: ns(0.6), end: ns(1.0))])
    let once = heard.correcting(terms: ["Soredemo"])
    let twice = once.correcting(terms: ["Soredemo"])
    #expect(once == twice)
    #expect(once.words.map(\.text) == ["open", "Soredemo"])
}

/// An empty list is not an edit. A caller may always call this.
@Test func noTermsMeansNoChange() {
    let heard = Transcript(text: "nothing to do here",
                           words: [TranscribedWord(text: "nothing", start: ns(0), end: ns(1))])
    #expect(heard.correcting(terms: []) == heard)
    // Whitespace and punctuation are not terms either — they normalise to nothing, and a term
    // that normalises to nothing would match every run.
    #expect(heard.correcting(terms: ["", "  ", "—"]) == heard)
}

/// Punctuation around a rewritten run survives. A caption that gained or lost a full stop
/// because a brand name was corrected would be a second edit nobody asked for.
@Test func aFullStopAfterATermIsNotEatenByIt() {
    let heard = Transcript(text: "Press record in sora demo. Then stop.")
    let fixed = heard.correcting(terms: ["Soredemo"])
    #expect(fixed.text == "Press record in Soredemo. Then stop.")
}

/// The longest run wins, so a list carrying both a term and its first word is not decided by
/// which was typed first.
@Test func aLongerTermBeatsAShorterOneInsideIt() {
    let heard = Transcript(
        text: "final cut pro is open",
        words: [TranscribedWord(text: "final", start: ns(0), end: ns(0.3)),
                TranscribedWord(text: "cut", start: ns(0.3), end: ns(0.5)),
                TranscribedWord(text: "pro", start: ns(0.5), end: ns(0.8)),
                TranscribedWord(text: "is", start: ns(0.8), end: ns(0.9)),
                TranscribedWord(text: "open", start: ns(0.9), end: ns(1.2))])
    for order in [["Final Cut Pro", "Finalise"], ["Finalise", "Final Cut Pro"]] {
        let fixed = heard.correcting(terms: order)
        #expect(fixed.words.map(\.text) == ["Final Cut Pro", "is", "open"],
                "term order changed the result — the longest run must win first")
    }
}

/// Ties go to the term listed first, because the order of the list is the only thing in it that
/// carries an intention.
///
/// **A genuine tie, which the first version of this test did not have.** It paired an exact
/// spelling against a near one and asserted the order decided — but the exact one is strictly
/// closer, so it wins whichever way round it is typed, and the test was checking that the
/// better match loses. Both terms here sit at distance 1 from what was heard.
@Test func twoTermsAtTheSameDistanceAreDecidedByTheList() {
    let heard = Transcript(text: "kubernetes",
                           words: [TranscribedWord(text: "kubernetes", start: ns(0), end: ns(1))])
    #expect(Transcript.distance("kubernetes", "kubernetos", noMoreThan: 1) == 1)
    #expect(Transcript.distance("kubernetes", "kubernetez", noMoreThan: 1) == 1)

    #expect(heard.correcting(terms: ["Kubernetos", "Kubernetez"]).words[0].text == "Kubernetos")
    #expect(heard.correcting(terms: ["Kubernetez", "Kubernetos"]).words[0].text == "Kubernetez")

    // And a strictly closer term still wins from second place, which is the case the tie rule
    // must not swallow.
    #expect(heard.correcting(terms: ["Kubernetez", "Kubernetes"]).words[0].text == "Kubernetes")
}

/// A word the recogniser mangled beyond a segmentation — different sounds, not a different split
/// — stays mangled. This is a spelling pass, and saying so is the point.
@Test func aTermTheRecogniserNeverApproximatedIsLeftAlone() {
    let heard = Transcript(text: "the elephant walked",
                           words: [TranscribedWord(text: "elephant", start: ns(0), end: ns(1))])
    let fixed = heard.correcting(terms: ["Kubernetes"])
    #expect(fixed == heard, "an unrelated word was rewritten — the tolerance is far too wide")
}

/// The tolerance is a function of length, and this pins the shape of it rather than one value:
/// nothing fuzzy below the floor, one edit at eight letters, two at sixteen.
@Test func theToleranceGrowsWithTheTermRatherThanBeingAConstant() {
    #expect(Transcript.tolerance(forNormalisedLength: 4) == nil)
    #expect(Transcript.tolerance(forNormalisedLength: 5) == 1)
    #expect(Transcript.tolerance(forNormalisedLength: 8) == 1)
    #expect(Transcript.tolerance(forNormalisedLength: 16) == 2)
    #expect(Transcript.tolerance(forNormalisedLength: 24) == 3)

    // And the distance function agrees with what the tolerance promises.
    #expect(Transcript.distance("soredemo", "sorademo", noMoreThan: 1) == 1)
    #expect(Transcript.distance("soredemo", "sordemo", noMoreThan: 1) == 1)
    #expect(Transcript.distance("soredemo", "elephant", noMoreThan: 1) == nil)
    #expect(Transcript.distance("", "", noMoreThan: 0) == 0)
}

// MARK: - matching by sound

/// **The mishearings measured on macOS 27.2**, which a spelling pass cannot reach: "Cubernades" is
/// three edits from "Kubernetes" against a tolerance of one, "Sorodimo" two from "Soredemo". Both
/// are the same sounds with different letters — c for k, d for t, a vowel for a vowel — and a
/// pass that matches by sound puts them right
/// (`docs/design/2026-11-12-captions-that-know-what-was-on-screen.md`).
@Test func aNameHeardWithTheSameSoundsButOtherLettersIsCorrected() {
    let heard = Transcript(
        text: "click export to Cubernades in Sorodimo",
        words: [TranscribedWord(text: "click", start: ns(0), end: ns(0.3)),
                TranscribedWord(text: "export", start: ns(0.3), end: ns(0.7)),
                TranscribedWord(text: "to", start: ns(0.7), end: ns(0.8)),
                TranscribedWord(text: "Cubernades", start: ns(0.8), end: ns(1.5)),
                TranscribedWord(text: "in", start: ns(1.5), end: ns(1.6)),
                TranscribedWord(text: "Sorodimo", start: ns(1.6), end: ns(2.2))])

    let fixed = heard.correcting(terms: ["Kubernetes", "Soredemo"])

    #expect(fixed.words.map(\.text) == ["click", "export", "to", "Kubernetes", "in", "Soredemo"])
    #expect(fixed.text == "click export to Kubernetes in Soredemo")
    #expect(fixed.words[3].start == ns(0.8) && fixed.words[3].end == ns(1.5), "the word keeps its time")
}

/// **Sounding alike is not enough.** "connote" shares a sound key with "Keynote" — k, n, t — and is
/// a real English word somebody says. The spelling has to be close as well, within a third of the
/// name, or every word that rhymes with a product becomes it.
@Test func aWordThatSoundsAlikeButIsSpelledFarAwayIsLeftAlone() {
    let heard = Transcript(text: "these words connote speed",
                           words: [TranscribedWord(text: "these", start: ns(0), end: ns(0.3)),
                                   TranscribedWord(text: "words", start: ns(0.3), end: ns(0.6)),
                                   TranscribedWord(text: "connote", start: ns(0.6), end: ns(1.0)),
                                   TranscribedWord(text: "speed", start: ns(1.0), end: ns(1.3))])
    #expect(Transcript.soundKey("connote") == Transcript.soundKey("Keynote"), "the case this guards against")
    #expect(heard.correcting(terms: ["Keynote"]) == heard)
}

/// The key folds what a listener confuses and nothing else: c/k/q and the voiced-unvoiced pairs,
/// vowels after the first letter, a doubled consonant. Two words with different consonants differ.
@Test func theSoundKeyFoldsWhatAListenerConfusesAndKeepsTheRest() {
    #expect(Transcript.soundKey("Cubernades") == Transcript.soundKey("Kubernetes"))
    #expect(Transcript.soundKey("Sorodimo") == Transcript.soundKey("Soredemo"))
    #expect(Transcript.soundKey("Sora demo") == Transcript.soundKey("Soredemo"), "spacing is not a sound")
    #expect(Transcript.soundKey("Kubernetes") != Transcript.soundKey("elephant"))
    #expect(Transcript.soundKey("Keynote") != Transcript.soundKey("Keyboard"))
    #expect(Transcript.soundKey("Export") == Transcript.soundKey("Egsbord") , "x is k-s, and b/p, t/d fold")
}

/// A short name is matched exactly, by sound as by spelling: "code" and a product called "Kode"
/// share a key and are one edit apart, and a four-letter key is shared by too much English to be
/// evidence that the name was said.
@Test func aShortNameIsNotMatchedBySound() {
    let heard = Transcript(text: "open the code", words: [TranscribedWord(text: "open", start: ns(0), end: ns(0.3)),
                                                          TranscribedWord(text: "the", start: ns(0.3), end: ns(0.4)),
                                                          TranscribedWord(text: "code", start: ns(0.4), end: ns(0.8))])
    #expect(Transcript.soundKey("code") == Transcript.soundKey("Kode"), "the case this guards against")
    #expect(heard.correcting(terms: ["Kode"]) == heard)
}
