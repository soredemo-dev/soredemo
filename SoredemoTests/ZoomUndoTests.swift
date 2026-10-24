import Testing
import Foundation
import Framing
import Geometry
import Timeline
@testable import Soredemo

private let second: Int64 = 1_000_000_000
private let epoch = BootEpoch(id: UUID(uuidString: "3C3C3C3C-1D1D-4E4E-9F9F-2A2A2A2A2A2A")!)
/// A zoom from 4 s to 6 s — not at the recording's start, so a move that went nowhere and a
/// move undone to zero cannot look alike.
private let origin = HostInstant(epoch: epoch, hostTime: Nanoseconds(4 * second))

/// A 10 s recording with one derived zoom at 4–6 s, then split at 2 s so there is a clip edit
/// in the history BEFORE any zoom change — the edit a zoom's ⌘Z used to undo instead.
@MainActor private func splitWithAZoom() -> TimelineEditorModel {
    let model = TimelineEditorModel(scrubbingThrough: { _ in })
    model.load(duration: 10)
    model.setZoomAnchor(EpochAnchor(epoch: epoch, hostTime: Nanoseconds(0), wallClockUnixNanos: 0))
    let target = FramingTarget(
        frame: NormalizedFrame(origin: NormalizedPoint(x: 0.3, y: 0.6),
                               size: NormalizedSize(width: 0.05, height: 0.05),
                               revision: GeometryRevision(id: 1)), role: "AXButton")
    model.setDerivedZooms([ZoomBlock(origin: origin, start: origin,
                                     end: HostInstant(epoch: epoch, hostTime: Nanoseconds(6 * second)),
                                     target: target, zoom: 2)])
    model.movePlayhead(to: Nanoseconds(2 * second))
    model.splitAtPlayhead()
    return model
}

@MainActor private func zoomStart(_ model: TimelineEditorModel) -> Nanoseconds? {
    model.zooms.first.flatMap { model.offset(of: $0.start) }
}

@MainActor @Suite(.serialized) struct ZoomUndoTests {
    @Test func undoPutsAMovedZoomBackAndLeavesTheEditBeforeIt() {
        let model = splitWithAZoom()
        model.previewZoomMove(origin, byNanoseconds: 3 * second / 2)
        model.commitZoomDrag(.move)
        #expect(zoomStart(model) == Nanoseconds(11 * second / 2))

        model.undo()
        #expect(zoomStart(model) == Nanoseconds(4 * second), "the zoom is back")
        #expect(model.edit.clips.count == 2, "and the split before it is still there")

        model.undo()
        #expect(model.edit.clips.count == 1, "the next ⌘Z undoes the split")
    }

    @Test func theStepIsNamedForWhatTheDragDid() {
        let model = splitWithAZoom()
        model.previewZoomMove(origin, byNanoseconds: second)
        model.commitZoomDrag(.move)
        #expect(model.undoTitle?.contains(String(localized: "Move Zoom")) == true)

        model.previewZoomResize(origin, byNanoseconds: second)
        model.commitZoomDrag(.resize)
        #expect(model.undoTitle?.contains(String(localized: "Resize Zoom")) == true)
    }

    /// A trim's rule: the pixels a cursor travelled are not steps; letting go is.
    @Test func aDragNotYetReleasedIsNotAStep() {
        let model = splitWithAZoom()
        let before = model.undoTitle
        model.previewZoomMove(origin, byNanoseconds: second)
        model.previewZoomMove(origin, byNanoseconds: 2 * second)
        #expect(zoomStart(model) == Nanoseconds(6 * second), "the preview shows the drag")
        #expect(model.undoTitle == before, "and the history has not moved")
    }

    @Test func switchingAZoomOffIsUndoneAndRedone() {
        let model = splitWithAZoom()
        model.toggleZoomSuppressed(origin)
        #expect(model.isZoomSuppressed(origin))
        model.undo()
        #expect(!model.isZoomSuppressed(origin))
        #expect(model.edit.clips.count == 2)
        model.redo()
        #expect(model.isZoomSuppressed(origin))
    }

    /// Opening a project is not an edit to whatever was open before it.
    @Test func restoringSavedZoomsLeavesNothingToUndo() {
        let model = TimelineEditorModel(scrubbingThrough: { _ in })
        model.load(duration: 10)
        model.restoreZoomAdjustments([ZoomAdjustment(origin: origin).settingSuppressed(true)])
        #expect(model.isZoomSuppressed(origin))
        #expect(!model.canUndo)
    }
}
