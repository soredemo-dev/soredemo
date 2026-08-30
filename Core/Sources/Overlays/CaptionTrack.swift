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

    /// The cue a step from `time` lands on, or `nil` for an empty track.
    ///
    /// **The interesting case is a playhead in a GAP**, which is most of a recording: between
    /// two cues, "next" has to go forward to the one after the gap and "previous" back to the
    /// one before it. Anchoring on "the last cue that has started" gives both — from a gap,
    /// `+1` is the cue ahead and `-1` is the one just left — and it is why this is here rather
    /// than in the panel, where it could not be tested.
    ///
    /// Clamped at both ends: stepping past the last cue stays on it. A wrap would move the
    /// playhead to the other end of the recording, which is never what a repeated key press
    /// means.
    public func index(steppingFrom time: Nanoseconds, by delta: Int) -> Int? {
        guard !cues.isEmpty else { return nil }
        let anchor = cues.lastIndex { $0.start.rawValue <= time.rawValue } ?? -1
        // Before the first cue, "next" is the first one rather than the second.
        let stepped = anchor < 0 ? (delta > 0 ? 0 : 0) : anchor + delta
        return Swift.min(Swift.max(stepped, 0), cues.count - 1)
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

    /// A cue's two boundaries moved to where the speech around it actually starts and stops.
    ///
    /// **Both ends at once, because that is the thing a person wants.** "Make this line line up
    /// with what was said" is one intention; two controls for it would be two presses for one
    /// decision, and a start that snapped while the end did not would leave the cue describing
    /// half of something.
    ///
    /// An end with nothing in reach keeps its own value rather than the cue being refused — a
    /// boundary that could be improved is improved, and one that could not is left where a
    /// person put it. `retiming` then clamps the pair, so a snap can never cross a neighbour or
    /// go under the floor.
    public func snapping(at index: Int, to pauses: [SilenceFinder.Span],
                         within reach: Nanoseconds = SilenceFinder.snapReach) -> CaptionTrack {
        guard cues.indices.contains(index) else { return self }
        let cue = cues[index]
        let start = SilenceFinder.speechResumes(nearest: cue.start, in: pauses, within: reach)
            ?? cue.start
        let end = SilenceFinder.speechStops(nearest: cue.end, in: pauses, within: reach)
            ?? cue.end
        guard start != cue.start || end != cue.end else { return self }
        return retiming(at: index, start: start, end: end)
    }

    /// True when either boundary has somewhere better to be, so a control can say whether
    /// pressing it will do anything rather than doing nothing quietly.
    public func canSnap(at index: Int, to pauses: [SilenceFinder.Span],
                        within reach: Nanoseconds = SilenceFinder.snapReach) -> Bool {
        guard cues.indices.contains(index) else { return false }
        let cue = cues[index]
        let start = SilenceFinder.speechResumes(nearest: cue.start, in: pauses, within: reach)
        let end = SilenceFinder.speechStops(nearest: cue.end, in: pauses, within: reach)
        return (start.map { $0 != cue.start } ?? false) || (end.map { $0 != cue.end } ?? false)
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

// MARK: - one correction, applied everywhere it belongs

/// What changed between two versions of a line, when it was one contiguous run.
///
/// **Common prefix and common suffix, rather than splitting into words.** A word split needs
/// word gaps, and half the languages this app recognises have none — a Chinese product name
/// corrected in one caption is exactly the case worth catching, and it has no spaces around it.
/// The differing middle is the correction whatever the script.
public struct RunEdit: Sendable, Equatable {
    public let was: String
    public let now: String

    /// `nil` when nothing changed, when the whole line was rewritten rather than one run
    /// corrected, or when what changed is too short to replace safely.
    ///
    /// **A one-character run is refused.** Replacing every "的" or every "a" across a transcript
    /// on the strength of one edit is a change nobody could review, and the offer is only worth
    /// making where a person can predict what it will do.
    public static let shortestRun = 2

    public init?(from before: String, to after: String) {
        guard before != after else { return nil }
        let old = Array(before), new = Array(after)
        var head = 0
        while head < old.count, head < new.count, old[head] == new[head] { head += 1 }
        var tail = 0
        while tail < old.count - head, tail < new.count - head,
              old[old.count - 1 - tail] == new[new.count - 1 - tail] { tail += 1 }

        let was = String(old[head..<(old.count - tail)])
        let now = String(new[head..<(new.count - tail)])
        // Both sides non-empty: a pure insertion or deletion is not a term being corrected, and
        // replacing "" everywhere is not a thing anybody means.
        guard was.count >= Self.shortestRun, !now.isEmpty else { return nil }
        // The whole line replaced is a rewrite, not a correction to carry elsewhere.
        guard head > 0 || tail > 0 else { return nil }
        self.was = was
        self.now = now
    }
}

extension CaptionTrack {
    /// How many cues, other than `excluding`, contain `run`.
    ///
    /// **Counted before it is offered.** "Fix this everywhere" is safe to press only when a
    /// person can see how far "everywhere" reaches; an offer with no number is a button whose
    /// effect is discovered afterwards.
    public func cuesContaining(_ run: String, excluding index: Int? = nil) -> Int {
        guard !run.isEmpty else { return 0 }
        return cues.enumerated().count { offset, cue in
            offset != index && cue.text.contains(run)
        }
    }

    /// Every occurrence of `run` replaced, in every cue.
    ///
    /// A plain substring replacement, deliberately: the run came from a diff of two strings the
    /// person typed, so it is already exactly the text they changed, and matching it any more
    /// cleverly would find something they did not mean. **The word runs are left alone** — they
    /// carry the recogniser's own text and its times, and rewriting them would put a corrected
    /// spelling on a span the recogniser never said it about.
    public func replacing(_ run: String, with replacement: String) -> CaptionTrack {
        guard !run.isEmpty else { return self }
        return CaptionTrack(cues: cues.map { cue in
            CaptionCue(text: cue.text.replacingOccurrences(of: run, with: replacement),
                       start: cue.start, end: cue.end, words: cue.words)
        })
    }
}
