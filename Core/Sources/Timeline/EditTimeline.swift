import Foundation

/// One span of the recording that survives editing, in the order it plays.
///
/// `sourceStart` is a position in the RECORDING, `duration` is how much of it plays. Where the
/// clip sits in the OUTPUT is not stored: it is the sum of the durations before it, so a cut
/// cannot leave a clip claiming an output position that disagrees with its neighbours.
/// A clip's identity, stable across every edit that does not destroy the clip.
///
/// **Why identity and not the array index.** A person selects a clip, then deletes an earlier
/// one; by index the selection silently becomes a different clip. Every editor in
/// `../opensource/Screen Record Opensource/` keys selection on an identity for this reason —
/// a native editor's `clip.id`, an Electron recorder's clip ids, a Rust recorder's.
///
/// **A counter, not a UUID.** `Timeline` is a deterministic target: the architecture plugin
/// forbids it from reaching ambient randomness, and `Minting` — the one place allowed to —
/// is a tier away. The timeline mints from a monotonic counter it carries, so the same
/// sequence of edits on the same recording produces the same ids, which is also what makes a
/// project file comparable to itself.
public struct ClipID: Hashable, Sendable, Codable, Comparable {
    public let rawValue: Int

    public init(rawValue: Int) {
        precondition(rawValue >= 0, "a clip id is a counter and never negative")
        self.rawValue = rawValue
    }

    /// Validated on decode for the same reason `EditClip` is (D6 rule 8): the synthesised
    /// decoder never calls the initialiser above.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int.self)
        guard raw >= 0 else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath, debugDescription: "negative clip id \(raw)"))
        }
        self.rawValue = raw
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: ClipID, rhs: ClipID) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct EditClip: Hashable, Sendable, Codable, Identifiable {
    public let id: ClipID
    public let sourceStart: Nanoseconds
    /// How much of the RECORDING this clip covers. Not how long it plays — see `speed`.
    public let duration: Nanoseconds
    /// How fast it plays. 1 is the recording's own pace; 2 plays it in half the time.
    ///
    /// **Source duration and output duration stop being the same number here**, which is the
    /// whole cost of this feature and the reason it is a field on the clip rather than a
    /// setting on the timeline: every conversion between the two spaces has to divide, and a
    /// timeline-wide speed would still need the same division while pretending it did not.
    ///
    /// Bounded at a quarter and four. Below a quarter a demo is a slideshow of held frames —
    /// the recording has no more frames to give — and above four the pointer moves faster than
    /// a viewer can follow, which is the opposite of what a walkthrough is for.
    public let speed: Double

    public init(id: ClipID, sourceStart: Nanoseconds, duration: Nanoseconds,
                speed: Double = 1) {
        precondition(sourceStart.rawValue >= 0, "a clip cannot start before the recording")
        precondition(duration.rawValue > 0, "a clip with no duration is not a clip")
        self.id = id
        self.sourceStart = sourceStart
        self.duration = duration
        // Clamped rather than trapped: a speed reaches here from a slider and from a decoder,
        // and rule 8 forbids trapping on an untrusted input.
        self.speed = Swift.min(Swift.max(speed.isFinite ? speed : 1, 0.25), 4)
    }

    /// How long this clip PLAYS. Every output-space position is a sum of these.
    public var outputDuration: Nanoseconds {
        Nanoseconds(Int64((Double(duration.rawValue) / speed).rounded()))
    }

    /// The same clip at a different speed. Keeps the id, for `spanning`'s reason.
    public func playing(at speed: Double) -> EditClip {
        EditClip(id: id, sourceStart: sourceStart, duration: duration, speed: speed)
    }

    /// The same clip covering a different span of the recording. **Keeps the id**, which is
    /// what makes a trim an edit to a clip rather than a replacement of it: a selection
    /// survives, and so does anything else keyed on the clip.
    public func spanning(sourceStart: Nanoseconds, duration: Nanoseconds) -> EditClip {
        EditClip(id: id, sourceStart: sourceStart, duration: duration, speed: speed)
    }

    /// **Validated on decode, not by the `precondition` above** (D6 rule 8). The synthesised
    /// `Decodable` assigns stored properties directly and never calls the initialiser, so the
    /// invariant would hold everywhere except the path carrying a project file — and a
    /// `precondition` there turns a corrupt file into a crash rather than an error.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(ClipID.self, forKey: .id)
        let sourceStart = try container.decode(Nanoseconds.self, forKey: .sourceStart)
        let duration = try container.decode(Nanoseconds.self, forKey: .duration)
        guard sourceStart.rawValue >= 0, duration.rawValue > 0 else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "clip at \(sourceStart.rawValue) has duration \(duration.rawValue)"))
        }
        self.id = id
        self.sourceStart = sourceStart
        self.duration = duration
        // **Absence-tolerant.** A project written before speeds existed has no key, and its
        // clips play at the recording's own pace — which is what they did when it was saved.
        self.speed = Swift.min(
            Swift.max(try container.decodeIfPresent(Double.self, forKey: .speed) ?? 1, 0.25), 4)
    }

    private enum CodingKeys: String, CodingKey { case id, sourceStart, duration, speed }

    /// One past the last nanosecond this clip reads from the recording.
    public var sourceEnd: Nanoseconds { Nanoseconds(sourceStart.rawValue + duration.rawValue) }
}

