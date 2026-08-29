import Foundation
import Testing
@testable import Timeline

private func ns(_ value: Int64) -> Nanoseconds { Nanoseconds(value) }

/// **A stack of values, not of inverse operations**, because `EditTimeline` is a value and
/// every edit already produces a whole new one. The usual shape registers a closure
/// per mutation, which is right for the mutable object graph it edits and wrong here: an
/// inverse is a second implementation of an edit, and two implementations of one rule is the
/// shape this project keeps finding bugs in.
@Suite struct EditHistoryTests {
    private func whole(_ length: Int64) -> EditTimeline { .whole(duration: ns(length)) }

    @Test func aFreshHistoryHasNothingToUndoOrRedo() {
        let history = EditHistory(whole(1_000))
        #expect(!history.canUndo)
        #expect(!history.canRedo)
        #expect(history.undoName == nil)
        #expect(history.redoName == nil)
    }

    @Test func undoRestoresTheValueThatCameBefore() {
        var history = EditHistory(whole(1_000))
        let cut = whole(1_000).removing(sourceRange: 200..<400)
        history.record("Remove selection", cut)

        #expect(history.current == cut)
        #expect(history.canUndo)
        #expect(history.undoName == "Remove selection")

        history.undo()
        #expect(history.current == whole(1_000))
        #expect(!history.canUndo)
        #expect(history.canRedo)
    }

    /// The name travels with the step so a menu can say what it will undo — "Undo Split at
    /// playhead", not "Undo" — and redo offers the same wording from the other side.
    @Test func redoOffersTheSameActionNameTheUndoDid() {
        var history = EditHistory(whole(1_000))
        history.record("Split at playhead", whole(1_000).split(atOutput: ns(400))!)
        history.undo()
        #expect(history.redoName == "Split at playhead")
        history.redo()
        #expect(history.undoName == "Split at playhead")
    }

    @Test func redoReturnsTheValueThatWasUndoneAway() {
        var history = EditHistory(whole(1_000))
        let cut = whole(1_000).removing(sourceRange: 200..<400)
        history.record("cut", cut)
        history.undo()
        history.redo()
        #expect(history.current == cut)
        #expect(!history.canRedo)
    }

    /// **Recording after an undo clears the redo branch.** Once you edit past a point, the
    /// thing you undid is no longer ahead of you — every editor behaves this way, and a redo
    /// that survived would put a value back that no longer follows from the current one.
    @Test func recordingAfterAnUndoDropsWhatWasAhead() {
        var history = EditHistory(whole(1_000))
        history.record("first", whole(1_000).removing(sourceRange: 100..<200))
        history.undo()
        #expect(history.canRedo)

        history.record("second", whole(1_000).removing(sourceRange: 800..<900))
        #expect(!history.canRedo, "the abandoned branch is still reachable")
        #expect(history.undoName == "second")
    }

    /// **A no-op records nothing.** Dragging a handle and putting it back, or splitting on a
    /// boundary, would otherwise leave a step that undoes to the state it is already in — and
    /// a person pressing ⌘Z would see nothing happen and press it again.
    @Test func recordingTheSameValueIsNotAStep() {
        var history = EditHistory(whole(1_000))
        history.record("no-op", whole(1_000))
        #expect(!history.canUndo)
        #expect(history.depth == 0)
    }

    /// Undo and redo are inverses over any sequence, checked by walking a real one rather than
    /// by asserting the property at one point.
    @Test func undoAndRedoRoundTripOverASequenceOfEdits() {
        var history = EditHistory(whole(1_000))
        var expected: [EditTimeline] = [whole(1_000)]
        var timeline = whole(1_000)
        for cut: Int64 in [100, 300, 500, 700] {
            timeline = timeline.removing(sourceRange: cut..<(cut + 50))
            history.record("cut at \(cut)", timeline)
            expected.append(timeline)
        }
        // All the way back…
        for step in stride(from: expected.count - 2, through: 0, by: -1) {
            history.undo()
            #expect(history.current == expected[step], "undo to step \(step) disagreed")
        }
        // …and all the way forward.
        for step in 1..<expected.count {
            history.redo()
            #expect(history.current == expected[step], "redo to step \(step) disagreed")
        }
    }

    /// The bound drops the OLDEST steps, so the most recent edits stay undoable — a history
    /// that refused new steps once full would silently stop recording.
    @Test func theHistoryIsBoundedAndForgetsTheOldest() {
        var history = EditHistory(whole(10_000), limit: 3)
        for cut: Int64 in [100, 200, 300, 400, 500] {
            history.record("cut \(cut)", whole(10_000).removing(sourceRange: cut..<(cut + 10)))
        }
        #expect(history.depth == 3)
        #expect(history.undoName == "cut 500", "the newest step was dropped instead of the oldest")

        // Three undos are available and the fourth is not.
        for _ in 0..<3 { history.undo() }
        #expect(!history.canUndo)
    }

    /// Reopening a recording is not an edit to the one before it.
    @Test func resetForgetsEverything() {
        var history = EditHistory(whole(1_000))
        history.record("cut", whole(1_000).removing(sourceRange: 100..<200))
        history.reset(to: whole(500))
        #expect(history.current == whole(500))
        #expect(!history.canUndo)
        #expect(!history.canRedo)
    }

    /// Undo on an empty history is a no-op that says so, rather than trapping or returning a
    /// value the caller would treat as a change.
    @Test func undoingNothingReturnsNothing() {
        var history = EditHistory(whole(1_000))
        #expect(history.undo() == nil)
        #expect(history.redo() == nil)
        #expect(history.current == whole(1_000))
    }
}
