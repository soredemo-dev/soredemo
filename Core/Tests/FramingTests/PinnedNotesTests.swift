import Foundation
import Geometry
import Project
import Testing
import Timeline
@testable import Framing

// Notes a person pins on a recording, for the agent to address. A recording anchored at 100 s with
// steps at 104 s and 115 s; every value below is a literal.

private let epoch = BootEpoch(id: UUID(uuidString: "0E7E5000-0000-4000-8000-0000000000E1")!)
private let second: Int64 = 1_000_000_000
private let anchor = EpochAnchor(epoch: epoch, hostTime: Nanoseconds(100 * second), wallClockUnixNanos: 0)

private func at(_ seconds: Int64) -> HostInstant { HostInstant(epoch: epoch, hostTime: Nanoseconds(seconds * second)) }

private let steps = [
    RecordedStep(origin: at(104), end: at(115), number: 1, label: "Export", role: "AXButton", application: "Keynote", frame: nil),
    RecordedStep(origin: at(115), end: at(120), number: 2, label: "Done", role: "AXButton", application: "Keynote", frame: nil),
]

private func board() throws -> NoteBoard {
    try NoteBoard()
        .adding(at: Nanoseconds(12 * second), x: 0.6, y: 0.3, text: "  This pause drags  ")
        .adding(at: Nanoseconds(2 * second), x: nil, y: nil, text: "Start later")
}

@Suite struct PinnedNotesTests {
    @Test func notesAreKeptInTimeOrderWithTheirWordsTrimmed() throws {
        let notes = try board().notes
        #expect(notes.map(\.text) == ["Start later", "This pause drags"])
        #expect(notes.map(\.id) == [2, 1], "ids are the order they were pinned in, not the time order")
    }

    /// The agent is told the step a note falls in, derived from the log rather than stored.
    @Test func eachNoteIsAnchoredToTheStepItFallsIn() throws {
        let anchored = try board().anchored(to: steps, anchor: anchor)
        #expect(anchored.map { $0.step?.number } == [nil, 1], "2 s is before any step; 12 s is during step 1")
    }

    @Test func whatCannotBeANoteIsRefusedByName() {
        #expect(throws: PinnedNote.Refusal.emptyText) { try NoteBoard().adding(at: Nanoseconds(0), x: nil, y: nil, text: "   ") }
        #expect(throws: PinnedNote.Refusal.negativeTime(-1)) { try NoteBoard().adding(at: Nanoseconds(-1), x: nil, y: nil, text: "a") }
        #expect(throws: PinnedNote.Refusal.textTooLong(501)) {
            try NoteBoard().adding(at: Nanoseconds(0), x: nil, y: nil, text: String(repeating: "a", count: 501))
        }
        #expect(throws: (any Error).self) { try NoteBoard().adding(at: Nanoseconds(0), x: 1.2, y: 0.5, text: "a") }
        #expect(throws: (any Error).self) { try NoteBoard().adding(at: Nanoseconds(0), x: 0.5, y: nil, text: "a") }
    }

    /// A note is resolved once, with what was done, and reopened only by a person.
    @Test func aNoteIsResolvedOnceWithItsReasonAndCanBeReopened() throws {
        let resolved = try #require(try board().resolving(1, as: .addressed("Cut 2.1 s of the pause")))
        #expect(resolved.notes.first { $0.id == 1 }?.state == .addressed("Cut 2.1 s of the pause"))
        #expect(resolved.open.map(\.id) == [2])
        #expect(resolved.resolving(1, as: .skipped("again")) == nil, "already resolved")
        #expect(try board().resolving(9, as: .addressed("x")) == nil, "no such note")
        #expect(resolved.reopening(1)?.open.count == 2)
    }

    @Test func thePreviewShowsTheNotesNearThePlayhead() throws {
        #expect(try board().near(Nanoseconds(11 * second), within: Nanoseconds(1_500_000_000)).map(\.id) == [1])
        #expect(try board().near(Nanoseconds(7 * second), within: Nanoseconds(1_500_000_000)).isEmpty)
    }

    /// From a file: the validating initialiser runs, and a counter that fell behind is raised.
    @Test func aBoardFromAFileIsValidatedAndItsCounterKeptAhead() throws {
        let good = #"{"nextID":1,"notes":[{"at":{"rawValue":5000000000},"id":7,"state":{"open":{}},"text":"Hi"}]}"#
        let decoded = try JSONDecoder().decode(NoteBoard.self, from: Data(good.utf8))
        #expect(decoded.nextID == 8, "raised past note 7 so a new note cannot take its id")
        let bad = #"{"nextID":1,"notes":[{"at":{"rawValue":5000000000},"id":7,"state":{"open":{}},"text":"  "}]}"#
        #expect(throws: (any Error).self) { try JSONDecoder().decode(NoteBoard.self, from: Data(bad.utf8)) }
        let round = try JSONDecoder().decode(NoteBoard.self, from: JSONEncoder().encode(try board()))
        #expect(round == (try board()))
    }

    @Test func removingANoteDoesNotFreeItsId() throws {
        let next = try board().removing(1).adding(at: Nanoseconds(0), x: nil, y: nil, text: "again")
        #expect(next.notes.map(\.id).sorted() == [2, 3])
    }
}