/// **What survives editing, and where each surviving nanosecond came from** — `timeline-core`'s
/// "integer-nanosecond output↔source mapping".
///
/// Two clocks, and confusing them is this project's recurring fault (`1a98402`): SOURCE time is
/// a position in the recording, which every observation record is stamped against; OUTPUT time
/// is a position in the edited video, which is what a player and an exporter count in. With no
/// edits the two are equal, which is exactly why a bug here stays invisible until the first cut.
///
/// **Integer nanoseconds throughout, never seconds.** A cut is a subtraction repeated once per
/// surviving clip, and in `Double` seconds those subtractions accumulate error until a clip
/// boundary lands a frame away from where the model says it does.
///
/// The third timestamp the row names — CAMERA time — is deliberately not here. It belongs to
/// `CameraMotion`, which integrates against source time, and folding it in would make one type
/// own two independent rules.
public struct EditTimeline: Hashable, Sendable, Codable {
    /// In output order. Never empty in a timeline that has any recording at all; an empty one
    /// is the legal representation of "everything was cut".
    public let clips: [EditClip]

    /// The next id to mint. Carried by the timeline rather than a global counter so the same
    /// sequence of edits on the same recording produces the same ids — a project file that is
    /// comparable to itself, and an undo that restores the clip a selection pointed at rather
    /// than a new one wearing its number.
    ///
    /// Never reused. An id that came back after a delete would make a stale selection or a
    /// stale override silently attach to a different clip, which is the same class of fault
    /// as an array index and the reason ids exist.
    public let nextID: ClipID

    public init(clips: [EditClip], nextID: ClipID? = nil) {
        self.clips = clips
        // Derived when not given, so a caller constructing a timeline by hand — every test,
        // and any decode of an older file — cannot mint a duplicate.
        let highest = clips.map(\.id.rawValue).max().map { $0 + 1 } ?? 0
        self.nextID = nextID.map { ClipID(rawValue: max($0.rawValue, highest)) }
            ?? ClipID(rawValue: highest)
    }

    /// The whole recording, unedited.
    public static func whole(duration: Nanoseconds) -> EditTimeline {
        guard duration.rawValue > 0 else { return EditTimeline(clips: []) }
        return EditTimeline(clips: [EditClip(id: ClipID(rawValue: 0),
                                             sourceStart: Nanoseconds(0), duration: duration)])
    }

    // MARK: - clips as objects

    /// The clip playing at `outputTime`, or `nil` past the end — what a click on the timeline
    /// resolves to.
    public func clip(atOutput outputTime: Nanoseconds) -> EditClip? {
        guard outputTime.rawValue >= 0 else { return nil }
        var running: Int64 = 0
        for clip in clips {
            let next = running + clip.outputDuration.rawValue
            if outputTime.rawValue < next { return clip }
            running = next
        }
        return nil
    }

