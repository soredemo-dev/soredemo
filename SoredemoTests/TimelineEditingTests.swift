import Testing
import Foundation
import Framing
import Timeline
@testable import Soredemo

private func ns(_ seconds: Double) -> Nanoseconds { Nanoseconds(Int64((seconds * 1000).rounded()) * 1_000_000) }

/// **A 20 s recording with 2–5 s already cut out**, so source and output time differ by 3 s
/// everywhere after the cut. A fixture with no cut would make every source↔output conversion
/// below pass whether or not it converts — the two clocks are equal until the first cut.
@MainActor private func cutTimeline() -> TimelineEditorModel {
    let model = TimelineEditorModel()
    model.load(duration: 20)
    model.selection = ns(2).rawValue..<ns(5).rawValue
    model.removeSelection()
    return model
}

@MainActor @Suite(.serialized) struct TimelineEditingTests {
    // MARK: - the export range (output time)

    @Test func pressingInTwiceCancelsIt() {
        let model = cutTimeline()
        model.movePlayhead(to: ns(4))
        model.markIn()
        #expect(model.exportRange == ns(4).rawValue..<ns(17).rawValue)
        model.markIn()
        #expect(model.exportRange == nil)
    }

    @Test func anOutPointBeforeTheInPointClearsTheInPoint() {
        let model = cutTimeline()
        model.movePlayhead(to: ns(9))
        model.markIn()
        model.movePlayhead(to: ns(6))
        model.markOut()
        #expect(model.exportRange == 0..<ns(6).rawValue)
    }

    /// An in point at the very start is the whole video, not a section of it.
    @Test func aRangeThatIsTheWholeVideoIsNoRange() {
        let model = cutTimeline()
        model.movePlayhead(to: ns(0))
        model.markIn()
        #expect(model.exportRange == nil)
        #expect(model.editForExport == model.edit)
    }

    @Test func theExportIsRestrictedAndThePreviewIsNot() {
        let model = cutTimeline()
        model.movePlayhead(to: ns(10))
        model.markOut()
        #expect(model.editForExport.outputDuration == ns(10))
        #expect(model.edit.outputDuration == ns(17))
        model.clearExportRange()
        #expect(model.exportRange == nil)
    }

    // MARK: - editing (source time), and the history

    /// The playhead is in SOURCE time and a split takes OUTPUT time: at source 10 after a 3 s cut
    /// the split must land at output 7, and the clip boundary at source 10.
    @Test func aSplitAfterACutLandsWhereThePlayheadIs() {
        let model = cutTimeline()
        model.movePlayhead(to: ns(10))
        #expect(model.canSplitAtPlayhead)
        model.splitAtPlayhead()
        #expect(model.edit.clips.map(\.sourceStart) == [ns(0), ns(5), ns(10)])
        #expect(model.edit.outputDuration == ns(17))
    }

    @Test func thereIsNothingToSplitInsideACut() {
        let model = cutTimeline()
        model.movePlayhead(to: ns(3))
        #expect(!model.canSplitAtPlayhead)
    }

    @Test func aTapInsideACutSelectsNothing() {
        let model = cutTimeline()
        model.selectClip(atSource: ns(3))
        #expect(model.selectedClip == nil)
        model.selectClip(atSource: ns(12))
        #expect(model.selectedClip != nil)
    }

    @Test func deletingAClipClosesTheGapAndUndoBringsItBack() {
        let model = cutTimeline()
        model.selectClip(atSource: ns(12))
        model.deleteSelectedClip()
        #expect(model.edit.outputDuration == ns(2))
        #expect(model.selectedClip == nil)
        model.undo()
        #expect(model.edit.outputDuration == ns(17))
        #expect(model.canRedo)
        model.redo()
        #expect(model.edit.outputDuration == ns(2))
    }

    /// Undo past a split removes the right-hand clip; its id must not stay selected, or Delete
    /// Clip would be offered with nothing to delete.
    @Test func undoingPastASplitForgetsTheClipItRemoved() {
        let model = cutTimeline()
        model.movePlayhead(to: ns(10))
        model.splitAtPlayhead()
        model.selectClip(atSource: ns(15))
        #expect(model.selectedClip != nil)
        model.undo()
        #expect(model.selectedClip == nil)
    }

