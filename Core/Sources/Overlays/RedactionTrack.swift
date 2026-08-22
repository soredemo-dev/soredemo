import Foundation
import Render
import Timeline

/// One redaction and the span it covers, in the recording's SOURCE time.
public struct RedactionItem: Sendable, Equatable, Codable, Identifiable {
    public var id: Int { region.id }
    public var region: RedactionRegion
    public var start: Nanoseconds
    public var end: Nanoseconds
    /// True covers the whole recording — which is the right default, because the thing being
    /// hidden is usually a window that is on screen throughout.
    public var coversEverything: Bool

    public init(region: RedactionRegion, start: Nanoseconds, end: Nanoseconds,
                coversEverything: Bool = true) {
        self.region = region
        self.start = start
        self.end = end
        self.coversEverything = coversEverything
    }

    public func contains(_ time: Nanoseconds) -> Bool {
        coversEverything
            || (time.rawValue >= start.rawValue && time.rawValue < end.rawValue)
    }
}

/// Every redaction on one recording.
///
/// **No `retimed(through:)`, unlike the other two tracks.** A redaction that covers everything
/// covers everything after a cut too, and one with a span is looked up through
/// `sourceOffset(forOutput:)` at draw time like the rest. A retimed COPY would be a second
/// answer to "is this hidden", and the failure mode of the two disagreeing is a frame that shows
/// what a person hid — which is the one failure this feature must not have.
public struct RedactionTrack: Sendable, Equatable, Codable {
    public var items: [RedactionItem]
    public private(set) var nextID: Int

    public init(items: [RedactionItem] = [], nextID: Int? = nil) {
        self.items = items
        self.nextID = max(nextID ?? 0, (items.map(\.id).max() ?? -1) + 1)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(items: try container.decode([RedactionItem].self, forKey: .items),
                  nextID: try container.decodeIfPresent(Int.self, forKey: .nextID))
    }

    private enum CodingKeys: String, CodingKey { case items, nextID }

    public var isEmpty: Bool { items.isEmpty }

    /// The regions covering `time`, with empty ones dropped — a zero-area region is what a click
    /// that never became a drag leaves behind, and drawing one is a no-op that still costs a
    /// filter pass.
    public func regions(at time: Nanoseconds) -> [RedactionRegion] {
        items.filter { $0.contains(time) && !$0.region.isEmpty }.map(\.region)
    }

    public func adding(x: Double, y: Double, width: Double, height: Double,
                       style: RedactionStyle = .defaultMosaic,
                       start: Nanoseconds = Nanoseconds(0),
                       end: Nanoseconds = Nanoseconds(0)) -> RedactionTrack {
        let region = RedactionRegion(id: nextID, x: x, y: y, width: width, height: height,
                                     style: style)
        return RedactionTrack(
            items: items + [RedactionItem(region: region, start: start, end: end)],
            nextID: nextID + 1)
    }

    public func removing(_ id: Int) -> RedactionTrack {
        RedactionTrack(items: items.filter { $0.id != id }, nextID: nextID)
    }

    /// A no-op for an id nobody has — rule 8: never trap on an input from outside.
    public func replacing(_ item: RedactionItem) -> RedactionTrack {
        guard items.contains(where: { $0.id == item.id }) else { return self }
        return RedactionTrack(items: items.map { $0.id == item.id ? item : $0 }, nextID: nextID)
    }
}
