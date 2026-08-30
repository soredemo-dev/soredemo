import Foundation
import Timeline

/// One recognised word and when it was said, in the RECORDING's own time.
///
/// Nanoseconds rather than the seconds every speech API hands back, because everything else in
/// this project measures time in nanoseconds and a transcript that did not would need converting
/// at every comparison — which is where an off-by-a-frame comes from.
public struct TranscribedWord: Sendable, Equatable, Codable {
    public let text: String
    public let start: Nanoseconds
    public let end: Nanoseconds
    /// How sure the recogniser was, 0…1, or `nil` when it did not say.
    ///
    /// **Information, never a warning — and that distinction is measured.** Requesting
    /// `.transcriptionConfidence` returns a value for every run (93 of 93 on a narration), and
    /// on audio the recogniser genuinely mangles it finds the mangling: "Soredemo" heard as
    /// "Sorodimo" scored 0.462, the lowest of nine.
    ///
    /// But it is noisy in a way that matters. On a clean narration the low scores were almost
    /// all sentence-INITIAL or sentence-final — "Trim", "If", "When", "screen." — every one of
    /// them recognised correctly. They are where the endpointer cut, not where it was wrong.
    /// Flagging everything under 0.8 would mark 8% of words and most of those would be right,
    /// which is how people learn to ignore a marker.
    ///
    /// So this is shown for the cue somebody is looking at and nothing is coloured by it.
    /// `nil` rather than 1 when absent: "did not say" and "was certain" are different answers,
    /// and a default of 1 would make an old project claim a confidence nothing measured.
    public let confidence: Double?

    public init(text: String, start: Nanoseconds, end: Nanoseconds, confidence: Double? = nil) {
        self.text = text
        self.start = start
        self.end = end
        // Clamped rather than trapped: it arrives from a framework and from a decoder, and
        // rule 8 forbids trapping on an untrusted input.
        self.confidence = confidence.map { $0.isFinite ? min(max($0, 0), 1) : 0 }
    }
}

/// One endpointed run of speech — what a recogniser considers a sentence.
public struct TranscribedSegment: Sendable, Equatable, Codable {
    public let text: String
    public let start: Nanoseconds
    public let end: Nanoseconds

    public init(text: String, start: Nanoseconds, end: Nanoseconds) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// What a recogniser heard: the whole text, its segments, and per-word timings where the
/// recogniser gave them.
///
/// **Words are separate from segments and neither is derived from the other.** A recogniser
/// endpoints on silence, so its segments are where a person paused; its word runs are where each
/// sound was. Captions need both — the segments say where a sentence ends, the words say when to
/// change the line — and reconstructing either from the other loses exactly the information the
/// other one had.
///
/// **`words` may be empty.** Not every locale's model reports word timings, and a caption path
/// that assumed they existed would produce nothing at all for those languages rather than
/// captions timed by sharing out the segment — see `CaptionBuilder`.
public struct Transcript: Sendable, Equatable, Codable {
    public let text: String
    /// BCP 47. `nil` when the recogniser did not say.
    public let languageCode: String?
    public let words: [TranscribedWord]
    public let segments: [TranscribedSegment]

    public init(text: String, languageCode: String? = nil,
                words: [TranscribedWord] = [], segments: [TranscribedSegment] = []) {
        self.text = text
        self.languageCode = languageCode
        self.words = words
        self.segments = segments
    }

    public static let empty = Transcript(text: "")

    public var isEmpty: Bool { segments.isEmpty && words.isEmpty }