    /// The clip covering a SOURCE position — what a click on a strip drawn from the recording
    /// resolves to, as `TimelineEditor` draws it.
    ///
    /// **Assumes clips do not overlap in the source**, which every edit here preserves: cutting
    /// and trimming only shrink spans, splitting divides one, and moving reorders without
    /// changing any span. A model that later allows the same footage twice would need this to
    /// return more than one, and the assumption is stated here so that change is visible.
    public func clip(atSource sourceTime: Nanoseconds) -> EditClip? {
        clips.first {
            sourceTime.rawValue >= $0.sourceStart.rawValue
                && sourceTime.rawValue < $0.sourceEnd.rawValue
        }
    }

    /// Where `id` begins in the OUTPUT, or `nil` if it is not in this timeline.
    public func outputStart(of id: ClipID) -> Nanoseconds? {
        var running: Int64 = 0
        for clip in clips {
            if clip.id == id { return Nanoseconds(running) }
            running += clip.outputDuration.rawValue
        }
        return nil
    }

    /// One clip removed, and the clips after it pulled earlier — a ripple delete.
    ///
    /// **The ripple is free, and that is a property of the model rather than a feature.**
    /// A clip's output position is the sum of the durations before it, never a stored value,
    /// so removing one cannot leave a gap and cannot leave two clips claiming the same
    /// moment. a native editor needs a `RippleEngine` because its clips carry `startFrame`.
    public func removing(id: ClipID) -> EditTimeline {
        EditTimeline(clips: clips.filter { $0.id != id }, nextID: nextID)
    }

    /// The clip at `outputTime` cut in two there. Both halves keep playing back to back, so
    /// the output is unchanged — a split is preparation for an edit, not an edit.
    ///
    /// **The left half keeps the id.** A split is not a replacement of the clip a person had
    /// selected; it is that clip becoming shorter with a new one after it.
    ///
    /// `nil` when the cut would land on a boundary and produce a zero-length piece: two cuts
    /// at the same instant is a no-op a caller should be able to detect, not a clip with no
    /// duration.
    public func split(atOutput outputTime: Nanoseconds) -> EditTimeline? {
        var running: Int64 = 0
        for (index, clip) in clips.enumerated() {
            let next = running + clip.outputDuration.rawValue
            if outputTime.rawValue > running && outputTime.rawValue < next {
                // **Converted back into SOURCE time before it becomes a duration.** The offset
                // is how far into the clip's PLAYBACK the cut fell; a clip at 2× covers twice
                // that much of the recording. Using the output offset directly would put the
                // cut at the wrong frame on every clip whose speed is not 1.
                let leftLength = Int64((Double(outputTime.rawValue - running)
                                        * clip.speed).rounded())
                let left = clip.spanning(sourceStart: clip.sourceStart,
                                         duration: Nanoseconds(leftLength))
                let right = EditClip(
                    id: nextID,
                    sourceStart: Nanoseconds(clip.sourceStart.rawValue + leftLength),
                    duration: Nanoseconds(clip.duration.rawValue - leftLength),
                    // **The right half keeps the speed too.** A split is preparation for an
                    // edit, not an edit: the output must be unchanged, and a right half at the
                    // default pace would make the video longer the moment it was cut. The left
                    // half inherits it through `spanning`; this one is constructed, so it has
                    // to be said.
                    speed: clip.speed)
                var updated = clips
                updated.replaceSubrange(index...index, with: [left, right])
                return EditTimeline(clips: updated,
                                    nextID: ClipID(rawValue: nextID.rawValue + 1))
            }
            running = next
        }
        return nil
    }

