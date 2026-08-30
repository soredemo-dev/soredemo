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

    public init(text: String, start: Nanoseconds, end: Nanoseconds) {
        self.text = text
        self.start = start
        self.end = end
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
