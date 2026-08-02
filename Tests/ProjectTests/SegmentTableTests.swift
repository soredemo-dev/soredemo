import Testing
import Foundation
import Geometry
import Timeline
@testable import Project

private let ep = BootEpoch(id: UUID(uuidString: "6495B81D-14D1-4E05-8851-DD30BE41D757")!)
private let revA = GeometryRevision(id: 0xAAAA_0000_0000_0001)
private let revB = GeometryRevision(id: 0xBBBB_0000_0000_0002)

private func seg(_ i: Int, _ start: Int64, _ dur: Int64, _ rev: GeometryRevision,
                 _ end: SegmentBoundary) -> MasterSegment {
    MasterSegment(index: i, mediaFilename: "master-\(i).mov",
                  hostRange: HostRange(epoch: ep, start: Nanoseconds(start), duration: Nanoseconds(dur)),
                  revision: rev, endedBy: end)
}

@Test func contentTimeIsTheGaplessConcatenation() throws {
    // Real gaps: 1000..2000, then 5000..6500. Wall time between them is not content time.
    let t = try SegmentTable(segments: [
        seg(0, 1_000, 1_000, revA, .paused),
        seg(1, 5_000, 1_500, revA, .stopped),
    ])
    #expect(t.contentDuration == Nanoseconds(2_500))
    #expect(t.contentTime(of: HostInstant(epoch: ep, hostTime: Nanoseconds(1_500))) == Nanoseconds(500))
    // The first instant of segment 1 lands immediately after segment 0's content.
    #expect(t.contentTime(of: HostInstant(epoch: ep, hostTime: Nanoseconds(5_000))) == Nanoseconds(1_000))
}

/// An instant inside the gap belongs to no segment. Returning zero, or the
/// nearest edge, would be a plausible number for a question with no answer.
@Test func anInstantInsideAGapHasNoContentTime() throws {
    let t = try SegmentTable(segments: [seg(0, 1_000, 1_000, revA, .paused),
                                        seg(1, 5_000, 1_500, revA, .stopped)])
    #expect(t.contentTime(of: HostInstant(epoch: ep, hostTime: Nanoseconds(3_000))) == nil)
}

@Test func anInstantFromAnotherEpochHasNoContentTime() throws {
    let other = BootEpoch(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
    let t = try SegmentTable(segments: [seg(0, 1_000, 1_000, revA, .stopped)])
    #expect(t.contentTime(of: HostInstant(epoch: other, hostTime: Nanoseconds(1_500))) == nil)
}

@Test func aBoundaryCarriesWhyItHappened() throws {
    let t = try SegmentTable(segments: [
        seg(0, 1_000, 1_000, revA, .displayReconfigured(newRevision: revB)),
        seg(1, 3_000, 1_000, revB, .stopped),
    ])
    guard case .displayReconfigured(let newRev) = t.segments[0].endedBy else {
        Issue.record("expected a reconfiguration boundary"); return
    }
    #expect(newRev == revB)
    #expect(t.segments[1].revision == revB)
}

@Test func outOfOrderOrOverlappingSegmentsAreRejected() {
    #expect(throws: (any Error).self) {
        try SegmentTable(segments: [seg(1, 5_000, 100, revA, .stopped), seg(0, 1_000, 100, revA, .paused)])
    }
    #expect(throws: (any Error).self) {   // overlap
        try SegmentTable(segments: [seg(0, 1_000, 2_000, revA, .paused), seg(1, 2_000, 100, revA, .stopped)])
    }
}

@Test func aSnapshotWithSegmentsRoundTrips() throws {
    let t = try SegmentTable(segments: [seg(0, 1_000, 1_000, revA, .stopped)])
    let s = ProjectSnapshot(schemaVersion: 1, geometries: GeometryRegistry(),
                            mediaFilenames: ["master-0.mov"], segments: t)
    let back = try JSONDecoder().decode(ProjectSnapshot.self,
                                        from: try ProjectSnapshot.makeEncoder().encode(s))
    #expect(back == s)
}
