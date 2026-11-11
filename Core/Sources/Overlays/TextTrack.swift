import Foundation
import Render
import Timeline

/// A piece of text on the timeline: what it says, when it is on screen, and how it looks.
///
/// **Every item carries its own style.** A shared style would be right for a lower third that
/// appears four times and wrong the moment a title needs to be bigger than a note, and a person
/// putting a word on the screen is deciding about THAT word.
public struct TextItem: Sendable, Equatable, Codable, Identifiable {
    /// Stable across edits, so a selection or an inspector binding survives a retime — the same
    /// reason `EditClip` has an identity.
    ///
    /// **A counter, not a `UUID`, and `TextTrack` mints it.** `Captions` is a deterministic
    /// target and the architecture plugin forbids it from reaching ambient randomness; `UUID()`
    /// is exactly that. `ClipID`'s header makes the same argument, and adds the one that matters
    /// after the rule: the same sequence of edits produces the same ids, which is what makes a
    /// project file comparable to itself.
    public let id: Int
    public var text: String
    public var start: Nanoseconds
    public var end: Nanoseconds
    public var style: TextOverlayStyle
    /// How it arrives and leaves.
    public var animation: TextAnimation

    public init(id: Int, text: String, start: Nanoseconds, end: Nanoseconds,
                style: TextOverlayStyle = .default,
                animation: TextAnimation = .fade) {
        self.id = id
        self.text = text
        self.start = start
        self.end = end
        self.style = style
        self.animation = animation
    }

    /// **How far through its entrance or exit this item is at `time`.**
    ///
    /// Returns the state the renderer draws with: the lead-in runs forward and the lead-out runs
    /// the same curve backwards, so a title leaves the way it arrived rather than needing a
    /// second animation nobody chose.
    ///
    /// The lead is a fraction of the item's own duration, capped in seconds — a ten-second title
    /// must not spend two seconds arriving — and never more than half of it, or the entrance and
    /// the exit would overlap and the text would never be fully on.
    public func animationState(at time: Nanoseconds)
    -> (opacity: Double, rise: Double, scale: Double) {
        let span = Double(duration.rawValue) / 1_000_000_000
        guard span > 0 else { return (1, 0, 1) }
        let lead = min(span * TextAnimation.durationFraction,
                       TextAnimation.maximumSeconds, span / 2)
        guard lead > 0 else { return (1, 0, 1) }
        let position = Double(time.rawValue - start.rawValue) / 1_000_000_000
        if position < lead { return animation.state(at: position / lead) }
        if position > span - lead { return animation.state(at: (span - position) / lead) }
        return (1, 0, 1)
    }

    public var duration: Nanoseconds { Nanoseconds(max(0, end.rawValue - start.rawValue)) }

    public func contains(_ time: Nanoseconds) -> Bool {
        time.rawValue >= start.rawValue && time.rawValue < end.rawValue
    }
}

/// Every text overlay on one recording, in the recording's SOURCE time.
///
/// Source time for `CaptionTrack`'s reason: a cut moves everything after it, and a track stored
/// in output time would be rewritten on every trim.
///
/// **Overlapping items are allowed and are drawn together**, which is the difference from
/// `CaptionTrack`. Two captions on screen at once is a bug; a title and a lower third at once is
/// a layout.
public struct TextTrack: Sendable, Equatable, Codable {
    public var items: [TextItem]
    /// The next id to mint. Carried rather than derived from `items.count`, so deleting an item
    /// cannot cause the next one to reuse a dead id — which would attach an old selection to a
    /// new title.
    public private(set) var nextID: Int

    public init(items: [TextItem] = [], nextID: Int? = nil) {
        self.items = items.sorted { $0.start.rawValue < $1.start.rawValue }
        self.nextID = max(nextID ?? 0, (items.map(\.id).max() ?? -1) + 1)
    }

    /// Decoded absence-tolerantly: a track written before `nextID` existed recovers one from its
    /// items rather than failing to open.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let items = try container.decode([TextItem].self, forKey: .items)
        let stored = try container.decodeIfPresent(Int.self, forKey: .nextID)
        self.init(items: items, nextID: stored)
    }

    public var isEmpty: Bool { items.isEmpty }

    /// Everything on screen at `time`, in the order they were added — so a later item draws over
    /// an earlier one, which is what "bring to front" means without a z-order field.
    public func items(at time: Nanoseconds) -> [TextItem] {
        items.filter { $0.contains(time) }
    }

    /// A new item with a freshly minted id — the only way to make one, so nothing else has to
    /// know how ids are allocated.
    public func adding(text: String, start: Nanoseconds, end: Nanoseconds,
                       style: TextOverlayStyle = .default,
                       animation: TextAnimation = .fade) -> TextTrack {
        let item = TextItem(id: nextID, text: text, start: start, end: end, style: style,
                            animation: animation)
        return TextTrack(items: items + [item], nextID: nextID + 1)
    }

    public func removing(_ id: Int) -> TextTrack {
        TextTrack(items: items.filter { $0.id != id }, nextID: nextID)
    }

    /// One item replaced, matched on identity. A no-op for an id nobody has — rule 8: never trap
    /// on an input that came from outside.
    public func replacing(_ item: TextItem) -> TextTrack {
        guard items.contains(where: { $0.id == item.id }) else { return self }
        return TextTrack(items: items.map { $0.id == item.id ? item : $0 }, nextID: nextID)
    }

    /// The same overlays in the EDIT's time: items inside a cut disappear, items spanning one are
    /// split at it, and everything after moves back by what the cut removed.
    ///
    /// **A split keeps the id.** Both halves are the same title, and an inspector showing "this
    /// one" should show both halves selected rather than treating the second as a stranger.
    public func retimed(through timeline: EditTimeline) -> TextTrack {
        TextTrack(items: items.flatMap { item in
            timeline.clips.compactMap { clip -> TextItem? in
                let start = max(item.start.rawValue, clip.sourceStart.rawValue)
                let end = min(item.end.rawValue, clip.sourceEnd.rawValue)
                guard end > start,
                      let outputStart = timeline.outputTime(atSource: SourceTime(nanos: start))?.nanoseconds
                else { return nil }
                return TextItem(id: item.id, text: item.text, start: outputStart,
                                end: Nanoseconds(outputStart.rawValue + clip.playLength(ofSource: Nanoseconds(end - start)).rawValue),
                                style: item.style, animation: item.animation)
            }
        }, nextID: nextID)
    }

    private enum CodingKeys: String, CodingKey { case items, nextID }
}
