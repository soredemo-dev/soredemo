import Timeline

/// A note a person pinned on the recording — "this pause drags", "zoom tighter here" — at a moment
/// and, when they clicked one, a point on the picture.
///
/// **Authored, and so persisted**: the producer-value rule's authored half. What the note refers to
/// in the observation log — the step it falls in — is derived on reading (`NoteBoard.anchored`),
/// never stored, so a note keeps meaning the same thing when the steps are re-derived.
///
/// **A validating decoder**, because a note arrives from a project file, which is untrusted input
/// (rule 8): an empty text, a negative time or a point off the picture is refused by name.
public struct PinnedNote: Hashable, Sendable, Codable, Identifiable {
    public enum State: Hashable, Sendable, Codable {
        case open
        /// Done, with what was done — the agent's reason, or the person's.
        case addressed(String)
        /// Left as it was, with why.
        case skipped(String)
    }

    public enum Refusal: Error, Equatable {
        case emptyText
        case textTooLong(Int)
        case negativeTime(Int64)
        case pointOffThePicture(x: Double, y: Double)
    }

    /// Longest note kept: a sentence or two, the length a person writes beside a picture.
    public static let longestText = 500

    public let id: Int
    /// Nanoseconds on the recording's clock.
    public let at: Nanoseconds
    /// Where on the picture, 0…1 from the top left, or `nil` for a note about the moment alone.
    public let x: Double?
    public let y: Double?
    public let text: String
    public let state: State

    public init(id: Int, at: Nanoseconds, x: Double?, y: Double?, text: String, state: State = .open) throws(Refusal) {
        let words = text.trimmingWhitespaceAndNewlines
        guard !words.isEmpty else { throw .emptyText }
        guard words.count <= Self.longestText else { throw .textTooLong(words.count) }
        guard at.rawValue >= 0 else { throw .negativeTime(at.rawValue) }
        if x != nil || y != nil {
            guard let x, let y, (0...1).contains(x), (0...1).contains(y) else {
                throw .pointOffThePicture(x: x ?? .nan, y: y ?? .nan)
            }
        }
        self.id = id
        self.at = at
        self.x = x
        self.y = y
        self.text = words
        self.state = state
    }

    private enum CodingKeys: String, CodingKey { case id, at, x, y, text, state }

    /// Through the validating initialiser — never straight into the stored properties.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(Int.self, forKey: .id), at: c.decode(Nanoseconds.self, forKey: .at),
                      x: c.decodeIfPresent(Double.self, forKey: .x), y: c.decodeIfPresent(Double.self, forKey: .y),
                      text: c.decode(String.self, forKey: .text), state: c.decode(State.self, forKey: .state))
    }

    /// The same note in another state. Only the state changes, so nothing needs validating again.
    func with(state: State) -> PinnedNote { PinnedNote(validated: self, state: state) }

    private init(validated note: PinnedNote, state: State) {
        id = note.id
        at = note.at
        x = note.x
        y = note.y
        text = note.text
        self.state = state
    }

    public var isOpen: Bool { state == .open }
}

/// Every note on one recording, and the operations a person and an agent perform on them.
public struct NoteBoard: Hashable, Sendable, Codable {
    public private(set) var notes: [PinnedNote]
    /// Never reused, so a resolution cannot land on a different note that took a deleted one's id.
    public private(set) var nextID: Int

    public init(notes: [PinnedNote] = []) {
        self.notes = notes.sorted { $0.at < $1.at }
        nextID = (notes.map(\.id).max() ?? 0) + 1
    }

    private enum CodingKeys: String, CodingKey { case notes, nextID }

    /// `nextID` is raised past every id present: a file whose counter fell behind its notes would
    /// otherwise mint an id that is already taken.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let notes = try c.decode([PinnedNote].self, forKey: .notes)
        self.init(notes: notes)
        nextID = max(nextID, try c.decode(Int.self, forKey: .nextID))
    }

    public var open: [PinnedNote] { notes.filter(\.isOpen) }

    /// A new note, or why it could not be pinned.
    public func adding(at: Nanoseconds, x: Double?, y: Double?, text: String) throws(PinnedNote.Refusal) -> NoteBoard {
        var next = self
        let note = try PinnedNote(id: nextID, at: at, x: x, y: y, text: text)
        next.notes.append(note)
        next.notes.sort { $0.at < $1.at }
        next.nextID += 1
        return next
    }

    public func removing(_ id: Int) -> NoteBoard {
        var next = self
        next.notes.removeAll { $0.id == id }
        return next
    }

    /// The note marked addressed or skipped, with the words that say how. `nil` when there is no
    /// such note, or it is not open — a note is resolved once, and reopened by a person.
    public func resolving(_ id: Int, as state: PinnedNote.State) -> NoteBoard? {
        guard state != .open, let index = notes.firstIndex(where: { $0.id == id }), notes[index].isOpen else { return nil }
        var next = self
        next.notes[index] = notes[index].with(state: state)
        return next
    }

    public func reopening(_ id: Int) -> NoteBoard? {
        guard let index = notes.firstIndex(where: { $0.id == id }), !notes[index].isOpen else { return nil }
        var next = self
        next.notes[index] = notes[index].with(state: .open)
        return next
    }

    /// The notes pinned within `window` of a moment on the recording's clock — what the preview
    /// draws as the playhead passes.
    public func near(_ time: Nanoseconds, within window: Nanoseconds) -> [PinnedNote] {
        notes.filter { abs($0.at.rawValue - time.rawValue) <= window.rawValue }
    }

    /// Each note with the step it falls in — the last to begin at or before it — derived here so
    /// the agent is told "during step 4, Export", not only a time and a point.
    public func anchored(to steps: [RecordedStep], anchor: EpochAnchor) -> [(note: PinnedNote, step: RecordedStep?)] {
        notes.map { note in
            let instant = anchor.hostTime.rawValue + note.at.rawValue
            return (note, steps.filter { $0.origin.epoch == anchor.epoch && $0.origin.hostTime.rawValue <= instant }
                .max { $0.origin.hostTime < $1.origin.hostTime })
        }
    }
}

private extension String {
    var trimmingWhitespaceAndNewlines: String {
        var view = Substring(self)
        while let first = view.first, first.isWhitespace { view = view.dropFirst() }
        while let last = view.last, last.isWhitespace { view = view.dropLast() }
        return String(view)
    }
}