    /// The timeline restricted to one span of OUTPUT time — an in point and an out point.
    ///
    /// **This is how "export just this part" is expressed, and expressing it as an EDIT is the
    /// whole design.** The alternative is a range parameter threaded through the exporter, the
    /// compositor, the observation-log mapping and the caption track, each of which would then
    /// have two notions of "where are we" to keep in step. A restricted timeline has one:
    /// everything downstream already knows how to render a timeline, so a range costs nothing
    /// new anywhere.
    ///
    /// ScreenKite ships this and writes a whole article about Screen Studio not having it; their
    /// workaround there is to duplicate the project and trim the copy, once per section. The
    /// coordinate transforms this needs — `sourceTime(atOutput:)` and the speed-aware `split`
    /// below it — were already here for other reasons.
    ///
    /// **Output time, not source time.** A person setting an in point is pointing at the video
    /// they are watching, which is the edited one; a cut earlier in the timeline has already
    /// moved every later frame. Converting to source at the edges is this function's job, and
    /// `split` does it speed-aware — a clip at 2× covers twice as much recording per second of
    /// playback.
    ///
    /// Returns `nil` for a range that selects nothing: empty, or entirely outside the output. A
    /// named refusal rather than an empty timeline, because an empty timeline exports a
    /// zero-length file and looks like the export failing for some other reason.
    ///
    /// **Not "reversed", though the guard below would catch it.** `Range` traps at construction
    /// on `lowerBound > upperBound`, so an out point before the in point cannot reach this
    /// function at all — the type has already refused it, and a comment claiming this guard
    /// handles a case the type forbids would be describing work nothing does.
    public func restricted(toOutput range: Range<Int64>) -> EditTimeline? {
        guard range.lowerBound < range.upperBound else { return nil }
        let total = outputDuration.rawValue
        // Clamped into the output. **The upper clamp is belt to a brace the loop already
        // provides** — it cannot keep a clip that does not exist, so an out point past the end
        // works either way; a mutation removing this line left every test green. It stays
        // because `upper` is compared against `total` below and a reader should not have to
        // work out that the comparison is safe with an unclamped value.
        let lower = Swift.max(range.lowerBound, 0)
        let upper = Swift.min(range.upperBound, total)
        guard lower < upper else { return nil }

        // Split at both edges so the range falls on clip boundaries.
        //
        // **The order does not matter, and the comment that used to be here said it did.** It
        // argued that splitting at the out point first saved recomputing an offset. A mutation
        // that swapped the two left every test green, and the reason is that a split preserves
        // output duration exactly — it divides a clip without moving anything — so neither edge's
        // output offset is disturbed by the other's split. Recorded rather than deleted, because
        // the plausible-sounding version is the one somebody writes again.
        var working = self
        if upper < total, let split = working.split(atOutput: Nanoseconds(upper)) {
            working = split
        }
        if lower > 0, let split = working.split(atOutput: Nanoseconds(lower)) {
            working = split
        }

        // Everything that now begins at or after the in point and ends at or before the out
        // point. After the splits those boundaries fall exactly on clip edges, so this is a
        // whole number of clips and no clip is half in.
        var kept: [EditClip] = []
        var running: Int64 = 0
        for clip in working.clips {
            let next = running + clip.outputDuration.rawValue
            if running >= lower && next <= upper { kept.append(clip) }
            running = next
        }
        guard !kept.isEmpty else { return nil }
        return EditTimeline(clips: kept, nextID: working.nextID)
    }

