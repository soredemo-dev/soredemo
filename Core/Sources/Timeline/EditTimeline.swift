import Foundation

/// One span of the recording that survives editing, in the order it plays.
///
/// `sourceStart` is a position in the RECORDING, `duration` is how much of it plays. Where the
/// clip sits in the OUTPUT is not stored: it is the sum of the durations before it, so a cut
/// cannot leave a clip claiming an output position that disagrees with its neighbours.
public struct EditClip: Hashable, Sendable, Codable {
    public let sourceStart: Nanoseconds
    public let duration: Nanoseconds

    public init(sourceStart: Nanoseconds, duration: Nanoseconds) {
        precondition(sourceStart.rawValue >= 0, "a clip cannot start before the recording")
        precondition(duration.rawValue > 0, "a clip with no duration is not a clip")
        self.sourceStart = sourceStart
        self.duration = duration
    }

    /// **Validated on decode, not by the `precondition` above** (D6 rule 8). The synthesised
    /// `Decodable` assigns stored properties directly and never calls the initialiser, so the
    /// invariant would hold everywhere except the path carrying a project file — and a
    /// `precondition` there turns a corrupt file into a crash rather than an error.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sourceStart = try container.decode(Nanoseconds.self, forKey: .sourceStart)
        let duration = try container.decode(Nanoseconds.self, forKey: .duration)
        guard sourceStart.rawValue >= 0, duration.rawValue > 0 else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "clip at \(sourceStart.rawValue) has duration \(duration.rawValue)"))
        }
        self.sourceStart = sourceStart
        self.duration = duration
    }

    private enum CodingKeys: String, CodingKey { case sourceStart, duration }

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

    public init(clips: [EditClip]) {
        self.clips = clips
    }

    /// The whole recording, unedited.
    public static func whole(duration: Nanoseconds) -> EditTimeline {
        guard duration.rawValue > 0 else { return EditTimeline(clips: []) }
        return EditTimeline(clips: [EditClip(sourceStart: Nanoseconds(0), duration: duration)])
    }

    public var isEmpty: Bool { clips.isEmpty }

    /// How long the edited video runs — the sum of what survived, not the recording's length.
    public var outputDuration: Nanoseconds {
        Nanoseconds(clips.reduce(0) { $0 + $1.duration.rawValue })
    }

    /// Where each clip begins in the OUTPUT, in the same order as `clips`.
    public var outputStarts: [Nanoseconds] {
        var starts: [Nanoseconds] = []
        var running: Int64 = 0
        for clip in clips {
            starts.append(Nanoseconds(running))
            running += clip.duration.rawValue
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
            let next = running + clip.duration.rawValue
            if outputTime.rawValue < next {
                return Nanoseconds(clip.sourceStart.rawValue + (outputTime.rawValue - running))
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
                return Nanoseconds(running + (sourceTime.rawValue - clip.sourceStart.rawValue))
            }
            running += clip.duration.rawValue
        }
        return nil
    }

    // MARK: - Edits

    /// Everything outside `range` removed — a trim.
    ///
    /// Expressed against SOURCE time, because that is the space a person points at on a
    /// timeline drawn from the recording. Clips are intersected rather than dropped, so a trim
    /// landing inside a clip splits nothing: it shortens.
    public func trimmed(toSource range: Range<Int64>) -> EditTimeline {
        EditTimeline(clips: clips.compactMap { clip in
            let start = max(clip.sourceStart.rawValue, range.lowerBound)
            let end = min(clip.sourceEnd.rawValue, range.upperBound)
            guard end > start else { return nil }
            return EditClip(sourceStart: Nanoseconds(start), duration: Nanoseconds(end - start))
        })
    }

    /// `range` removed — a cut. A cut through the middle of a clip leaves two.
    ///
    /// **Adjacent survivors are NOT merged.** Two clips that happen to abut in the source are
    /// still two clips, and joining them would erase the record of a cut having been made
    /// there — which a reviewer looking at the timeline needs, and which `removing` cannot know
    /// is unwanted. `merged()` is available for a caller that does want it.
    public func removing(sourceRange range: Range<Int64>) -> EditTimeline {
        guard range.upperBound > range.lowerBound else { return self }
        var kept: [EditClip] = []
        for clip in clips {
            let start = clip.sourceStart.rawValue
            let end = clip.sourceEnd.rawValue
            // The part before the cut.
            let headEnd = min(end, range.lowerBound)
            if headEnd > start {
                kept.append(EditClip(sourceStart: Nanoseconds(start),
                                     duration: Nanoseconds(headEnd - start)))
            }
            // The part after it.
            let tailStart = max(start, range.upperBound)
            if end > tailStart {
                kept.append(EditClip(sourceStart: Nanoseconds(tailStart),
                                     duration: Nanoseconds(end - tailStart)))
            }
        }
        return EditTimeline(clips: kept)
    }

    /// Clips that abut in the source joined into one. Only for a caller that wants the record
    /// of the cut gone — an exporter, say, for which two abutting ranges are one read.
    public func merged() -> EditTimeline {
        var merged: [EditClip] = []
        for clip in clips {
            if let last = merged.last, last.sourceEnd.rawValue == clip.sourceStart.rawValue {
                merged[merged.count - 1] = EditClip(
                    sourceStart: last.sourceStart,
                    duration: Nanoseconds(last.duration.rawValue + clip.duration.rawValue))
            } else {
                merged.append(clip)
            }
        }
        return EditTimeline(clips: merged)
    }
}
