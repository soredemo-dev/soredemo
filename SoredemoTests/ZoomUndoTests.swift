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
        model.commitZoomDrag(.resizeEnd)
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

// MARK: - both edges, the neighbour, and the curve

/// Zooms at 4–6 s and 7–9 s, for the drags that run into a neighbour.
@MainActor private func twoZooms() -> TimelineEditorModel {
    let model = TimelineEditorModel(scrubbingThrough: { _ in })
    model.load(duration: 12)
    model.setZoomAnchor(EpochAnchor(epoch: epoch, hostTime: Nanoseconds(0), wallClockUnixNanos: 0))
    func zoom(_ from: Int64, _ to: Int64) -> ZoomBlock {
        let target = FramingTarget(
            frame: NormalizedFrame(origin: NormalizedPoint(x: 0.3, y: 0.6),
                                   size: NormalizedSize(width: 0.05, height: 0.05),
                                   revision: GeometryRevision(id: 1)), role: "AXButton")
        let start = HostInstant(epoch: epoch, hostTime: Nanoseconds(from * second))
        return ZoomBlock(origin: start, start: start,
                         end: HostInstant(epoch: epoch, hostTime: Nanoseconds(to * second)),
                         target: target, zoom: 2)
    }
    model.setDerivedZooms([zoom(4, 6), zoom(7, 9)])
    return model
}

private let second2 = HostInstant(epoch: epoch, hostTime: Nanoseconds(7 * second))

@MainActor private func edges(_ model: TimelineEditorModel, _ origin: HostInstant) -> (Nanoseconds?, Nanoseconds?) {
    let block = model.zooms.first { $0.origin == origin }
    return (block.flatMap { model.offset(of: $0.start) }, block.flatMap { model.offset(of: $0.end) })
}

@MainActor @Suite(.serialized) struct ZoomEdgeTests {
    /// The left edge moves the start and leaves the end where it was.
    @Test func draggingTheStartKeepsTheEnd() {
        let model = twoZooms()
        model.previewZoomResizeStart(origin, byNanoseconds: -second / 2)
        model.commitZoomDrag(.resizeStart)
        let (start, end) = edges(model, origin)
        #expect(start == Nanoseconds(7 * second / 2))
        #expect(end == Nanoseconds(6 * second), "the end did not move")
        #expect(model.undoTitle?.contains(String(localized: "Resize Zoom")) == true)
    }

    /// A move into the next zoom stops at its start rather than overlapping it.
    @Test func aMoveStopsAtTheNeighbour() {
        let model = twoZooms()
        model.previewZoomMove(origin, byNanoseconds: 3 * second)
        let (start, end) = edges(model, origin)
        #expect(end == Nanoseconds(7 * second), "stopped at the next zoom's start")
        #expect(start == Nanoseconds(5 * second), "and kept its length")
    }

    @Test func aResizeStopsAtTheNeighbour() {
        let model = twoZooms()
        model.previewZoomResize(origin, byNanoseconds: 5 * second)
        #expect(edges(model, origin).1 == Nanoseconds(7 * second))
        model.commitZoomDrag(.resizeEnd)
        model.previewZoomResizeStart(second2, byNanoseconds: -5 * second)
        #expect(edges(model, second2).0 == Nanoseconds(7 * second), "the second's start stops at the first's new end")
    }

    /// A zoom switched off is not drawn into the picture, so it is not in the way.
    @Test func aSwitchedOffZoomIsNotInTheWay() {
        let model = twoZooms()
        model.toggleZoomSuppressed(second2)
        model.previewZoomMove(origin, byNanoseconds: 2 * second)
        #expect(edges(model, origin).1 == Nanoseconds(8 * second))
    }

    @Test func theLaneChoosesTheDragFromWhereThePressLands() {
        #expect(TimelineZoomLane.drag(startingAt: 2, width: 40) == .resizeStart)
        #expect(TimelineZoomLane.drag(startingAt: 20, width: 40) == .move)
        #expect(TimelineZoomLane.drag(startingAt: 38, width: 40) == .resizeEnd)
        #expect(TimelineZoomLane.drag(startingAt: 1, width: 12) == .move, "too narrow for edges")
    }

    // MARK: the curve

    @Test func theCurveIsZeroAtRestAndOneAtTheDeepestZoomInView() throws {
        let model = twoZooms()
        let curve = model.zoomCurve(columns: 120)   // 10 columns a second over 12 s
        try #require(curve.count == 120)
        #expect(curve[0..<38].allSatisfy { $0 < 0.01 }, "at rest before the first zoom")
        #expect(abs((curve.max() ?? 0) - 1) < 1e-9, "the deepest point fills the lane")
        #expect(curve[50] > 0.8, "held inside the first zoom")
    }

    /// **The cache pair.** Asking twice with nothing changed bakes once; moving a zoom or
    /// changing the pace bakes again — and the curve then follows the move.
    @Test func theCameraIsBakedOnceAndAgainWhenTheZoomsOrThePaceChange() {
        let model = twoZooms()
        _ = model.zoomCurve(columns: 120)   // the bake under test; its curve is not
        let before = model.cameraBakes
        #expect(model.zoomCurve(columns: 120) == model.zoomCurve(columns: 120))
        #expect(model.cameraBakes == before, "unchanged zooms were baked again")

        let rest = model.zoomCurve(columns: 120)[45]
        model.previewZoomMove(origin, byNanoseconds: -3 * second)
        #expect(model.zoomCurve(columns: 120)[45] < rest, "the moved zoom moved the curve")
        #expect(model.cameraBakes == before + 1)

        model.cameraPace = .gentle
        _ = model.zoomCurve(columns: 120)   // asked only to count the bake
        #expect(model.cameraBakes == before + 2, "a new pace is a new bake")
    }
}
