import Foundation
import Timeline

/// One line of caption and when it is on screen.
public struct CaptionCue: Sendable, Equatable, Codable {
    public var text: String
    public var start: Nanoseconds
    public var end: Nanoseconds
    /// The words inside this line with their own timings, for a caption that highlights the word
    /// being said. Empty when the recogniser gave no word timings — a cue is still a cue.
    public var words: [TranscribedWord]

    public init(text: String, start: Nanoseconds, end: Nanoseconds,
                words: [TranscribedWord] = []) {
        self.text = text
        self.start = start
        self.end = end
        self.words = words
    }

    public var duration: Nanoseconds { Nanoseconds(max(0, end.rawValue - start.rawValue)) }

    /// The word the recogniser was least sure of, when it said and when it was unsure enough to
    /// be worth a look.
    ///
    /// **Below 0.8, which is where the tail of the distribution starts.** Measured on a clean
    /// narration: the 5th percentile of confidence was 0.78 and the 10th was 0.87, so 0.8 is
    /// about the worst one word in ten. On audio carrying a name the recogniser does not know,
    /// the mangled word came back at 0.46 — the lowest of its cue, which is what makes this
    /// worth showing at all.
    ///
    /// `nil` when nothing is below it, so a cue with nothing to check says nothing. Shown for
    /// the cue somebody is looking at and never used to mark a cue in a list: on clean speech
    /// the low scores are mostly sentence-initial words that were recognised correctly, and a
    /// marker that is usually wrong is one people stop reading.
    public var leastCertainWord: TranscribedWord? {
        words
            .filter { ($0.confidence ?? 1) < CaptionCue.uncertainBelow }
            .min { ($0.confidence ?? 1) < ($1.confidence ?? 1) }
    }

    public static let uncertainBelow: Double = 0.8

    public func contains(_ time: Nanoseconds) -> Bool {
        time.rawValue >= start.rawValue && time.rawValue < end.rawValue
    }
}

/// Turns a transcript into caption-sized lines. Written from a specification
/// (`docs/design/2026-11-11-caption-line-breaking.md`), which the tests carry.
///
/// 1. **Where to break is chosen, not fallen into.** Every space is a candidate; each possible line
///    has a cost — balance by width, a dearer ending on a word that leads into the next, a single
///    stranded word dearer still — and the cheapest set of breaks is found by dynamic programming.
///    A line that crosses a boundary must start and end on one at least as strong (a sentence end
///    over a clause over any space), which is what keeps "Yes." a line of its own.
/// 2. **`fits` is a closure, not a character limit.** Whether a line fits is a question about the
///    font, the size and the canvas. The caller measures; this file decides where to break.
/// 3. **Lines are timed by the characters they contain.** A recogniser's runs need not split on
///    spaces, so a line is matched to runs by its letters and digits rather than by its words.
public enum CaptionBuilder {
    /// The floor a line stays on screen. A caption shown for its spoken duration is unreadable
    /// when that duration is a short word — often under 200 ms.
    ///
    /// **`CaptionMeasurement.shortestDisplay`, not a number of its own.** Two numbers would mean
    /// the panel warning "too brief" about lines this builder had just produced.
    public static let minimumDisplay = CaptionMeasurement.shortestDisplay

    /// The widest a line of a spaced script may be, in `CaptionMeasurement.width` units.
    static let longestLine = CaptionScript.spaced.longestLine

    /// Lines for one segment.
    ///
    /// - Parameters:
    ///   - fits: whether a candidate line fits the caption box. Called many times per segment,
    ///     so a caller measuring text should cache.
    ///   - maximumWords: a hard cap on top of `fits`, or `nil` for "as many as fit". A cap is
    ///     what produces the one-to-three-words-at-a-time style, which is a look rather than a
    ///     constraint — so it is a choice, and the default is nil.
    public static func cues(for segment: TranscribedSegment,
                            words: [TranscribedWord] = [],
                            fits: (String) -> Bool,
                            maximumWords: Int? = nil,
                            minimumDisplay: Nanoseconds = CaptionBuilder.minimumDisplay
    ) -> [CaptionCue] {
        let inside = words.filter { lies($0, inside: segment) }
        let lines = timedLines(for: segment, runs: inside, fits: fits, maximumWords: maximumWords)
        return holdingFloor(lines, minimumDisplay: minimumDisplay)
    }

