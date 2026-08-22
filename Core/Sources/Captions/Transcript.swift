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

    /// Every timestamp shifted, for a transcript taken from an extracted span of a longer
    /// recording. a native editor's `offsetting(by:)`, in nanoseconds — transcribing a selection is
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
