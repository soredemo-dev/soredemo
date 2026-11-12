import Foundation

/// A word that was on screen while the recording was made, and where it was.
///
/// **Structured, not a sentence**: the app words the origin in the person's language, and the
/// agent reads it as data. A pressed element's label is the strongest evidence — the speaker was
/// pointing at it — and an application's name the next.
public struct VocabularyEvidence: Sendable, Equatable {
    public enum Origin: Sendable, Equatable, Hashable {
        /// The label of the element pressed in this step.
        case pressedLabel(step: Int)
        /// The name of the application this step happened in.
        case application(step: Int)

        public var step: Int {
            switch self {
            case .pressedLabel(let step), .application(let step): step
            }
        }
    }

    public let term: String
    public let origin: Origin

    public init(term: String, origin: Origin) {
        self.term = term
        self.origin = origin
    }
}

/// One correction proposed from what was on screen: a run the recogniser produced, the on-screen
/// spelling it is close to, the lines it is in and where the spelling came from.
public struct CaptionSuggestion: Sendable, Equatable, Identifiable {
    public let was: String
    public let now: String
    /// Indices into the caption track's cues, ascending.
    public let lines: [Int]
    public let origin: VocabularyEvidence.Origin

    /// The same correction is the same suggestion wherever it was found, so a dismissal holds
    /// across a rebuild of the lines.
    public var id: String { "\(was)\u{1F}\(now)" }

    public init(was: String, now: String, lines: [Int], origin: VocabularyEvidence.Origin) {
        self.was = was
        self.now = now
        self.lines = lines
        self.origin = origin
    }
}

/// Corrections proposed from the observation log's vocabulary — never applied by this type.
///
/// **Proposed, not applied** (`docs/design/2026-11-12-captions-that-know-what-was-on-screen.md`):
/// the person's own names list corrects silently because the person wrote it; a label the
/// recording happened to contain is evidence, and a person or their agent accepts it. Matching is
/// `Transcript`'s, by spelling and by sound, so the two never disagree about what is close.
public enum CaptionSuggestions {
    public static func suggestions(for track: CaptionTrack, evidence: [VocabularyEvidence],
                                   dismissed: Set<String> = []) -> [CaptionSuggestion] {
        // Earliest step first, and a pressed label before an application name in the same step:
        // the first piece of evidence that proposes a correction is the one it is credited to.
        let ordered = evidence.enumerated().sorted { a, b in
            if a.element.origin.step != b.element.origin.step { return a.element.origin.step < b.element.origin.step }
            if a.element.origin.isLabel != b.element.origin.isLabel { return a.element.origin.isLabel }
            return a.offset < b.offset
        }.map(\.element)
        let terms = ordered.map { (term: String($0.term.prefix(Transcript.longestTerm)),
                                   normalised: Transcript.normalised($0.term)) }
            .filter { !$0.normalised.isEmpty }
        guard !terms.isEmpty else { return [] }

        var found: [CaptionSuggestion] = []
        for (line, cue) in track.cues.enumerated() {
            for (was, termIndex) in Transcript.matchedRuns(in: cue.text, with: terms) {
                let now = terms[termIndex].term
                // The same letters and digits is the same word: a capital or a hyphen is not a
                // correction anybody needs offered.
                guard Transcript.normalised(was) != Transcript.normalised(now) else { continue }
                let suggestion = CaptionSuggestion(was: was, now: now, lines: [line],
                                                   origin: ordered[termIndex].origin)
                guard !dismissed.contains(suggestion.id) else { continue }
                if let index = found.firstIndex(where: { $0.id == suggestion.id }) {
                    let existing = found[index]
                    if existing.lines.last != line {
                        found[index] = CaptionSuggestion(was: existing.was, now: existing.now,
                                                         lines: existing.lines + [line], origin: existing.origin)
                    }
                } else {
                    found.append(suggestion)
                }
            }
        }
        return found
    }
}

private extension VocabularyEvidence.Origin {
    var isLabel: Bool { if case .pressedLabel = self { true } else { false } }
}

extension Transcript {
    /// Each run of `text` that matches a term, as written in `text` without trailing punctuation,
    /// with the index of the term it matched — the same walk as `correcting(text:with:)`, which
    /// rewrites what this reports.
    static func matchedRuns(in text: String,
                            with terms: [(term: String, normalised: String)]) -> [(String, Int)] {
        let tokens = text.split(separator: " ")
        var runs: [(String, Int)] = []
        var index = 0
        while index < tokens.count {
            var advanced = false
            for length in stride(from: min(maximumWordsPerTerm, tokens.count - index), through: 1, by: -1) {
                let run = tokens[index..<(index + length)]
                let candidate = normalised(run.joined())
                guard !candidate.isEmpty, let hit = match(candidate, against: terms) else { continue }
                let written = run.joined(separator: " ")
                let trimmed = String(written.reversed().drop {
                    !CharacterSet.alphanumerics.contains($0.unicodeScalars.first!)
                }.reversed())
                runs.append((trimmed, hit.index))
                index += length
                advanced = true
                break
            }
            if !advanced { index += 1 }
        }
        return runs
    }
}