    /// One clip's edges moved, in SOURCE time. Positive `startDelta` trims from the front,
    /// negative extends it; `endDelta` is the same at the other end.
    ///
    /// `nil` when the result would have no duration or would start before the recording — a
    /// trim past a clip's own length is a gesture that has gone too far, and the caller stops
    /// the handle rather than the model inventing a floor.
    public func trimming(id: ClipID, startDelta: Int64, endDelta: Int64) -> EditTimeline? {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return nil }
        let clip = clips[index]
        let start = clip.sourceStart.rawValue + startDelta
        let length = clip.duration.rawValue - startDelta + endDelta
        guard start >= 0, length > 0 else { return nil }
        var updated = clips
        updated[index] = clip.spanning(sourceStart: Nanoseconds(start),
                                       duration: Nanoseconds(length))
        return EditTimeline(clips: updated, nextID: nextID)
    }

    /// One clip moved to a new position in the output order.
    ///
    /// `destination` is an index into the timeline WITHOUT the moved clip, which is the only
    /// interpretation that makes "move it to the end" expressible — with the clip still in
    /// place, the last valid index is one short.
    public func moving(id: ClipID, to destination: Int) -> EditTimeline? {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return nil }
        var updated = clips
        let clip = updated.remove(at: index)
        guard destination >= 0, destination <= updated.count else { return nil }
        updated.insert(clip, at: destination)
        return EditTimeline(clips: updated, nextID: nextID)
    }

    public var isEmpty: Bool { clips.isEmpty }

    /// How long the edited video runs — the sum of what survived, not the recording's length.
    public var outputDuration: Nanoseconds {
        Nanoseconds(clips.reduce(0) { $0 + $1.outputDuration.rawValue })
    }

    /// Where each clip begins in the OUTPUT, in the same order as `clips`.
    public var outputStarts: [Nanoseconds] {
        var starts: [Nanoseconds] = []
        var running: Int64 = 0
        for clip in clips {
            starts.append(Nanoseconds(running))
            running += clip.outputDuration.rawValue
        }
        return starts
    }

    // MARK: - The mapping

    /// The position in the RECORDING that plays at `outputTime`.
    ///
    /// `nil` past the end of the edited video. Not clamped to the last frame: a caller asking
    /// about a time that does not exist has a bug, and returning the final frame would let it
    /// run undetected.
    public func sourceTime(atOutput outputTime: Nanoseconds) -> Nanoseconds? {
        guard outputTime.rawValue >= 0 else { return nil }
        var running: Int64 = 0
        for clip in clips {
            let next = running + clip.outputDuration.rawValue
            if outputTime.rawValue < next {
                // Scaled by the clip's speed: an output offset covers `speed` times as much of
                // the recording. This is the conversion the pointer, the camera, the captions
                // and the text overlays all reach the source through.
                let into = Int64((Double(outputTime.rawValue - running) * clip.speed).rounded())
                return Nanoseconds(clip.sourceStart.rawValue + into)
            }
            running = next
        }
        return nil
    }

    /// Where in the edited video `sourceTime` plays, or `nil` if it was cut.
    ///
    /// **`nil` means CUT, and it is a different answer from zero.** A caller drawing the
    /// pointer at output time 0 for every cut sample would pile the whole removed span onto the
    /// first frame — the shape of fault this project keeps finding, one domain over.
    public func outputTime(atSource sourceTime: Nanoseconds) -> Nanoseconds? {
        var running: Int64 = 0
        for clip in clips {
            if sourceTime.rawValue >= clip.sourceStart.rawValue,
               sourceTime.rawValue < clip.sourceEnd.rawValue {
                // The inverse of `sourceTime(atOutput:)`: a source offset takes `1/speed` as
                // long to play.
                let into = Int64((Double(sourceTime.rawValue - clip.sourceStart.rawValue)
                                  / clip.speed).rounded())
                return Nanoseconds(running + into)
            }
            running += clip.outputDuration.rawValue
        }
        return nil
    }

    /// How much of a span of the RECORDING is still in the edit.
    ///
    /// For a surface that addresses the recording by something other than the timeline — a
    /// transcript, say — and has to say whether the thing it is naming is still in the video.
    /// Three states rather than a `Bool`: a span can be half cut, by a trim that landed inside
    /// it or by a neighbouring deletion, and a row that called that "removed" would be offering
    /// to delete footage that is still there.
    public enum Survival: Hashable, Sendable {
        /// Every nanosecond of it plays.
        case whole
        /// Some of it plays and some was cut.
        case partly
        /// None of it plays.
        case gone
    }

    /// **Measured against the clips rather than sampled**, because sampling three points inside
    /// a span cannot tell `whole` from `partly` when the cut sits between two samples — and the
    /// clips already say exactly which nanoseconds survive.
    public func survival(ofSource range: Range<Int64>) -> Survival {
        guard range.upperBound > range.lowerBound else { return .gone }
        var kept: Int64 = 0
        for clip in clips {
            let low = max(clip.sourceStart.rawValue, range.lowerBound)
            let high = min(clip.sourceEnd.rawValue, range.upperBound)
            if high > low { kept += high - low }
        }
        if kept == 0 { return .gone }
        // Clamped, because two clips CAN cover the same source range — nothing in this type
        // forbids it and `moving(id:to:)` reorders freely — and an uncapped sum would report a
        // span that survives twice over as `partly`, which is the opposite of true.
        let length = range.upperBound - range.lowerBound
        return min(kept, length) == length ? .whole : .partly
    }

    // MARK: - Edits

    /// Everything outside `range` removed — a trim.
    ///
    /// Expressed against SOURCE time, because that is the space a person points at on a
    /// timeline drawn from the recording. Clips are intersected rather than dropped, so a trim
    /// landing inside a clip splits nothing: it shortens.
    ///
    /// **Survivors keep their ids.** A trim shortens the clips it touches; it does not replace
    /// them, so a selection made before the trim still points at the clip a person can see.
    public func trimmed(toSource range: Range<Int64>) -> EditTimeline {
        EditTimeline(clips: clips.compactMap { clip -> EditClip? in
            let start = max(clip.sourceStart.rawValue, range.lowerBound)
            let end = min(clip.sourceEnd.rawValue, range.upperBound)
            guard end > start else { return nil }
            return clip.spanning(sourceStart: Nanoseconds(start),
                                 duration: Nanoseconds(end - start))
        }, nextID: nextID)
    }

    /// `range` removed — a cut. A cut through the middle of a clip leaves two.
    ///
    /// **Adjacent survivors are NOT merged.** Two clips that happen to abut in the source are
    /// still two clips, and joining them would erase the record of a cut having been made
    /// there — which a reviewer looking at the timeline needs, and which `removing` cannot know
    /// is unwanted. `merged()` is available for a caller that does want it.
    ///
    /// **The head of a cut clip keeps the id; the tail is a new clip.** Same rule as `split`,
    /// and for the same reason: the piece a person was looking at is the one that starts where
    /// the clip started.
    public func removing(sourceRange range: Range<Int64>) -> EditTimeline {
        guard range.upperBound > range.lowerBound else { return self }
        var kept: [EditClip] = []
        var minting = nextID.rawValue
        for clip in clips {
            let start = clip.sourceStart.rawValue
            let end = clip.sourceEnd.rawValue
            // The part before the cut.
            let headEnd = min(end, range.lowerBound)
            let hasHead = headEnd > start
            if hasHead {
                kept.append(clip.spanning(sourceStart: Nanoseconds(start),
                                          duration: Nanoseconds(headEnd - start)))
            }
            // The part after it. It keeps the clip's own id only when there is no head to
            // have taken it — a cut off the FRONT shortens the clip rather than splitting it.
            let tailStart = max(start, range.upperBound)
            if end > tailStart {
                let id: ClipID
                if hasHead {
                    id = ClipID(rawValue: minting)
                    minting += 1
                } else {
                    id = clip.id
                }
                kept.append(EditClip(id: id, sourceStart: Nanoseconds(tailStart),
                                     duration: Nanoseconds(end - tailStart)))
            }
        }
        return EditTimeline(clips: kept, nextID: ClipID(rawValue: minting))
    }

    /// Clips that abut in the source joined into one. Only for a caller that wants the record
    /// of the cut gone — an exporter, say, for which two abutting ranges are one read.
    public func merged() -> EditTimeline {
        var merged: [EditClip] = []
        for clip in clips {
            // **Only when the speeds match.** Two adjacent spans of the recording played at
            // different rates are two clips however contiguous their source is; merging them
            // would silently give the whole run one of the two speeds. Before speeds existed
            // this condition was always true, which is why it was not written.
            if let last = merged.last, last.sourceEnd.rawValue == clip.sourceStart.rawValue,
               last.speed == clip.speed {
                // The survivor keeps the FIRST clip's id: the merged clip starts where it did.
                merged[merged.count - 1] = last.spanning(
                    sourceStart: last.sourceStart,
                    duration: Nanoseconds(last.duration.rawValue + clip.duration.rawValue))
            } else {
                merged.append(clip)
            }
        }
        return EditTimeline(clips: merged, nextID: nextID)
    }
}
