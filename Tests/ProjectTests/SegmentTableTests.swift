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

/// The two-segment fixture above cannot separate three readings of
/// `contentDuration`/`contentTime`'s accumulator: with one step, "sum of
/// all preceding durations", "the previous duration alone", and "the first
/// duration" are indistinguishable numbers. Three distinctly-sized segments
/// with two DIFFERENTLY-sized gaps between them (1_300 and 5_700 — not the
/// same size, so a mutation that used a fixed or averaged gap would also
/// be caught) separates all three: `contentDuration` must be the full sum,
/// and `contentTime` at the start of segment 2 must be `d0 + d1`, not `d1`
/// alone or `d0` alone.
@Test func threeSegmentsSeparateTheSumFromThePriorFromTheFirst() throws {
    let t = try SegmentTable(segments: [
        seg(0, 1_000, 700, revA, .paused),    // d0 = 700,  content 1_000..1_700
        seg(1, 3_000, 300, revA, .paused),    // d1 = 300,  content 3_000..3_300 (gap 1_300)
        seg(2, 9_000, 900, revA, .stopped),   // d2 = 900,  content 9_000..9_900 (gap 5_700)
    ])
    #expect(t.contentDuration == Nanoseconds(700 + 300 + 900))
    #expect(t.contentTime(of: HostInstant(epoch: ep, hostTime: Nanoseconds(9_000))) == Nanoseconds(700 + 300))
}

/// An instant inside the gap belongs to no segment. Returning zero, or the
/// nearest edge, would be a plausible number for a question with no answer.
@Test func anInstantInsideAGapHasNoContentTime() throws {
    let t = try SegmentTable(segments: [seg(0, 1_000, 1_000, revA, .paused),
                                        seg(1, 5_000, 1_500, revA, .stopped)])
    #expect(t.contentTime(of: HostInstant(epoch: ep, hostTime: Nanoseconds(3_000))) == nil)
}

/// What this uniquely pins: `SegmentTable.contentTime` asks `HostRange`
/// whether the instant falls inside it — `s.hostRange.contains(instant)` —
/// rather than doing a raw `hostTime` comparison itself. It is
/// `HostRange.contains`'s own epoch guard (`isComparable(with:)`,
/// `HostRange.swift`) that produces `nil` here, not any epoch check written
/// in this file. `SegmentTable` DOES own epoch logic — `init(segments:)`'s
/// `mixedEpochs` check refuses to construct a table spanning two epochs at
/// all — but that is a different guard at a different point (construction,
/// not lookup), covered by `segmentsFromDifferentEpochsAreRejected` below,
/// not by this test. A reader tempted to conclude from this one test that
/// `SegmentTable` validates epochs should look there instead.
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

/// Asserts the specific case and index, not merely "an error": `outOfOrder`
/// and `overlapping` are both reachable from a two-segment array, and a
/// mutation that swapped which one fires (or reported the wrong index)
/// would survive `#expect(throws: (any Error).self)` — the type is
/// `Equatable` precisely so a caller, and this test, can tell them apart.
@Test func outOfOrderSegmentsAreRejectedWithTheirIndex() {
    do {
        _ = try SegmentTable(segments: [seg(1, 5_000, 100, revA, .stopped), seg(0, 1_000, 100, revA, .paused)])
        Issue.record("expected SegmentTableError.outOfOrder to be thrown")
    } catch let error as SegmentTableError {
        #expect(error == .outOfOrder(0))
    } catch {
        Issue.record("expected SegmentTableError, got \(error)")
    }
}

/// See `outOfOrderSegmentsAreRejectedWithTheirIndex` — same reasoning.
@Test func overlappingSegmentsAreRejectedWithTheirIndex() {
    do {
        _ = try SegmentTable(segments: [seg(0, 1_000, 2_000, revA, .paused), seg(1, 2_000, 100, revA, .stopped)])
        Issue.record("expected SegmentTableError.overlapping to be thrown")
    } catch let error as SegmentTableError {
        #expect(error == .overlapping(1))
    } catch {
        Issue.record("expected SegmentTableError, got \(error)")
    }
}