    @Test func keepingOnlyTheSelectionTrimsToIt() {
        let model = cutTimeline()
        model.selection = ns(8).rawValue..<ns(14).rawValue
        model.keepOnlySelection()
        #expect(model.edit.outputDuration == ns(6))
        #expect(model.selection == nil)
    }

    @Test func revertAllGoesBackToWhatWasOpened() {
        let model = cutTimeline()
        #expect(model.hasEdits)
        model.restore()
        #expect(!model.hasEdits)
        #expect(model.edit.outputDuration == ns(20))
    }

    /// Choosing the speed a clip already has is not an edit and must not add an undo step.
    ///
    /// **Held in two places, and this reddens only when both go** — measured by mutation:
    /// `setSelectedSpeed` returns early on an unchanged speed, and `EditHistory.record` refuses a
    /// value equal to the current one. Either alone keeps it green. The test is about the
    /// behaviour a person sees, which is what both exist for.
    @Test func aSpeedIsAnEditOnlyWhenItChanges() {
        let model = TimelineEditorModel()
        model.load(duration: 20)
        model.selectClip(atSource: ns(4))
        model.setSelectedSpeed(1)
        #expect(!model.canUndo)
        model.setSelectedSpeed(2)
        #expect(model.selectedSpeed == 2)
        #expect(model.edit.outputDuration == ns(10))
        #expect(model.canUndo)
    }

    @Test func aFadeChangesOnlyTheEndItNames() {
        let model = cutTimeline()
        model.selectClip(atSource: ns(12))
        model.setSelectedFade(in: 0.5)
        #expect(model.selectedFades?.in == 0.5 && model.selectedFades?.out == 0)
        model.setSelectedFade(out: 1)
        #expect(model.selectedFades?.in == 0.5 && model.selectedFades?.out == 1)
    }

    @Test func anEmptySpanRemovesNothing() {
        let model = cutTimeline()
        let before = model.edit
        model.removeSourceRange(ns(9).rawValue..<ns(9).rawValue, named: "nothing")
        #expect(model.edit == before)
    }

    /// Playback reports OUTPUT time; the playhead is SOURCE time.
    @Test func followingThePlayerConvertsOutputToSource() {
        let model = cutTimeline()
        model.followPlayer(outputTime: ns(7))
        #expect(model.playhead == ns(10))
    }

    // MARK: - what a project saves

    @Test func theWholeRecordingIsNotSavedAsAnEdit() {
        let model = TimelineEditorModel()
        model.load(duration: 20)
        #expect(model.editToSave == nil)
        #expect(cutTimeline().editToSave?.outputDuration == ns(17))
    }

    // MARK: - zooms

    @Test func switchingAZoomOffAndOnIsRememberedPerZoom() {
        let model = cutTimeline()
        let epoch = BootEpoch(id: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!)
        let one = HostInstant(epoch: epoch, hostTime: ns(6))
        let two = HostInstant(epoch: epoch, hostTime: ns(9))
        model.toggleZoomSuppressed(one)
        #expect(model.isZoomSuppressed(one) && !model.isZoomSuppressed(two))
        #expect(!model.isZoomAdjusted(one), "switching off is not moving")
        #expect(model.hasZoomEdits)
        model.resetZooms()
        #expect(!model.isZoomSuppressed(one) && !model.hasZoomEdits)
    }

    // MARK: - the strip's own labels

    @Test func rulerLabelsShowTenthsOnlyWhenTheStepIsUnderASecond() {
        #expect(TimelineRuler.tickLabel(75.4, step: 5) == "1:15")
        #expect(TimelineRuler.tickLabel(75.4, step: 0.5) == "1:15.4")
    }

    @Test func theTickStepWidensAsMoreTimeIsVisible() {
        let near = TimelineRuler.tickStep(visibleSeconds: 3, width: 600)
        let far = TimelineRuler.tickStep(visibleSeconds: 1200, width: 600)
        #expect(near < far)
        #expect(far * 600 / 1200 >= 64, "labels at least 64 points apart")
    }

    @Test func theReadoutStampHasHundredths() {
        #expect(TimelineEditor.stamp(ns(83.25)) == "1:23.25")
    }
}
