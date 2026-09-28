import Foundation
import Project
import Timeline

/// Where a chapter came from. **Shown beside it**, so a person can see what a suggestion was
/// built on — and a title edited by hand stops claiming a sentence as its source.
public enum ChapterOrigin: Sendable, Equatable, Codable {
    /// Typed, or edited, by a person.
    case authored
    /// Offered by the on-device model and added by a person: which transcript sentence it
    /// starts at, and what that sentence said.
    case suggested(sentence: Int, text: String)
    /// Placed by a person with the recorder's mark while the take ran. The moment is theirs; the
    /// title is a numbered placeholder until they write one, which makes it `.authored`.
    case marked
}

/// A title and the moment it begins, in the RECORDING's time — the clock `TextTrack` and the
/// captions use — so cutting and reordering move it without anyone re-placing it.
public struct Chapter: Sendable, Equatable, Codable, Identifiable {
    /// Minted by `ChapterTrack`, for `TextItem.id`'s reason: a deterministic target may not
    /// reach randomness, and the same edits should produce the same file.
    public let id: Int
    public var title: String
    public var start: Nanoseconds
    public var origin: ChapterOrigin

    public init(id: Int, title: String, start: Nanoseconds, origin: ChapterOrigin = .authored) {
        self.id = id
        self.title = title
        self.start = start
        self.origin = origin
    }
}

/// A chapter where it plays in the edited output, and for how long.
///
/// **`name`, not `title`, because this is what the render tier reads.** There `title` is the
/// accessibility title an observation log carries, which Gate 2 (`FixtureRedactionTests`)
/// forbids the render path to read — by name, since a line of source has no types. A chapter's
/// name is a person's own text, not evidence; spelling it differently keeps both readable.
public struct PlacedChapter: Sendable, Equatable {
    public let id: Int
    public let name: String
    public let start: Nanoseconds
    public let duration: Nanoseconds

    public init(id: Int, name: String, start: Nanoseconds, duration: Nanoseconds) {
        self.id = id
        self.name = name
        self.start = start
        self.duration = duration
    }
}

/// What the edit did to each chapter. **Every chapter has one**, so a chapter that silently
/// vanished from an export is not a possible state — the list says which, and why.
public enum ChapterFate: Sendable, Equatable {
    /// Its own moment plays, and it starts there.
    case placed
    /// Its first moment was cut; it starts where its content resumes.
    case movedPastACut
    /// Nothing at or after its moment survives the edit.
    case droppedNothingAfter
    /// Another chapter landed on the same moment and kept it.
    case collided(with: Int)
}

public struct ChapterPlacement: Sendable, Equatable {
    /// In playing order.
    public let placed: [PlacedChapter]
    public let fates: [Int: ChapterFate]
}

/// The recording's chapters, in the order they happen.
///
/// **Authored in full**: a suggestion becomes a chapter only when a person adds it, and asking
/// for suggestions again never touches what is here. See `docs/design/2026-09-27-chapters.md`.
public struct ChapterTrack: Sendable, Equatable, Codable {
    public private(set) var chapters: [Chapter]
    public private(set) var nextID: Int

    public init(chapters: [Chapter] = [], nextID: Int? = nil) {
        self.chapters = chapters.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        // Never below an id already in use, whatever a file claims: a collision would make two
        // chapters answer to one edit.
        let floor = (chapters.map(\.id).max() ?? -1) + 1
        self.nextID = max(nextID ?? floor, floor)
    }