    /// Lines for a whole transcript, in order.
    ///
    /// **Falls back to the word list when there are no segments.** Some recognisers report only
    /// runs; a caption path that needed segments would produce nothing for those, which is worse
    /// than one long synthetic segment broken by the same rules.
    /// - Parameter pauses: where the RECORDING is silent, from `SilenceFinder`. Empty is the
    ///   behaviour every caller had before this existed: segments are cut by punctuation and
    ///   length alone.
    public static func cues(for transcript: Transcript,
                            fits: (String) -> Bool,
                            maximumWords: Int? = nil,
                            minimumDisplay: Nanoseconds = CaptionBuilder.minimumDisplay,
                            pauses: [SilenceFinder.Span] = []
    ) -> [CaptionCue] {
        let segments = transcript.segments.isEmpty
            ? synthesisedSegment(from: transcript.words).map { [$0] } ?? []
            : transcript.segments
        let index = RunIndex(transcript.words)
        let silences = pauses.filter { $0.end.rawValue > $0.start.rawValue }
        var lines: [CaptionCue] = []
        for segment in segments {
            for piece in cut(segment, runs: index.runs(inside: segment), at: silences) {
                lines += timedLines(for: piece.segment, runs: piece.runs,
                                    fits: fits, maximumWords: maximumWords)
            }
        }
        // Once over the whole list: a segment's last line has to see the next segment's first.
        return holdingFloor(lines, minimumDisplay: minimumDisplay)
    }

    /// Two lines from one that has no punctuation to break at. Tested directly.
    ///
    /// The same line cost the whole-segment search uses, restricted to exactly two lines and
    /// with nothing infeasible: the cheapest single break wins.
    static func breakAtMiddleWord(_ text: String) -> [String] {
        let layout = Layout(text)
        guard layout.count > 1 else { return layout.tokens }
        var bestBreak = 1
        var bestCost = Int.max
        for split in 1..<layout.count {
            let cost = layout.cost(0, split) + layout.cost(split, layout.count)
            if cost < bestCost { bestCost = cost; bestBreak = split }
        }
        return [layout.text(0, bestBreak), layout.text(bestBreak, layout.count)]
    }
}

// MARK: - Choosing the breaks

extension CaptionBuilder {
    /// What a gap between two words is, ranked. `edge` is the start or end of the segment.
    enum Boundary: Int, Comparable {
        case word, clause, sentence, edge

