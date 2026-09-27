import Testing
import Foundation
import Framing
import Geometry
import Timeline
@testable import Soredemo

/// The first executable test the app target has ever had.
///
/// **13,761 lines and nothing ran against them.** The models here are `@Observable` classes with
/// no view in them — they were testable the whole time, and the only thing missing was somewhere
/// to put the tests. See docs/TESTING.md § 5.4.
@Test @MainActor func aFreshTimelineHasNoDurationAndNoExportRange() {
    let model = TimelineEditorModel()
    #expect(model.duration == nil)
    #expect(model.exportRange == nil)
    #expect(model.playhead == Nanoseconds(0))
}

// MARK: - trims and zooms line up

private let second: Int64 = 1_000_000_000

/// A trim dragged near the playhead lands ON it — the range selection's rule, now on the handles.
@Test @MainActor func aTrimNearThePlayheadLandsOnIt() throws {
    let model = TimelineEditorModel()
    model.load(duration: 10)
    model.movePlayhead(to: Nanoseconds(3 * second))
    let clip = try #require(model.edit.clips.first)
    // The end dragged from 10 s to 3.05 s, with a tenth of a second counting as near.
    model.previewTrim(of: clip.id, edge: .end, byNanoseconds: -(7 * second - second / 20),
                      snapThreshold: Nanoseconds(second / 10))
    #expect(model.edit.clips.first?.sourceEnd == Nanoseconds(3 * second))
    #expect(model.snapIndicator == Nanoseconds(3 * second), "and the line says where it snapped")
    model.commitTrim(edge: .end)
    #expect(model.snapIndicator == nil, "a finished drag leaves no line behind")
}

/// No threshold — ⌘ held — is the trim exactly as dragged.
@Test @MainActor func aTrimWithNoThresholdGoesExactlyWhereItWasDragged() throws {
    let model = TimelineEditorModel()
    model.load(duration: 10)
    model.movePlayhead(to: Nanoseconds(3 * second))
    let clip = try #require(model.edit.clips.first)
    model.previewTrim(of: clip.id, edge: .end, byNanoseconds: -(7 * second - second / 20),
                      snapThreshold: Nanoseconds(0))
    #expect(model.edit.clips.first?.sourceEnd == Nanoseconds(3 * second + second / 20))
}

/// **A small trim is possible.** The edge being dragged is not a target, so it cannot stick to
/// where it started and hold a trim of a few frames at zero.
@Test @MainActor func aSmallTrimIsNotHeldAtItsOwnStartingEdge() throws {
    let model = TimelineEditorModel()
    model.load(duration: 10)
    model.movePlayhead(to: Nanoseconds(2 * second))
    let clip = try #require(model.edit.clips.first)
    model.previewTrim(of: clip.id, edge: .end, byNanoseconds: -(second / 50),
                      snapThreshold: Nanoseconds(second / 10))
    #expect(model.edit.clips.first?.sourceEnd == Nanoseconds(10 * second - second / 50))
}

/// A zoom moved whole lines up by whichever end is nearer, and keeps its length doing so.
@Test @MainActor func aZoomMovedNearThePlayheadLinesUpByItsNearerEnd() throws {
    let epoch = BootEpoch(id: UUID(uuidString: "5E5E5E5E-6F6F-4A4A-8B8B-9C9C9C9C9C9C")!)
    let model = TimelineEditorModel()
    model.load(duration: 10)
    model.setZoomAnchor(EpochAnchor(epoch: epoch, hostTime: Nanoseconds(0), wallClockUnixNanos: 0))
    let target = FramingTarget(
        frame: NormalizedFrame(origin: NormalizedPoint(x: 0.4, y: 0.4),
                               size: NormalizedSize(width: 0.05, height: 0.05),
                               revision: GeometryRevision(id: 1)), role: "AXButton")
    let origin = HostInstant(epoch: epoch, hostTime: Nanoseconds(second))
    model.setDerivedZooms([ZoomBlock(origin: origin, start: origin,
                                     end: HostInstant(epoch: epoch, hostTime: Nanoseconds(2 * second)),
                                     target: target, zoom: 2)])
    model.movePlayhead(to: Nanoseconds(3 * second))

    // Dragged by 0.97 s: the end would land at 2.97 s, a hundredth short of the playhead.
    model.previewZoomMove(origin, byNanoseconds: 970_000_000, snapThreshold: Nanoseconds(second / 10))
    let moved = try #require(model.zooms.first)
    #expect(model.offset(of: moved.end) == Nanoseconds(3 * second), "its end lined up with the playhead")
    #expect(model.offset(of: moved.start) == Nanoseconds(2 * second), "and it kept its one-second length")
}