    /// **The span of the recording a "delete this sentence" removes: the sentence, and only
    /// the sentence.**
    ///
    /// `nil` for an index outside `segments`, or for a segment whose own times are degenerate —
    /// cutting nothing while telling somebody their sentence was deleted is worse than refusing.
    ///
    /// **The pause after it is deliberately left, and a first draft took it.** A gap between
    /// sentences can be ten seconds of deliberate pause as easily as a breath, and this app
    /// already has one owner for where the silences are — `SilenceFinder`, the Silence lane, and
    /// `Remove Silent Span(s)`. Deciding it a second time here would be a second answer to a
    /// question already answered. `docs/design/deleting-a-sentence.md` has the argument in full.
    ///
    /// **Source time, so a second deletion needs no re-mapping.** A transcript is timed against
    /// the recording rather than the edit, and `EditTimeline.removing(sourceRange:)` takes
    /// source time too — so deleting three sentences one at a time gives the same result in any
    /// order.
    public func removalRange(ofSegmentAt index: Int) -> Range<Int64>? {
        guard segments.indices.contains(index) else { return nil }
        let segment = segments[index]
        let start = segment.start.rawValue, end = segment.end.rawValue
        guard end > start else { return nil }
        return start..<end
    }

    /// Which of `words` were said inside the segment at `index`.
    ///
    /// The two arrays are timed against the same recording and are otherwise unrelated — the
    /// recogniser reports sentences and words separately — so the only honest way to pair them is
    /// by time. A word belongs to a segment when it lies inside it; a word that straddles the
    /// join belongs to neither, which is the right answer rather than a rounding: cutting it as
    /// part of a sentence it is only half inside would take a syllable of the next one.
    ///
    /// **A range rather than a list, because `words` is in time order** and a segment's words are
    /// therefore contiguous in it. Empty when the recogniser gave sentences but no word times,
    /// which happens and is not an error — the caller offers no word controls rather than
    /// pretending to.
    public func wordIndices(inSegmentAt index: Int) -> Range<Int> {
        guard segments.indices.contains(index) else { return 0..<0 }
        let segment = segments[index]
        let inside = words.indices.filter {
            words[$0].start.rawValue >= segment.start.rawValue
                && words[$0].end.rawValue <= segment.end.rawValue
        }
        guard let first = inside.first, let last = inside.last else { return 0..<0 }
        return first..<(last + 1)
    }

    /// **The span a "delete this word" removes: the word, and only the word.**
    ///
    /// The same rule `removalRange(ofSegmentAt:)` states, at the smaller scale, and for the same
    /// reasons: the pause on either side belongs to whoever owns pauses, which here is
    /// `SilenceFinder` and the Silence lane.
    ///
    /// `nil` for an index outside `words`, or for a word whose own times are degenerate.
    public func removalRange(ofWordAt index: Int) -> Range<Int64>? {
        guard words.indices.contains(index) else { return nil }
        let word = words[index]
        let start = word.start.rawValue, end = word.end.rawValue
        guard end > start else { return nil }
        return start..<end
    }

    /// The spans a set of chosen words removes, with adjacent choices merged into one.
    ///
    /// **Adjacent words are merged, and the gap between them goes with them.** Two words chosen
    /// side by side are one thing a person is deleting; cutting them as two ranges leaves the
    /// pause between them behind, which is a fragment of somebody's breath sitting where a phrase
    /// used to be. Merging from the first word's start to the last one's end takes it.
    ///
    /// **Non-adjacent choices stay separate**, because the words between them are being kept and
    /// merging across would delete them without being asked.
    ///
    /// Returned in source time and in order, so a caller can hand each to
    /// `EditTimeline.removing(sourceRange:)` in any order and get the same edit. Words with
    /// degenerate times are dropped rather than refused: one unusable word is not a reason to
    /// refuse the run, and a zero-length cut would do nothing while claiming otherwise.
    public func removalRanges(ofWordsAt indices: some Sequence<Int>) -> [Range<Int64>] {
        let usable = Set(indices).filter { removalRange(ofWordAt: $0) != nil }.sorted()
        guard !usable.isEmpty else { return [] }

        var runs: [[Int]] = []
        for index in usable {
            if let last = runs.last?.last, index == last + 1 {
                runs[runs.count - 1].append(index)
            } else {
                runs.append([index])
            }
        }
        return runs.compactMap { run in
            guard let first = run.first, let last = run.last else { return nil }
            let start = words[first].start.rawValue
            let end = words[last].end.rawValue
            guard end > start else { return nil }
            return start..<end
        }
    }

