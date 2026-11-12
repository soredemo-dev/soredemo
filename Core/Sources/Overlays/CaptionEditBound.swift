import Foundation

/// How much one agent edit may change a caption line
/// (`docs/design/2026-11-12-captions-that-know-what-was-on-screen.md`, decision 3).
///
/// **A bound on the edit, not a judgement of it.** The failure the research names is the fluent
/// rewrite: a model that "corrects" a line into what it thinks was meant, and invents a name nobody
/// said. A misheard name corrected changes a word or two; a rewrite changes the line. How much
/// changed is the cheapest thing that tells the two apart, and applying it needs no model.
///
/// **Counted in words, where a Chinese or Japanese character is a word.** Those scripts carry no
/// spaces, so splitting on spaces would make every such line one word and every edit a rewrite of
/// all of it. A run of other letters — "Soredemo" written into a Chinese line — is one word, so
/// putting a product's Latin name where the recogniser heard four characters changes four.
public enum CaptionEditBound {
    /// What an edit changed.
    public struct Change: Sendable, Equatable {
        /// How many words differ: the longer of the two differing middles.
        public let changed: Int
        /// How many words the line had before.
        public let length: Int
        /// The most one edit may change in a line this long.
        public var allowed: Int { CaptionEditBound.allowed(length: length) }
        public var isWithinBound: Bool { changed <= allowed }
    }

    /// A third of the line rounded up, and never under two: a two-word name misheard as two other
    /// words is what the tool is for, and it has to fit in a three-word line too.
    public static func allowed(length: Int) -> Int {
        max(2, (length + 2) / 3)
    }

    /// What changed from `before` to `after`. **The differing middle, after the words both
    /// share at each end**: two small corrections far apart count as everything between them.
    /// That over-counts on purpose, because two corrections are two calls, each with its reason.
    public static func change(from before: String, to after: String) -> Change {
        let old = words(before), new = words(after)
        var head = 0
        while head < old.count, head < new.count, old[head] == new[head] { head += 1 }
        var tail = 0
        while tail < old.count - head, tail < new.count - head,
              old[old.count - 1 - tail] == new[new.count - 1 - tail] { tail += 1 }
        return Change(changed: max(old.count - head - tail, new.count - head - tail), length: old.count)
    }

    static func words(_ text: String) -> [String] {
        var words: [String] = []
        var run = ""
        for character in text {
            if character.isWhitespace {
                if !run.isEmpty { words.append(run); run = "" }
            } else if isUnspacedScript(character) {
                if !run.isEmpty { words.append(run); run = "" }
                words.append(String(character))
            } else {
                run.append(character)
            }
        }
        if !run.isEmpty { words.append(run) }
        return words
    }

    /// Han ideographs, and hiragana and katakana: the scripts written without spaces between words.
    /// Hangul is written with spaces and is not here.
    private static func isUnspacedScript(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return scalar.properties.isIdeographic || (0x3040...0x30FF).contains(scalar.value)
    }
}
