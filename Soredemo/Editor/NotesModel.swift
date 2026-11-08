import Foundation
import Framing
import Observation
import Timeline

/// The notes a person pinned on this recording, and whether the editor is waiting for a click to
/// pin one.
///
/// **Its own model**: a note is about the recording, not about the agent or the timeline, and the
/// agent is only one of the ways a note gets addressed. The Agent tab reads and resolves these; the
/// preview draws and places them.
@Observable
@MainActor
final class NotesModel {
    private(set) var board = NoteBoard()
    /// Waiting for a click on the preview to pin a note there — what N turns on.
    var isPlacing = false
    /// A note being written, at a point, before it is pinned.
    var draft: Draft?
    /// Why the last note could not be pinned, said beside the field.
    private(set) var refusal: String?

    struct Draft: Equatable {
        let at: Nanoseconds
        let x: Double
        let y: Double
        var text = ""
    }

    /// How close to a note the playhead has to be for the preview to draw it.
    static let visibleWithin = Nanoseconds(1_500_000_000)

    var open: [PinnedNote] { board.open }

    func begin(at: Nanoseconds, x: Double, y: Double) {
        isPlacing = false
        refusal = nil
        draft = Draft(at: at, x: x, y: y)
    }

    /// Pins the draft. Returns whether it was pinned; the reason it was not is in `refusal`.
    @discardableResult
    func pin() -> Bool {
        guard let draft else { return false }
        do {
            board = try board.adding(at: draft.at, x: draft.x, y: draft.y, text: draft.text)
            self.draft = nil
            refusal = nil
            return true
        } catch .emptyText {
            refusal = String(localized: "Write what should change here.")
        } catch .textTooLong(let count) {
            refusal = String(localized: "Keep a note under \(PinnedNote.longestText) characters; this one is \(count).")
        } catch {
            refusal = "\(error)"
        }
        return false
    }

    func cancel() {
        draft = nil
        isPlacing = false
        refusal = nil
    }

    func remove(_ id: Int) { board = board.removing(id) }

    /// The note marked addressed or skipped, by whoever did it. `false` when there is no such open note.
    @discardableResult
    func resolve(_ id: Int, as state: PinnedNote.State) -> Bool {
        guard let next = board.resolving(id, as: state) else { return false }
        board = next
        return true
    }

    func reopen(_ id: Int) {
        if let next = board.reopening(id) { board = next }
    }

    func restore(_ saved: NoteBoard) {
        board = saved
        cancel()
    }
}
