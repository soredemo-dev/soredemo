import Foundation
import Timeline

/// Every caption for one recording, in the recording's own time.
///
/// **Source time, always — the output's time is derived.** A cut moves every caption after it,
/// and a track stored in output time would have to be rewritten on every trim; one stored in
/// source time is rewritten on none of them. That is architecture rule 7's producer-value rule,
/// and it is the same reason `ZoomAdjustment` keys on the click rather than on the block.
public struct CaptionTrack: Sendable, Equatable, Codable {
    public var cues: [CaptionCue]

    public init(cues: [CaptionCue] = []) {
        self.cues = cues.sorted { $0.start.rawValue < $1.start.rawValue }
    }

    public var isEmpty: Bool { cues.isEmpty }

    /// The cue on screen at `time`, or `nil`. Cues do not overlap after `CaptionBuilder`, so the
    /// first match is the only match.
    public func cue(at time: Nanoseconds) -> CaptionCue? {
        cues.first { $0.contains(time) }
    }

    /// The same captions in the EDIT's time: cues inside a cut disappear, cues spanning a cut
    /// are split at it, and everything after a cut moves back by what the cut removed.
    ///
    /// **Split rather than dropped or stretched.** A sentence that straddles a removed pause is
    /// still two things a person said; dropping it loses a line of speech that is still in the
    /// video, and keeping it whole would leave a caption on screen across a jump cut describing
    /// words the cut removed.
    public func retimed(through timeline: EditTimeline) -> CaptionTrack {
        CaptionTrack(cues: cues.flatMap { cue in
            timeline.clips.compactMap { clip -> CaptionCue? in
                let start = max(cue.start.rawValue, clip.sourceStart.rawValue)
                let end = min(cue.end.rawValue, clip.sourceEnd.rawValue)
                guard end > start else { return nil }
                guard let outputStart = timeline.outputTime(atSource: Nanoseconds(start))
                else { return nil }
                let outputEnd = outputStart.rawValue + (end - start)
                // Words are clipped to the surviving span too, so a highlight cannot point at a
                // word the cut removed.
                let words = cue.words.compactMap { word -> TranscribedWord? in
                    let wordStart = max(word.start.rawValue, start)
                    let wordEnd = min(word.end.rawValue, end)
                    guard wordEnd > wordStart else { return nil }
                    return TranscribedWord(
                        text: word.text,
                        start: Nanoseconds(outputStart.rawValue + (wordStart - start)),
                        end: Nanoseconds(outputStart.rawValue + (wordEnd - start)))
                }
                return CaptionCue(text: cue.text, start: outputStart,
                                  end: Nanoseconds(outputEnd), words: words)
            }
        })
    }

    /// A cue's text replaced, keeping its timing. What editing a caption is: a recogniser gets a
    /// name or an acronym wrong far more often than it gets the timing wrong, so correcting the
    /// text must not re-time the line.
    public func replacingText(at index: Int, with text: String) -> CaptionTrack {
        guard cues.indices.contains(index) else { return self }
        var updated = cues
        updated[index].text = text
        return CaptionTrack(cues: updated)
    }

    public func removing(at index: Int) -> CaptionTrack {
        guard cues.indices.contains(index) else { return self }
        var updated = cues
        updated.remove(at: index)
        return CaptionTrack(cues: updated)
    }
}