        static func < (lhs: Boundary, rhs: Boundary) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The cheapest set of break points, by dynamic programming over the gaps between words.
    ///
    /// **Fewest lines first, then the lowest summed `Layout.cost`.** Two rules make a line
    /// infeasible rather than expensive: it fails a size test (`fits`, the reading limit, the
    /// word cap), or it crosses a boundary of a higher rank than the boundaries it starts and
    /// ends on. The second is what "a sentence end before a clause, a clause before anywhere
    /// else" means as a constraint: two whole sentences may share a line, but a line never holds
    /// the end of one sentence and half of the next. A single word is always feasible — it is
    /// left whole even when it overflows — so there is always a solution.
    ///
    /// Size tests are assumed to only get harder as a line grows, so extending a line stops at
    /// the first failure: `fits` is called at most once per (start, end) pair and in practice
    /// a line's worth of times per word.
    static func lines(of text: String, fits: (String) -> Bool, maximumWords: Int?) -> [String] {
        let layout = Layout(text)
        let n = layout.count
        guard n > 1 else { return layout.tokens }
        let cap = max(1, maximumWords ?? Int.max)

        var best: [(lines: Int, cost: Int)?] = Array(repeating: nil, count: n + 1)
        var previous = Array(repeating: 0, count: n + 1)
        best[0] = (0, 0)
        for start in 0..<n {
            guard let reached = best[start] else { continue }
            var crossed = Boundary.word
            for end in (start + 1)...n {
                if end - start > 1 {
                    crossed = max(crossed, layout.after[end - 2])
                    guard end - start <= cap,
                          layout.width(start, end) <= longestLine,
                          fits(layout.text(start, end))
                    else { break }
                }
                guard layout.opening(start) >= crossed, layout.closing(end) >= crossed else {
                    continue
                }
                let candidate = (lines: reached.lines + 1,
                                 cost: reached.cost + layout.cost(start, end))
                if let held = best[end],
                   (held.lines, held.cost) <= (candidate.lines, candidate.cost) {
                    continue
                }
                best[end] = candidate
                previous[end] = start
            }
        }
        var result: [String] = []
        var end = n
        while end > 0 {
            let start = previous[end]
            result.append(layout.text(start, end))
            end = start
        }
        return result.reversed()
    }

    /// A segment's words with what the search needs to know about them, computed once.
    struct Layout {
        let tokens: [String]
        /// `after[k]` is the boundary between token `k` and token `k + 1`.
        let after: [Boundary]
        private let prefixWidth: [Int]

        var count: Int { tokens.count }

        init(_ text: String) {
            tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
            var widths = [0]
            for token in tokens {
                widths.append(widths[widths.count - 1] + CaptionMeasurement.width(of: token))
            }
            prefixWidth = widths
            after = Layout.boundaries(tokens)
        }

        func width(_ start: Int, _ end: Int) -> Int { prefixWidth[end] - prefixWidth[start] }
        func text(_ start: Int, _ end: Int) -> String { tokens[start..<end].joined(separator: " ") }
        func opening(_ start: Int) -> Boundary { start == 0 ? .edge : after[start - 1] }
        func closing(_ end: Int) -> Boundary { end == count ? .edge : after[end - 1] }

        /// One line's cost. Squared width is what balances a fixed number of lines by
        /// characters; the penalties are in the same units — `2k²` is what moving a break `k`
        /// characters off the centre costs — so each reads as "how far off balance is worth it":
        /// a forward-binding last word is worth eight characters, a stranded word fifteen.
        func cost(_ start: Int, _ end: Int) -> Int {
            let width = width(start, end)
            var cost = width * width
            let closing = closing(end)
            switch closing {
            case .clause: cost += 8
            case .word: cost += 32 + (Layout.bindsForward(tokens[end - 1]) ? 128 : 0)
            case .sentence, .edge: break
            }
            // A one-word sentence is a line somebody said; any other lone word is stranded.
            if end - start == 1, !(opening(start) >= .sentence && closing >= .sentence) {
                cost += 450
            }
            return cost
        }

        /// Each gap ranked by the punctuation before it, then a one-word clause folded into
        /// its neighbour. Folding only ever merges, so a merged clause has two words or more
        /// and one pass is enough; sentence ends are never folded ("Yes." stands alone).
        private static func boundaries(_ tokens: [String]) -> [Boundary] {
            guard tokens.count > 1 else { return [] }
            var ranks = tokens.dropLast().map(boundary(after:))
            // Indices into `tokens` where a clause-or-higher unit ends, with the segment's end.
            let unitEnds = ranks.indices.filter { ranks[$0] >= .clause } + [tokens.count - 1]
            var unitStart = 0
            var unitLengths: [Int] = []
            for end in unitEnds { unitLengths.append(end - unitStart + 1); unitStart = end + 1 }
            for (position, end) in unitEnds.dropLast().enumerated() where ranks[end] == .clause {
                if unitLengths[position] == 1 || unitLengths[position + 1] == 1 {
                    ranks[end] = .word
                }
            }
            return ranks
        }

