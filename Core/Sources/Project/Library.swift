import Foundation

/// What a project holds besides its recording — takes, clips, screenshots, logos, music — and what
/// is known of each (`docs/design/2026-11-13-the-library.md`). Kept in `library/library.json`
/// inside the package; **its decoder is the gate**, because a package is a shareable document.
public struct Library: Sendable, Equatable, Codable {
    public static let directory = "library"
    public static let listFilename = "library.json"
    public static let version = 1

    public enum Kind: String, Sendable, Equatable, Codable, CaseIterable { case recording, video, image, audio }

    /// Where an item came from — so a person and the agent can tell a take from a download.
    public enum Origin: Sendable, Equatable, Codable {
        case recorded
        case imported(originalName: String)
        case web(host: String)
    }

    public struct Item: Sendable, Equatable, Codable, Identifiable {
        public let id: Int
        public let kind: Kind
        public let filename: String
        public var name: String
        public let origin: Origin
        public let durationNanos: Int64?
        public let width: Int?
        public let height: Int?
        /// Text read off a picture when it came in — derived, so `textRevision` says by what.
        public var pictureText: String?
        public var textRevision: Int?
    }

    public enum Refusal: Error, Equatable {
        case unsafeName(String)
        case negative(String)
        case idNotIssued(Int)
        case unknownVersion(Int)
    }

    public internal(set) var items: [Item]
    public private(set) var nextID: Int

    public init() {
        items = []
        nextID = 0
    }

    /// A name that stays inside the library folder: no separator, no leading dot, not empty.
    public static func isSafeFilename(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\") && name != ".."
    }

    /// The list with one more item, given the next id. Refuses what the decoder would refuse.
    @discardableResult
    public mutating func adding(kind: Kind, filename: String, name: String, origin: Origin,
                                durationNanos: Int64? = nil, width: Int? = nil, height: Int? = nil,
                                pictureText: String? = nil, textRevision: Int? = nil) throws -> Item {
        let item = Item(id: nextID, kind: kind, filename: filename, name: name, origin: origin,
                        durationNanos: durationNanos, width: width, height: height,
                        pictureText: pictureText, textRevision: textRevision)
        try Self.check(item)
        items.append(item)
        nextID += 1
        return item
    }

    public mutating func removing(_ id: Int) {
        items.removeAll { $0.id == id }
    }

    private static func check(_ item: Item) throws {
        guard isSafeFilename(item.filename) else { throw Refusal.unsafeName(item.filename) }
        if let duration = item.durationNanos, duration < 0 { throw Refusal.negative("durationNanos") }
        if let width = item.width, width < 0 { throw Refusal.negative("width") }
        if let height = item.height, height < 0 { throw Refusal.negative("height") }
    }

    private enum CodingKeys: String, CodingKey { case version, items, nextID }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.version else { throw Refusal.unknownVersion(version) }
        let items = try container.decode([Item].self, forKey: .items)
        let nextID = try container.decode(Int.self, forKey: .nextID)
        for item in items {
            try Self.check(item)
            guard item.id >= 0, item.id < nextID else { throw Refusal.idNotIssued(item.id) }
        }
        self.items = items
        self.nextID = nextID
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.version, forKey: .version)
        try container.encode(items, forKey: .items)
        try container.encode(nextID, forKey: .nextID)
    }
}

/// One thing that can be found: a field of an item, with its span when it has one.
public struct LibraryIndexEntry: Sendable, Equatable {
    public enum Field: Sendable, Equatable, Hashable {
        case stepLabel(step: Int)
        case application(step: Int)
        case spoken
        case pictureText
        case name
    }

    public let itemID: Int
    public let field: Field
    public let text: String
    public let startNanos: Int64?
    public let endNanos: Int64?

    public init(itemID: Int, field: Field, text: String, startNanos: Int64? = nil, endNanos: Int64? = nil) {
        self.itemID = itemID
        self.field = field
        self.text = text
        self.startNanos = startNanos
        self.endNanos = endNanos
    }
}

/// Searching the index: every word of the query in one entry, case and accents folded, the
/// strongest evidence first — a pressed label is what the speaker pointed at, then what was said,
/// then what a picture shows, then a name a person typed.
public enum LibrarySearch {
    public static func search(_ query: String, in index: [LibraryIndexEntry]) -> [LibraryIndexEntry] {
        let words = fold(query).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty else { return [] }
        return index.enumerated()
            .filter { _, entry in
                let text = fold(entry.text)
                return words.allSatisfy { text.contains($0) }
            }
            .sorted { a, b in
                let ra = rank(a.element.field), rb = rank(b.element.field)
                return ra != rb ? ra < rb : a.offset < b.offset
            }
            .map(\.element)
    }

    static func rank(_ field: LibraryIndexEntry.Field) -> Int {
        switch field {
        case .stepLabel: 0
        case .application: 1
        case .spoken: 2
        case .pictureText: 3
        case .name: 4
        }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

extension Library {
    /// The list for a sharing copy: every file still listed, without the text read off pictures
    /// and without the names a person's files had — the fields judged REDACT in
    /// `FixtureRedactionTests`. A web host stays: a public site's name, and the picture's source.
    public func withoutScreenText() -> Library {
        var copy = self
        copy.items = items.map { item in
            var origin = item.origin
            if case .imported = origin { origin = .imported(originalName: "") }
            return Item(id: item.id, kind: item.kind, filename: item.filename, name: item.name, origin: origin,
                        durationNanos: item.durationNanos, width: item.width, height: item.height,
                        pictureText: nil, textRevision: nil)
        }
        return copy
    }
}

extension EvidenceRedaction {
    /// Redacts the package's library list in place for a sharing copy. `false` when the package has
    /// no library — nothing to redact, said rather than reported as done.
    public static func redactLibrary(in packageURL: URL) throws -> Bool {
        let list = packageURL.appending(path: Library.directory).appending(path: Library.listFilename)
        guard FileManager.default.fileExists(atPath: list.path(percentEncoded: false)) else { return false }
        let library = try JSONDecoder().decode(Library.self, from: Data(contentsOf: list))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(library.withoutScreenText()).write(to: list, options: .atomic)
        return true
    }
}
