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
    /// a recogniser can report a zero-length run, and cutting nothing while telling somebody
    /// their sentence was deleted is worse than refusing.
    ///
    /// **The pause after it is deliberately left, and a first draft took it.** Speech is
    /// separated by pauses, so cutting only the words leaves one on each side of the join and
    /// a doubled pause reads as a fault rather than as an edit — which is the argument for
    /// extending the cut to where the next sentence begins. It is the wrong argument here for
    /// two reasons. A gap between sentences can be ten seconds of deliberate pause as easily as
    /// a breath, and a rule that swallows it removes content nobody asked to remove. And this
    /// app already has one owner for where the silences are and what to do about them —
    /// `SilenceFinder`, the Silence lane, and `Remove Silent Span(s)` — so deciding it a second
    /// time here would be a second answer to a question already answered, the same fault
    /// `MusicDucking.speech(betweenSilences:over:)` exists to avoid.
    ///
    /// In practice the gap is usually small anyway: a recogniser endpoints AFTER a silence
    /// threshold, so a segment's own end already carries part of the pause that ended it.
    ///
    /// **Source time, so a second deletion needs no re-mapping.** A transcript is timed against
    /// the recording, not against the edit, and `EditTimeline.removing(sourceRange:)` takes
    /// source time too — so deleting three sentences one at a time gives the same result in any
    /// order, and none of the three ranges has to be recomputed after the others land.
    public func removalRange(ofSegmentAt index: Int) -> Range<Int64>? {
        guard segments.indices.contains(index) else { return nil }
        let segment = segments[index]
        let start = segment.start.rawValue, end = segment.end.rawValue
        guard end > start else { return nil }
        return start..<end
    }

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
