import Testing
import Foundation
import Framing
import Geometry
import Project
import Timeline
@testable import Soredemo

// Accepting and dismissing a proposed cut, through the timeline model's one history.
// `docs/design/2026-11-08-evidence-cut-and-the-agent-surface.md`, "The review list".
//
// A twenty-second recording anchored at 100 s with clicks at 104 s and 115 s: three proposals,
// removing 0–3.5, 4.5–14.5 and 15.5–20 on the recording's own clock.

private let epoch = BootEpoch(id: UUID(uuidString: "C07AE71E-0000-4000-8000-0000000000A1")!)
private let second: Int64 = 1_000_000_000
private let anchor = EpochAnchor(epoch: epoch, hostTime: Nanoseconds(100 * second), wallClockUnixNanos: 0)

private func click(_ seconds: Int64) -> ButtonEvent {
    ButtonEvent(instant: HostInstant(epoch: epoch, hostTime: Nanoseconds(seconds * second)),
                position: NormalizedPoint(x: 0.3, y: 0.3), revision: GeometryRevision(id: 2),
                button: .left, phase: .down)
}

private func proposals() throws -> [CutProposal] {
    let take = try TakeActivity(
        recording: HostRange(epoch: epoch, start: Nanoseconds(100 * second), duration: Nanoseconds(20 * second)),
        steps: [], pointer: [], buttons: [click(104), click(115)], shortcuts: [], speech: [], unobserved: [])
    return DeadAirProposer().proposals(for: take)
}

@MainActor private func listing(_ model: TimelineEditorModel) throws -> CutReview.Listing {
    CutReview.listing(try proposals(), dismissed: model.dismissedCuts, edit: model.edit, anchor: anchor)
}

/// The thesis's one sentence for this feature: a person accepts one and the timeline changes,
/// undoably — and undoing puts the proposal back on the list, because the list reads the edit.
@Test @MainActor func acceptingAProposalCutsItAndUndoPutsItBackOnTheList() throws {
    let model = TimelineEditorModel()
    model.load(duration: 20)
    let row = try #require(try listing(model).rows.dropFirst().first)
    model.acceptCut(row, named: "Cut 10.0s Pause")
    #expect(model.edit.outputDuration == Nanoseconds(10 * second))
    #expect(try listing(model).rows.count == 2)
    // Contains, not equals: the frame around the name is the system language's ("還原「…」").
    #expect(model.undoTitle?.contains("Cut 10.0s Pause") == true, "the undo step is named by what it cut")
    model.undo()
    #expect(model.edit.outputDuration == Nanoseconds(20 * second))
    #expect(try listing(model).rows.count == 3)
}

@Test @MainActor func dismissingAProposalIsAStepUndoTakesBack() throws {
    let model = TimelineEditorModel()
    model.load(duration: 20)
    let row = try #require(try listing(model).rows.first)
    model.dismissCut(row.proposal.key, named: "Keep 4.0s Pause")
    #expect(try listing(model).rows.count == 2 && (try listing(model)).dismissed == 1)
    #expect(model.edit.outputDuration == Nanoseconds(20 * second), "a dismissal cuts nothing")
    model.undo()
    #expect(try listing(model).rows.count == 3)
}

/// A clip edit after a dismissal must not drop the dismissal — every history write goes through
/// one copy-and-replace, and this is the test that it does.
@Test @MainActor func aCutAfterADismissalKeepsTheDismissal() throws {
    let model = TimelineEditorModel()
    model.load(duration: 20)
    let rows = try listing(model).rows
    model.dismissCut(rows[0].proposal.key, named: "Keep")
    model.acceptCut(rows[2], named: "Cut")
    model.movePlayhead(to: SourceTime(Nanoseconds(2 * second)))
    model.splitAtPlayhead()
    #expect(model.dismissedCuts == [rows[0].proposal.key])
}

@Test @MainActor func cuttingAllIsOneUndoStep() throws {
    let model = TimelineEditorModel()
    model.load(duration: 20)
    model.acceptCuts(try listing(model).rows, named: "Cut Quiet Spans (3)")
    #expect(model.edit.outputDuration == Nanoseconds(2 * second))
    model.undo()
    #expect(model.edit.outputDuration == Nanoseconds(20 * second), "one ⌘Z undoes all three")
}

/// The producer-value rule for a "no": a saved dismissal outranks the re-derivation on open.
@Test @MainActor func aDismissalSurvivesSavingAndOpening() throws {
    let editor = EditorViewModel()
    editor.timeline.load(duration: 20)
    let key = try #require(try listing(editor.timeline).rows.first).proposal.key
    editor.timeline.dismissCut(key, named: "Keep")
    let saved = editor.currentEditState(hasCamera: false)

    let reopened = EditorViewModel()
    reopened.timeline.load(duration: 20)
    #expect(reopened.restore(saved).isEmpty)
    #expect(reopened.timeline.dismissedCuts == [key])
    #expect(try listing(reopened.timeline).rows.count == 2)
}