    /// **Throws on a chapter before the recording starts**, rather than clamping it to zero:
    /// clamping would move a person's chapter to a moment they did not choose, silently.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let chapters = try container.decode([Chapter].self, forKey: .chapters)
        if let early = chapters.first(where: { $0.start.rawValue < 0 }) {
            throw DecodingError.dataCorruptedError(
                forKey: .chapters, in: container,
                debugDescription: "chapter \(early.id) starts at \(early.start.rawValue) ns, before the recording")
        }
        self.init(chapters: chapters, nextID: try container.decodeIfPresent(Int.self, forKey: .nextID))
    }

    public var isEmpty: Bool { chapters.isEmpty }

    public func adding(title: String, start: Nanoseconds, origin: ChapterOrigin = .authored) -> ChapterTrack {
        ChapterTrack(chapters: chapters + [Chapter(id: nextID, title: title, start: start, origin: origin)],
                     nextID: nextID + 1)
    }

    /// **The chapters a take's marks become**, numbered in the order they happen, and how many
    /// could not be placed.
    ///
    /// Placed through `table`, because a pause occupies no content: an offset from the first
    /// frame would put every mark after a pause late by the pause's length. A mark in no segment
    /// — in a pause, or in the instant before the first frame — is refused and counted, never
    /// moved to the nearest edge, which would be a chapter at a moment nobody chose.
    public static func fromMarks(_ marks: [HostInstant], in table: SegmentTable,
                                 title: (Int) -> String) -> (track: ChapterTrack, refused: Int) {
        let starts = marks.compactMap { table.contentTime(of: $0) }.sorted()
        var track = ChapterTrack()
        for (index, start) in starts.enumerated() {
            track = track.adding(title: title(index + 1), start: start, origin: .marked)
        }
        return (track, marks.count - starts.count)
    }

    public func removing(_ id: Int) -> ChapterTrack {
        ChapterTrack(chapters: chapters.filter { $0.id != id }, nextID: nextID)
    }

    /// **A changed title is the person's**, so the chapter stops citing the sentence a suggestion
    /// took it from. The same title is not a change, and keeps the origin.
    public func retitled(_ id: Int, to title: String) -> ChapterTrack {
        ChapterTrack(chapters: chapters.map { chapter in
            guard chapter.id == id, chapter.title != title else { return chapter }
            return Chapter(id: id, title: title, start: chapter.start, origin: .authored)
        }, nextID: nextID)
    }

    /// **The chapters as the edited output plays them** — see `ChapterFate` for what can happen
    /// to each. `outputDuration` is where the last one ends; `nil` for `timeline` means unedited.
    public func outputChapters(through timeline: EditTimeline?,
                               outputDuration: Nanoseconds) -> ChapterPlacement {
        var fates: [Int: ChapterFate] = [:]
        var landed: [(chapter: Chapter, at: Int64, moved: Bool)] = []
        for chapter in chapters {
            guard let (at, moved) = Self.outputStart(of: chapter.start, through: timeline),
                  at < outputDuration.rawValue else {
                fates[chapter.id] = .droppedNothingAfter
                continue
            }
            landed.append((chapter, at, moved))
        }
        // Two on one moment: the one whose own moment plays keeps it, then the later in the
        // recording — it is the nearer to what actually plays there.
        var winners: [(chapter: Chapter, at: Int64)] = []
        for group in Dictionary(grouping: landed, by: \.at).values {
            let ranked = group.sorted {
                ($0.moved ? 0 : 1, $0.chapter.start.rawValue, $0.chapter.id)
                    > ($1.moved ? 0 : 1, $1.chapter.start.rawValue, $1.chapter.id)
            }
            let winner = ranked[0]
            fates[winner.chapter.id] = winner.moved ? .movedPastACut : .placed
            for loser in ranked.dropFirst() { fates[loser.chapter.id] = .collided(with: winner.chapter.id) }
            winners.append((winner.chapter, winner.at))
        }
        winners.sort { $0.at < $1.at }
        let placed = winners.enumerated().map { index, entry in
            let end = index + 1 < winners.count ? winners[index + 1].at : outputDuration.rawValue
            return PlacedChapter(id: entry.chapter.id, name: entry.chapter.title,
                                 start: Nanoseconds(entry.at), duration: Nanoseconds(end - entry.at))
        }
        return ChapterPlacement(placed: placed, fates: fates)
    }

    /// Where a source moment plays, or — when it was cut — where the nearest content after it
    /// in the RECORDING plays. Nearest in the recording, not in the output: with reordered
    /// clips the earliest-playing later clip may be minutes of content away.
    static func outputStart(of source: Nanoseconds,
                            through timeline: EditTimeline?) -> (Int64, moved: Bool)? {
        guard let timeline else { return (source.rawValue, false) }
        if let output = timeline.outputTime(atSource: source) { return (output.rawValue, false) }
        let next = timeline.clips.filter { $0.sourceStart.rawValue > source.rawValue }
            .min { $0.sourceStart.rawValue < $1.sourceStart.rawValue }
        return next.flatMap { timeline.outputTime(atSource: $0.sourceStart) }.map { ($0.rawValue, true) }
    }

    private enum CodingKeys: String, CodingKey { case chapters, nextID }
}

/// Chapters as a plain list — `0:00 Title` a line — for a video's description.
public enum ChapterList {
    /// Why a video host that turns such a list into chapters would not. **Reported, never
    /// fixed**: moving a person's first chapter to 0:00 is a decision about their video.
    public enum Problem: Sendable, Equatable {
        case firstIsNotAtTheStart
        case fewerThanThree(Int)
        case tooShort(id: Int)
    }

    /// The shortest chapter the common hosts accept, in seconds.
    public static let shortestSeconds: Int64 = 10

    public static func text(_ placed: [PlacedChapter], outputDuration: Nanoseconds) -> String {
        let hours = outputDuration.rawValue >= 3_600_000_000_000
        return placed.map { "\(timestamp($0.start, withHours: hours)) \($0.name)" }
            .joined(separator: "\n")
    }

    public static func problems(_ placed: [PlacedChapter]) -> [Problem] {
        var found: [Problem] = []
        if let first = placed.first, first.start.rawValue != 0 { found.append(.firstIsNotAtTheStart) }
        if placed.count < 3 { found.append(.fewerThanThree(placed.count)) }
        found += placed.filter { $0.duration.rawValue < shortestSeconds * 1_000_000_000 }
            .map { .tooShort(id: $0.id) }
        return found
    }

    /// Truncated, not rounded: a chapter at 74.6 s has not begun at 1:15.
    public static func timestamp(_ time: Nanoseconds, withHours: Bool) -> String {
        let total = max(0, time.rawValue) / 1_000_000_000
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        let two = { (value: Int64) in value < 10 ? "0\(value)" : "\(value)" }
        return withHours ? "\(h):\(two(m)):\(two(s))" : "\(total / 60):\(two(s))"
    }
}