    /// Every timestamp shifted, for a transcript taken from an extracted span of a longer
    /// recording, in nanoseconds. Transcribing a selection is
    /// how a long recording stays affordable, and the result is useless if it is not put back
    /// where it came from.
    public func offset(by delta: Int64) -> Transcript {
        guard delta != 0 else { return self }
        return Transcript(
            text: text, languageCode: languageCode,
            words: words.map {
                TranscribedWord(text: $0.text,
                                start: Nanoseconds($0.start.rawValue + delta),
                                end: Nanoseconds($0.end.rawValue + delta))
            },
            segments: segments.map {
                TranscribedSegment(text: $0.text,
                                   start: Nanoseconds($0.start.rawValue + delta),
                                   end: Nanoseconds($0.end.rawValue + delta))
            })
    }
}

// MARK: - correcting a term the recogniser has never heard

/// A spelling pass over what the recogniser returned, toward terms a person named.
///
/// **It fixes the text; it does not make the recogniser hear the word.** Both mechanisms Apple
/// publishes for biasing recognition were measured on this platform and changed nothing —
/// `docs/design/teaching-the-recogniser-a-word.md` has the numbers — so this is what is left,
/// and the interface says what it is rather than letting somebody infer that captions got more
/// accurate.
///
/// Word timings survive because nothing is re-recognised: a run rewritten to one term keeps the
/// first word's start and the last word's end, so a correction may be applied before or after a
/// cut and mean the same thing.
extension Transcript {
    /// The longest run of words a term may span. A term is a name, not a sentence, and every
    /// extra word multiplies the candidates a match is chosen from for no case anybody has.
    static let maximumWordsPerTerm = 4

    /// Below this many letters a term must match EXACTLY after normalising.
    ///
    /// **The threshold exists because the failure mode is worse than the problem.** At distance 1
    /// a three-letter term collides with most three-letter words — a pass that rewrote every
    /// "cat" and "cup" toward a three-letter product name would do more damage than the
    /// misspelling anybody minded. Long terms are where collisions stop being likely and
    /// biasing starts being worth it.
    static let shortestFuzzyTerm = 5

    /// Bounds on the list, because this is O(terms × words × run lengths) and the list arrives
    /// from a saved project as well as from a text field. **Clamped here rather than at decode**:
    /// this is the function that pays the cost, so it is the one place that cannot be bypassed by
    /// a future caller. Two hundred names is more than any recording has; a term longer than a
    /// short phrase is not a name.
    static let maximumTerms = 200
    static let longestTerm = 120

    /// Letters and digits, folded to lower case. Punctuation and spacing are dropped because
    /// "Sora demo", "sora-demo" and "soraDemo" are the same failure and a person naming a term
    /// should not have to guess which one the recogniser produced.
    static func normalised(_ text: some StringProtocol) -> String {
        String(text.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }.map(Character.init))
    }

    /// How far apart two normalised strings are, capped so a hopeless comparison stops early.
    ///
    /// Ordinary Levenshtein over two rows rather than a full matrix: the terms are short, this
    /// runs per candidate run per word, and the matrix would be the only allocation here.
    static func distance(_ a: String, _ b: String, noMoreThan limit: Int) -> Int? {
        if abs(a.count - b.count) > limit { return nil }
        let left = Array(a), right = Array(b)
        var previous = Array(0...right.count)
        var current = previous
        for i in 1...max(left.count, 1) where !left.isEmpty {
            current[0] = i
            var best = i
            for j in 1...max(right.count, 1) where !right.isEmpty {
                let substitution = previous[j - 1] + (left[i - 1] == right[j - 1] ? 0 : 1)
                current[j] = min(substitution, previous[j] + 1, current[j - 1] + 1)
                best = min(best, current[j])
            }
            // Every remaining row can only grow the answer, so a row whose best cell already
            // exceeds the limit cannot come back under it.
            if best > limit { return nil }
            swap(&previous, &current)
        }
        let answer = left.isEmpty ? right.count : previous[right.count]
        return answer <= limit ? answer : nil
    }

    /// The largest edit distance a term of this length will accept, or `nil` for "exact only".
    static func tolerance(forNormalisedLength length: Int) -> Int? {
        guard length >= shortestFuzzyTerm else { return nil }
        return max(1, length / 8)
    }