/// `init(segments:)`'s third check, uncovered until now: two segments that
/// agree on order and don't overlap in host time can still disagree on
/// WHICH boot session that host time belongs to — comparing them at all
/// would be meaningless (D2-11). `SegmentTable` is the one place that
/// guards this at construction, once, rather than asking `contentTime`
/// to re-ask it per lookup (see the comment on
/// `anInstantFromAnotherEpochHasNoContentTime`, which pins the opposite
/// case — HostRange's own per-call guard, not this one).
@Test func segmentsFromDifferentEpochsAreRejected() {
    let other = BootEpoch(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
    let foreignSegment = MasterSegment(
        index: 1, mediaFilename: "master-1.mov",
        hostRange: HostRange(epoch: other, start: Nanoseconds(5_000), duration: Nanoseconds(1_000)),
        revision: revA, endedBy: .stopped)
    do {
        _ = try SegmentTable(segments: [seg(0, 1_000, 1_000, revA, .stopped), foreignSegment])
        Issue.record("expected SegmentTableError.mixedEpochs to be thrown")
    } catch let error as SegmentTableError {
        #expect(error == .mixedEpochs)
    } catch {
        Issue.record("expected SegmentTableError, got \(error)")
    }
}

/// `init(segments:)` rejects `start < prev.end` — strictly less than. Two
/// segments touching exactly at the boundary (`start == prev.end`) must be
/// legal: a pause immediately followed by resume produces exactly this
/// shape, and rejecting it would make every ordinary pause/resume table
/// fail to construct. A mutation from `<` to `<=` would break this
/// silently — nothing else in this file constructs a touching pair.
@Test func contiguousSegmentsTouchingAtTheBoundaryAreAccepted() throws {
    let t = try SegmentTable(segments: [
        seg(0, 1_000, 1_000, revA, .paused),  // 1_000..2_000
        seg(1, 2_000, 500, revA, .stopped),   // 2_000..2_500 — touches, does not overlap
    ])
    #expect(t.segments.count == 2)
}

/// `.paused`/`.stopped`, used everywhere else in this file, carry no
/// payload — they are the identity element for "does the associated value
/// survive encoding," so a fixture built only from them would round-trip
/// whether or not `SegmentBoundary`'s payload-bearing cases decode
/// correctly at all. `.displayReconfigured(newRevision:)` and
/// `.failed(reason:)` are `SegmentBoundary`'s actual reason to exist —
/// "gaps are records, not absences" means the payload IS the record.
@Test func segmentBoundaryPayloadsSurviveEncodeDecode() throws {
    let t = try SegmentTable(segments: [
        seg(0, 1_000, 500, revA, .displayReconfigured(newRevision: revB)),
        seg(1, 2_000, 500, revB, .failed(reason: "capture stream stopped unexpectedly")),
    ])
    let data = try JSONEncoder().encode(t)
    let decoded = try JSONDecoder().decode(SegmentTable.self, from: data)
    #expect(decoded == t)
    guard case .displayReconfigured(let newRev) = decoded.segments[0].endedBy else {
        Issue.record("expected .displayReconfigured to survive the round trip"); return
    }
    #expect(newRev == revB)
    guard case .failed(let reason) = decoded.segments[1].endedBy else {
        Issue.record("expected .failed(reason:) to survive the round trip"); return
    }
    #expect(reason == "capture stream stopped unexpectedly")
}

/// The Critical finding: synthesised `Decodable` for a single-property
/// struct assigns `segments` directly and never calls the validating
/// `init(segments:)` — so a decoded table could carry an overlap
/// `init(segments:)` exists specifically to refuse, and every derived
/// value (`contentDuration`, `contentTime`) would compute a plausible,
/// wrong answer from it in silence. This decodes a JSON array literal —
/// not a table encoded from real `MasterSegment` values and re-decoded,
/// because THAT route is closed: `init(segments:)` would refuse to
/// construct an overlapping table in memory to begin with, so encoding one
/// is impossible from inside this package. Reaching an overlapping pair
/// requires going around the validating initialiser entirely, which is
/// exactly the route untrusted disk data takes. The literal's shape was
/// confirmed once against this package's own `JSONEncoder` output for the
/// same field values (matching key names, nested-container shapes for
/// `SegmentBoundary`, `HostRange`, `BootEpoch`, `Nanoseconds`, and
/// `GeometryRevision`), then hand-transcribed here — not generated by a
/// helper that itself depends on the code under test.
///
/// Asserts `.dataCorrupted` specifically, not merely "a `DecodingError`":
/// a `JSONDecoder().decode(SegmentTable.self, …)` that hit a wire-shape
/// mismatch instead (e.g. a build that reverted to synthesised `Codable`,
/// which would expect a keyed `{"segments":[...]}` rather than this bare
/// array) *also* throws a `DecodingError` — `.typeMismatch`, confirmed by
/// running exactly that reversion against this fixture — and a bare
/// `catch is DecodingError` would pass on that wrong-for-an-unrelated-
/// reason code without ever exercising `init(segments:)`'s overlap check
/// at all. `.dataCorrupted` is the specific case `SegmentTable.init(from:)`
/// wraps a validation failure in, so only that case is proof the overlap
/// was actually caught.
@Test func decodingAnOverlappingSegmentTableThrows() throws {
    let json = Data("""
    [
      {"index":0,"mediaFilename":"master-0.mov","revision":{"id":12297641732488560641},
       "hostRange":{"epoch":{"id":"6495B81D-14D1-4E05-8851-DD30BE41D757"},
                    "start":{"rawValue":1000},"duration":{"rawValue":2000}},
       "endedBy":{"paused":{}}},
      {"index":1,"mediaFilename":"master-1.mov","revision":{"id":12297641732488560641},
       "hostRange":{"epoch":{"id":"6495B81D-14D1-4E05-8851-DD30BE41D757"},
                    "start":{"rawValue":1500},"duration":{"rawValue":100}},
       "endedBy":{"stopped":{}}}
    ]
    """.utf8)
    do {
        _ = try JSONDecoder().decode(SegmentTable.self, from: json)
        Issue.record("expected decoding an overlapping segment table to throw")
    } catch let error as DecodingError {
        guard case .dataCorrupted = error else {
            Issue.record("expected .dataCorrupted (SegmentTable's own validation wrapper), got \(error)")
            return
        }
    } catch {
        Issue.record("expected DecodingError, got \(error)")
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