        /// The rank of the gap after `token`: a sentence end, a clause end, or a plain space.
        private static func boundary(after token: String) -> Boundary {
            var core = Substring(token)
            while let last = core.last, "\"')]}»”’".contains(last) { core = core.dropLast() }
            guard let mark = core.last else { return .word }
            if core.hasSuffix("...") || mark == "…" { return .clause }
            if mark == "!" || mark == "?" { return .sentence }
            if ",;:".contains(mark) { return .clause }
            guard mark == "." else { return .word }
            return isAbbreviation(core.dropLast()) ? .word : .sentence
        }

        /// "U.S", "e.g", "Mr": a full stop that closes these is not the end of a sentence.
        /// A decimal is not one ("3.14." ends a sentence); its inner stop has no space after
        /// it and never reaches here.
        private static func isAbbreviation(_ body: Substring) -> Bool {
            let parts = body.split(separator: ".", omittingEmptySubsequences: false)
            if parts.count > 1 {
                return parts.allSatisfy {
                    !$0.isEmpty && $0.count <= 2 && $0.allSatisfy(\.isLetter)
                }
            }
            return titles.contains(body.lowercased())
        }

        private static let titles: Set<String> = ["mr", "mrs", "ms", "dr", "prof", "vs", "st"]

        /// A word that opens a phrase and never closes one: ending a line on it leaves the
        /// reader holding half a thought across the break.
        static func bindsForward(_ token: String) -> Bool {
            forwardBinding.contains(token.lowercased())
        }

        private static let forwardBinding: Set<String> = [
            "a", "an", "the", "of", "to", "in", "on", "at", "by", "for", "from", "with", "into",
            "onto", "about", "as", "and", "or", "but", "nor", "if", "how", "what", "when",
            "where", "which", "who", "why", "that", "my", "your", "our", "their", "his", "her",
            "its", "this", "these", "those",
        ]
    }
}

// MARK: - Timing the lines

extension CaptionBuilder {
    /// A segment's lines with times, before the display floor.
    static func timedLines(for segment: TranscribedSegment, runs: [TranscribedWord],
                           fits: (String) -> Bool, maximumWords: Int?) -> [CaptionCue] {
        let texts = lines(of: segment.text, fits: fits, maximumWords: maximumWords)
        guard !texts.isEmpty else { return [] }
        return runs.isEmpty
            ? shared(texts, across: segment)
            : aligned(texts, to: runs, within: segment)
    }

    /// No word timings: the segment's span shared out by width, back to back, the last line
    /// ending exactly where the segment does. Integer arithmetic at full width, so no
    /// rounding drift and no overflow on a long span.
    private static func shared(_ texts: [String],
                               across segment: TranscribedSegment) -> [CaptionCue] {
        let start = segment.start.rawValue
        let span = max(0, segment.end.rawValue - start)
        let weights = texts.map { Int64(max(1, CaptionMeasurement.width(of: $0))) }
        let total = weights.reduce(0, +)
        var cues: [CaptionCue] = []
        var running: Int64 = 0
        var lineStart = start
        for (index, text) in texts.enumerated() {
            running += weights[index]
            let lineEnd = index == texts.count - 1
                ? start + span
                : start + total.dividingFullWidth(span.multipliedFullWidth(by: running)).quotient
            cues.append(CaptionCue(text: text, start: Nanoseconds(lineStart),
                                   end: Nanoseconds(lineEnd)))
            lineStart = lineEnd
        }
        return cues
    }

