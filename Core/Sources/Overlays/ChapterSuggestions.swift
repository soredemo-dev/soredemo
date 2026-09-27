import Foundation
import Timeline

/// What the model answered: a sentence number and a title. **Never a time** — see
/// `ChapterSuggestions`.
public struct RawChapterSuggestion: Sendable, Equatable {
    public let sentence: Int
    public let title: String

    public init(sentence: Int, title: String) {
        self.sentence = sentence
        self.title = title
    }
}

/// A suggestion that survived checking, with the evidence it rests on.
public struct ChapterSuggestion: Sendable, Equatable, Identifiable {
    public var id: Int { sentence }
    public let sentence: Int
    public let title: String
    /// The sentence's own start, from the transcript.
    public let start: Nanoseconds
    /// What the sentence said — shown beside the title, so a person judges the suggestion
    /// against what it is built on.
    public let evidence: String

    public var origin: ChapterOrigin { .suggested(sentence: sentence, text: evidence) }
}

/// Why a suggestion was not offered. Each names the sentence, so a refusal can be shown.
public enum SuggestionRefusal: Sendable, Equatable {
    case noSuchSentence(Int)
    case notAfterThePrevious(Int)
    case noTitle(sentence: Int)
    case titleTooLong(sentence: Int)
    case sentenceWasCut(Int)
    case tooCloseToAChapter(sentence: Int, chapter: Int)
    case tooCloseToTheLastSuggestion(sentence: Int)
}

/// **The model chooses a sentence and the transcript supplies the time**, so a suggestion
/// cannot name a moment nobody said anything at. Everything the model returns passes through
/// `validate`; nothing reaches a person unchecked. `docs/design/2026-09-27-chapters.md`.
public enum ChapterSuggestions {
    /// Longer than this is a sentence copied out, not a title.
    public static let longestTitle = 60
    /// Chapters closer than this are one chapter — the shortest the common hosts accept, so
    /// suggestions do not produce a list `ChapterList.problems` would then object to.
    public static let closestSeconds = ChapterList.shortestSeconds

    public static func validate(_ raw: [RawChapterSuggestion], transcript: Transcript,
                                timeline: EditTimeline?, existing: ChapterTrack)
    -> (accepted: [ChapterSuggestion], refused: [SuggestionRefusal]) {
        let gap = closestSeconds * 1_000_000_000
        var accepted: [ChapterSuggestion] = []
        var refused: [SuggestionRefusal] = []
        var previous = -1
        for suggestion in raw {
            let index = suggestion.sentence
            guard transcript.segments.indices.contains(index) else {
                refused.append(.noSuchSentence(index)); continue
            }
            guard index > previous else { refused.append(.notAfterThePrevious(index)); continue }
            previous = index
            let segment = transcript.segments[index]
            let title = suggestion.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty { refused.append(.noTitle(sentence: index)); continue }
            if title.count > longestTitle { refused.append(.titleTooLong(sentence: index)); continue }
            if let timeline,
               timeline.survival(ofSource: segment.start.rawValue..<segment.end.rawValue) == .gone {
                refused.append(.sentenceWasCut(index)); continue
            }
            if let near = existing.chapters.first(where: { abs($0.start.rawValue - segment.start.rawValue) < gap }) {
                refused.append(.tooCloseToAChapter(sentence: index, chapter: near.id)); continue
            }
            if let last = accepted.last, segment.start.rawValue - last.start.rawValue < gap {
                refused.append(.tooCloseToTheLastSuggestion(sentence: index)); continue
            }
            accepted.append(ChapterSuggestion(sentence: index, title: title, start: segment.start,
                                              evidence: segment.text))
        }
        return (accepted, refused)
    }

    /// Consecutive runs of sentences whose numbered text fits `maximumCharacters`, covering
    /// every sentence once. **A sentence longer than the limit gets a window of its own** rather
    /// than being split or skipped; whoever sends it finds out whether it fits.
    public static func windows(of transcript: Transcript, maximumCharacters: Int) -> [Range<Int>] {
        var windows: [Range<Int>] = []
        var start = 0
        var length = 0
        for index in transcript.segments.indices {
            let line = numberedLine(transcript, index).count + (index > start ? 1 : 0)
            if index > start, length + line > maximumCharacters {
                windows.append(start..<index)
                start = index
                length = numberedLine(transcript, index).count
            } else {
                length += line
            }
        }
        if start < transcript.segments.count { windows.append(start..<transcript.segments.count) }
        return windows
    }

    /// `[n] sentence` a line, numbered by the transcript's own indices — so an answer from any
    /// window names a sentence `validate` can find.
    public static func numberedSentences(of transcript: Transcript, in window: Range<Int>) -> String {
        window.map { numberedLine(transcript, $0) }.joined(separator: "\n")
    }

    private static func numberedLine(_ transcript: Transcript, _ index: Int) -> String {
        "[\(index)] \(transcript.segments[index].text)"
    }
}