    /// The best term for a run of words, or `nil` if none is close enough.
    ///
    /// Ties go to the term the person listed FIRST. Not to the shortest or the alphabetically
    /// first: the list is theirs and its order is the only thing here that carries an intention.
    static func match(_ candidate: String, against terms: [(term: String, normalised: String)])
        -> (index: Int, distance: Int)? {
        var best: (index: Int, distance: Int)?
        for (index, term) in terms.enumerated() {
            let limit = tolerance(forNormalisedLength: term.normalised.count)
            let found: Int?
            if let limit {
                found = distance(candidate, term.normalised, noMoreThan: limit)
            } else {
                found = candidate == term.normalised ? 0 : nil
            }
            guard let found else { continue }
            if best == nil || found < best!.distance { best = (index, found) }
        }
        return best
    }

    /// This transcript with every close-enough run rewritten to the term's own spelling.
    ///
    /// Returns `self` for an empty list, so a caller may always call it. **Idempotent**: a term
    /// matches its own spelling at distance zero, so correcting a corrected transcript changes
    /// nothing — which is what lets this run again after an edit without compounding.
    public func correcting(terms: [String]) -> Transcript {
        let prepared = terms
            .prefix(Self.maximumTerms)
            .map { (term: String($0.prefix(Self.longestTerm)), normalised: Self.normalised($0)) }
            .filter { !$0.normalised.isEmpty }
        guard !prepared.isEmpty else { return self }

        return Transcript(text: Self.correcting(text: text, with: prepared),
                          languageCode: languageCode,
                          words: Self.correcting(words: words, with: prepared),
                          segments: segments.map {
                              TranscribedSegment(text: Self.correcting(text: $0.text,
                                                                       with: prepared),
                                                 start: $0.start, end: $0.end)
                          })
    }

    /// Word runs merged into one word per match, keeping the span the run covered.
    static func correcting(words: [TranscribedWord],
                           with terms: [(term: String, normalised: String)]) -> [TranscribedWord] {
        var out: [TranscribedWord] = []
        var index = 0
        while index < words.count {
            var replaced = false
            // Longest run first: a term of three words must win over its own first word matching
            // a shorter term, or a list containing both would depend on which was typed first.
            for length in stride(from: min(maximumWordsPerTerm, words.count - index),
                                 through: 1, by: -1) {
                let run = words[index..<(index + length)]
                let candidate = normalised(run.map(\.text).joined())
                guard !candidate.isEmpty,
                      let hit = match(candidate, against: terms) else { continue }
                out.append(TranscribedWord(text: terms[hit.index].term,
                                           start: run.first!.start, end: run.last!.end))
                index += length
                replaced = true
                break
            }
            if !replaced {
                out.append(words[index])
                index += 1
            }
        }
        return out
    }

    /// The same pass over a plain string, splicing by range so spacing and punctuation around a
    /// rewritten run survive exactly. A caption that gained or lost a comma because a brand name
    /// was corrected would be a second, unasked-for edit.
    static func correcting(text: String,
                           with terms: [(term: String, normalised: String)]) -> String {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: false)
        guard tokens.count > 1 || !tokens.isEmpty else { return text }
        var out: [String] = []
        var index = 0
        while index < tokens.count {
            var replaced = false
            for length in stride(from: min(maximumWordsPerTerm, tokens.count - index),
                                 through: 1, by: -1) {
                let run = tokens[index..<(index + length)]
                let candidate = normalised(run.joined())
                guard !candidate.isEmpty,
                      let hit = match(candidate, against: terms) else { continue }
                // Trailing punctuation belongs to the sentence, not to the word: a term matched
                // across "demo." must not eat the full stop.
                let tail = String(run.last!.reversed().prefix {
                    !CharacterSet.alphanumerics.contains($0.unicodeScalars.first!)
                }.reversed())
                out.append(terms[hit.index].term + tail)
                index += length
                replaced = true
                break
            }
            if !replaced {
                out.append(String(tokens[index]))
                index += 1
            }
        }
        return out.joined(separator: " ")
    }
}