    /// Word timings: each run goes to the line holding its first letter or digit, counted
    /// along the segment; a run with none (a lone apostrophe) goes to the line it trails. When
    /// the runs spell more or fewer characters than the text, positions are scaled so the
    /// two still meet at both ends. A line no run landed on takes the time between its
    /// neighbours rather than being dropped.
    private static func aligned(_ texts: [String], to runs: [TranscribedWord],
                                within segment: TranscribedSegment) -> [CaptionCue] {
        var lineEnds: [Int] = []
        for text in texts { lineEnds.append((lineEnds.last ?? 0) + alphanumerics(in: text)) }
        let textTotal = lineEnds[lineEnds.count - 1]
        let runCounts = runs.map { alphanumerics(in: $0.text) }
        let runTotal = runCounts.reduce(0, +)

        var owned: [[TranscribedWord]] = Array(repeating: [], count: texts.count)
        var before = 0
        for (run, count) in zip(runs, runCounts) {
            let position = runTotal == textTotal || runTotal == 0
                ? before
                : Int((Double(before) * Double(textTotal) / Double(runTotal)).rounded(.down))
            let line = count > 0
                ? lineEnds.firstIndex { position < $0 } ?? texts.count - 1
                : lineEnds.firstIndex { position <= $0 } ?? texts.count - 1
            owned[line].append(run)
            before += count
        }

        var cues = texts.enumerated().map { index, text in
            CaptionCue(text: text, start: owned[index].first?.start ?? segment.start,
                       end: owned[index].last?.end ?? segment.end, words: owned[index])
        }
        for index in cues.indices where owned[index].isEmpty {
            let start = index > 0 ? cues[index - 1].end : segment.start
            let next = cues[(index + 1)...].first { !$0.words.isEmpty }?.start ?? segment.end
            cues[index].start = start
            cues[index].end = max(start, next)
        }
        return cues
    }

    /// Letters and digits, which is what a run and a line both spell however they are split.
    static func alphanumerics(in text: some StringProtocol) -> Int {
        text.unicodeScalars.reduce(0) { $0 + (CharacterSet.alphanumerics.contains($1) ? 1 : 0) }
    }

    /// Each line held for at least `minimumDisplay`, but never into the next line's start —
    /// and never overlapping it, whatever the timings said, since the track shows one line.
    static func holdingFloor(_ cues: [CaptionCue], minimumDisplay: Nanoseconds) -> [CaptionCue] {
        var held = cues
        for index in held.indices {
            let start = held[index].start.rawValue
            var end = max(held[index].end.rawValue, start + minimumDisplay.rawValue)
            if index + 1 < held.count {
                end = min(end, max(held[index + 1].start.rawValue, start))
            }
            held[index].end = Nanoseconds(end)
        }
        return held
    }
}

// MARK: - The transcript's structure

extension CaptionBuilder {
    static func lies(_ word: TranscribedWord, inside segment: TranscribedSegment) -> Bool {
        word.start.rawValue >= segment.start.rawValue && word.end.rawValue <= segment.end.rawValue
    }

    /// Runs with no segments, as one segment spanning all of them.
    private static func synthesisedSegment(from words: [TranscribedWord]) -> TranscribedSegment? {
        let text = words.map(\.text).joined(separator: " ")
        guard let start = words.map(\.start).min(), let end = words.map(\.end).max(),
              !text.allSatisfy(\.isWhitespace)
        else { return nil }
        return TranscribedSegment(text: text, start: start, end: end)
    }

    /// The runs of a whole transcript, for finding one segment's without rescanning them all.
    /// A recogniser emits them in time order, which allows a binary search; a list that is not
    /// in order is filtered in full instead, which is slower and gives the same answer.
    struct RunIndex {
        let runs: [TranscribedWord]
        let ordered: Bool

        init(_ runs: [TranscribedWord]) {
            self.runs = runs
            ordered = zip(runs, runs.dropFirst()).allSatisfy { $0.start <= $1.start }
        }

