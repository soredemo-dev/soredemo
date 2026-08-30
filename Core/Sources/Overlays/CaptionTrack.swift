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
                // **A source span takes `1/speed` as long to play, and this used to ignore that.**
                // The START went through `outputTime(atSource:)`, which divides; the END was
                // `outputStart + (end - start)`, which does not. Measured on a 2× clip: a cue at
                // source 0–2 came out at output 0–2 instead of 0–1, and the cue after it at 1–3
                // instead of 1–2 — every caption on a sped-up clip drawn for twice its length and
                // overlapping its successor by half of it. `played(_:)` is the one conversion now.
                let outputEnd = outputStart.rawValue + played(end - start, at: clip.speed)
                // Words are clipped to the surviving span too, so a highlight cannot point at a
                // word the cut removed — and they take the same conversion, or a highlight lands
                // on the wrong word for the whole of a sped-up clip.
                let words = cue.words.compactMap { word -> TranscribedWord? in
                    let wordStart = max(word.start.rawValue, start)
                    let wordEnd = min(word.end.rawValue, end)
                    guard wordEnd > wordStart else { return nil }
                    return TranscribedWord(
                        text: word.text,
                        start: Nanoseconds(outputStart.rawValue
                                           + played(wordStart - start, at: clip.speed)),
                        end: Nanoseconds(outputStart.rawValue
                                         + played(wordEnd - start, at: clip.speed)))
                }
                return CaptionCue(text: cue.text, start: outputStart,
                                  end: Nanoseconds(outputEnd), words: words)
            }
        })
    }

    /// How long a span of the RECORDING takes to PLAY at a clip's speed. The same arithmetic
    /// `EditTimeline.outputTime(atSource:)` does, spelled once here so a duration and an instant
    /// cannot disagree about it.
    private func played(_ sourceSpan: Int64, at speed: Double) -> Int64 {
        Int64((Double(sourceSpan) / speed).rounded())
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

// MARK: - correcting a cue's timing, and where one cue ends

/// **The three edits a recogniser's mistakes actually need**, and until now none of them existed:
/// text could be retyped and a line deleted, and that was the whole of it. A cue whose timing was
/// wrong could not be corrected at all — see `docs/design/what-a-caption-editor-is.md`.
///
/// All three return a new track and none of them can produce an invalid one. Every method here
/// **clamps against the neighbours** rather than refusing: a person dragging a boundary past the
/// next cue means "as far as it goes", and an edit that silently did nothing would read as the
/// control being broken.
extension CaptionTrack {
    /// How close two cues may sit. Two frames at 24 fps is the published minimum gap, and it is
    /// the reason a boundary stops short of its neighbour rather than touching it: cues that
    /// abut exactly leave `cue(at:)` deciding a tie on a frame nobody can see.
    public static let shortestGap = Nanoseconds(83_333_333)

    /// A cue moved to a new span, clamped so it cannot swallow or cross its neighbours.
    ///
    /// The floor is `CaptionMeasurement.shortestDisplay`, and it wins over the requested span:
    /// dragging a start past its own end produces the shortest legal cue rather than a backwards
    /// one. A cue with nowhere to go — neighbours closer together than the floor plus two gaps —
    /// is returned unchanged, which is the one case clamping cannot answer.
    public func retiming(at index: Int, start: Nanoseconds, end: Nanoseconds) -> CaptionTrack {
        guard cues.indices.contains(index) else { return self }
        let floor = CaptionMeasurement.shortestDisplay.rawValue
        let gap = Self.shortestGap.rawValue

        let earliest = index > 0 ? cues[index - 1].end.rawValue + gap : 0
        let latest = index + 1 < cues.count
            ? cues[index + 1].start.rawValue - gap
            : max(end.rawValue, start.rawValue + floor)
        guard latest - earliest >= floor else { return self }

        var newStart = min(max(start.rawValue, earliest), latest - floor)
        var newEnd = max(min(end.rawValue, latest), newStart + floor)
        // A start dragged past the end, or an end dragged before the start, becomes the floor
        // rather than a negative span.
        if newEnd - newStart < floor { newEnd = newStart + floor }
        if newEnd > latest { newEnd = latest; newStart = min(newStart, newEnd - floor) }

        var updated = cues
        updated[index].start = Nanoseconds(newStart)
        updated[index].end = Nanoseconds(newEnd)
        // The words go with the cue only where they still fall inside it. A word run left
        // outside its own cue would highlight nothing and time the karaoke pass against a span
        // the caption no longer covers.
        updated[index].words = updated[index].words.filter {
            $0.start.rawValue < newEnd && $0.end.rawValue > newStart
        }
        return CaptionTrack(cues: updated)
    }

    /// One cue split in two at a character offset into its text.
    ///
    /// **The join is timed from the WORD RUNS when there are any**, not by sharing the span out
    /// by character count. A recogniser gives a real time for the word the split lands on, and
    /// using it means the second half starts when its first word is actually said — which is the
    /// whole reason the runs are carried. Character-proportional is the fallback, and it is
    /// approximate in exactly the way `CaptionBuilder.distributed` is.
    ///
    /// Returns the track unchanged when the split would leave either half empty: a person who
    /// put the caret at the very start meant nothing by it, and a zero-character cue is not an
    /// edit anybody asked for.
    public func splitting(at index: Int, atCharacter offset: Int) -> CaptionTrack {
        guard cues.indices.contains(index) else { return self }
        let cue = cues[index]
        let characters = Array(cue.text)
        guard offset > 0, offset < characters.count else { return self }

        let head = String(characters[..<offset]).trimmingCharacters(in: .whitespaces)
        let tail = String(characters[offset...]).trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty, !tail.isEmpty else { return self }

        let joinAt = joinInstant(of: cue, head: head, offset: offset, characters: characters)
        let floor = CaptionMeasurement.shortestDisplay.rawValue
        // Both halves must be legal. A cue too short to split into two legal ones is left alone
        // rather than split into one legal cue and one that immediately reports `tooBrief`.
        guard joinAt - cue.start.rawValue >= floor,
              cue.end.rawValue - joinAt >= floor else { return self }

        let first = CaptionCue(text: head, start: cue.start, end: Nanoseconds(joinAt),
                               words: cue.words.filter { $0.end.rawValue <= joinAt })
        let second = CaptionCue(text: tail, start: Nanoseconds(joinAt), end: cue.end,
                                words: cue.words.filter { $0.end.rawValue > joinAt })
        var updated = cues
        updated.replaceSubrange(index...index, with: [first, second])
        return CaptionTrack(cues: updated)
    }

    /// Where the two halves meet: the start of the first word the tail contains, or a share of
    /// the span by character count when the cue carries no runs.
    private func joinInstant(of cue: CaptionCue, head: String,
                             offset: Int, characters: [Character]) -> Int64 {
        let readInHead = CaptionMeasurement.readableCharacters(in: head)
        if !cue.words.isEmpty {
            var seen = 0
            for word in cue.words {
                seen += CaptionMeasurement.readableCharacters(in: word.text)
                if seen > readInHead { return word.start.rawValue }
            }
        }
        let total = max(CaptionMeasurement.readableCharacters(in: String(characters)), 1)
        let span = max(cue.end.rawValue - cue.start.rawValue, 0)
        return cue.start.rawValue + span * Int64(readInHead) / Int64(total)
    }

    /// Two consecutive cues as one, spanning from the first's start to the second's end.
    ///
    /// The texts are joined with a single space for a spaced script and with nothing for a dense
    /// one, because inserting a space into Chinese is a visible edit to somebody's line.
    public func merging(at index: Int) -> CaptionTrack {
        guard cues.indices.contains(index), cues.indices.contains(index + 1) else { return self }
        let first = cues[index], second = cues[index + 1]
        let separator = CaptionScript.of(first.text) == .dense
            && CaptionScript.of(second.text) == .dense ? "" : " "
        let merged = CaptionCue(text: first.text + separator + second.text,
                                start: first.start, end: second.end,
                                words: first.words + second.words)
        var updated = cues
        updated.replaceSubrange(index...(index + 1), with: [merged])
        return CaptionTrack(cues: updated)
    }
}