        func runs(inside segment: TranscribedSegment) -> [TranscribedWord] {
            guard ordered else { return runs.filter { CaptionBuilder.lies($0, inside: segment) } }
            var low = 0, high = runs.count
            while low < high {
                let middle = (low + high) / 2
                if runs[middle].start < segment.start { low = middle + 1 } else { high = middle }
            }
            var inside: [TranscribedWord] = []
            var index = low
            while index < runs.count, runs[index].start <= segment.end {
                if CaptionBuilder.lies(runs[index], inside: segment) { inside.append(runs[index]) }
                index += 1
            }
            return inside
        }
    }

    /// A segment cut where the recording is silent between two of its runs.
    ///
    /// A pause separates runs `k` and `k + 1` when it touches the gap between them — the
    /// closed interval from one's end to the other's start. A pause wholly inside one run
    /// touches no gap and cuts nothing. Each piece takes its text from the segment's own text,
    /// cut after the same count of letters and digits the runs before the cut spell, so the
    /// segment's punctuation survives and an uncut segment is returned untouched.
    private static func cut(_ segment: TranscribedSegment, runs: [TranscribedWord],
                            at pauses: [SilenceFinder.Span])
        -> [(segment: TranscribedSegment, runs: [TranscribedWord])] {
        let whole = [(segment: segment, runs: runs)]
        guard !pauses.isEmpty, runs.count > 1 else { return whole }
        let cuts = (0..<(runs.count - 1)).filter { k in
            pauses.contains {
                $0.start.rawValue <= runs[k + 1].start.rawValue
                    && $0.end.rawValue >= runs[k].end.rawValue
            }
        }
        guard !cuts.isEmpty else { return whole }

        let scalars = Array(segment.text.unicodeScalars)
        let dense = CaptionScript.of(segment.text) == .dense
        var pieces: [(segment: TranscribedSegment, runs: [TranscribedWord])] = []
        var spelledThrough: [Int] = []
        for run in runs {
            spelledThrough.append((spelledThrough.last ?? 0) + alphanumerics(in: run.text))
        }
        var firstRun = 0
        var textFrom = 0
        for boundary in cuts + [runs.count - 1] {
            let last = boundary == runs.count - 1
            let spelled = spelledThrough[boundary]
            let textTo = last
                ? scalars.count
                : cutPosition(in: scalars, after: spelled, dense: dense)
            let text = String(String.UnicodeScalarView(scalars[textFrom..<max(textFrom, textTo)]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // A cut the text cannot honour (it would leave a piece with no words) is skipped,
            // and its runs stay with the next piece.
            guard !text.isEmpty || last else { continue }
            let pieceRuns = Array(runs[firstRun...boundary])
            let start = pieces.isEmpty ? segment.start : pieceRuns[0].start
            let end = last ? segment.end : pieceRuns[pieceRuns.count - 1].end
            if text.isEmpty, let previous = pieces.popLast() {
                let merged = TranscribedSegment(text: previous.segment.text,
                                                start: previous.segment.start, end: end)
                pieces.append((merged, previous.runs + pieceRuns))
            } else {
                pieces.append((TranscribedSegment(text: text, start: start, end: end), pieceRuns))
            }
            firstRun = boundary + 1
            textFrom = textTo
        }
        return pieces
    }

    /// Where the text is cut after its `count`-th letter or digit: past any punctuation that
    /// trails it and, in a spaced script, on to the end of the word, so a run boundary that
    /// falls inside a word never splits it.
    private static func cutPosition(in scalars: [Unicode.Scalar], after count: Int,
                                    dense: Bool) -> Int {
        var seen = 0
        var position = 0
        while position < scalars.count, seen < count {
            if CharacterSet.alphanumerics.contains(scalars[position]) { seen += 1 }
            position += 1
        }
        let space = CharacterSet.whitespacesAndNewlines
        while position < scalars.count, !space.contains(scalars[position]),
              !dense || !CharacterSet.alphanumerics.contains(scalars[position]) {
            position += 1
        }
        return position
    }
}
