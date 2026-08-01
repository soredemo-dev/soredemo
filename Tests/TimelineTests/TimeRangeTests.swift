import Testing
import Foundation
@testable import Timeline

// MARK: - Nanoseconds — Comparable, Hashable, Codable

@Test func equalNanosecondsCompareEqual() {
    #expect(Nanoseconds(1_000) == Nanoseconds(1_000))
}

@Test func differentNanosecondsCompareUnequal() {
    #expect(Nanoseconds(1_000) != Nanoseconds(2_000))
}

@Test func nanosecondsOrderingIsComparable() {
    #expect(Nanoseconds(1) < Nanoseconds(2))
    #expect(!(Nanoseconds(2) < Nanoseconds(1)))
    #expect(Nanoseconds(2) > Nanoseconds(1))
    #expect(Nanoseconds(1) <= Nanoseconds(1))
    #expect(Nanoseconds(1) >= Nanoseconds(1))
}

@Test func nanosecondsSortCorrectly() {
    let unsorted: [Nanoseconds] = [Nanoseconds(300), Nanoseconds(100), Nanoseconds(200)]
    #expect(unsorted.sorted() == [Nanoseconds(100), Nanoseconds(200), Nanoseconds(300)])
}

@Test func nanosecondsRoundTripsThroughCodable() throws {
    let n = Nanoseconds(1_234_567_890)
    let decoded = try JSONDecoder().decode(Nanoseconds.self, from: JSONEncoder().encode(n))
    #expect(decoded == n)
}

@Test func nanosecondsExposesRawValue() {
    #expect(Nanoseconds(42).rawValue == 42)
}

// MARK: - TimeRange — end, contains, overlaps

@Test func endIsStartPlusDuration() {
    let r = TimeRange(start: Nanoseconds(100), duration: Nanoseconds(50))
    #expect(r.end == Nanoseconds(150))
}

// The half-open boundary, pinned so an off-by-one on either `contains` or
// `overlaps` cannot pass:

@Test func containsStartIsTrue() {
    let r = TimeRange(start: Nanoseconds(100), duration: Nanoseconds(50))
    #expect(r.contains(Nanoseconds(100)))
}

@Test func containsEndIsFalse() {
    let r = TimeRange(start: Nanoseconds(100), duration: Nanoseconds(50))
    #expect(!r.contains(Nanoseconds(150)))
}

@Test func containsOneBeforeEndIsTrue() {
    let r = TimeRange(start: Nanoseconds(100), duration: Nanoseconds(50))
    #expect(r.contains(Nanoseconds(149)))
}

@Test func containsBeforeStartIsFalse() {
    let r = TimeRange(start: Nanoseconds(100), duration: Nanoseconds(50))
    #expect(!r.contains(Nanoseconds(99)))
}

// A zero-duration range's [start, start) is empty by construction of
// half-openness — it contains nothing, not even `start` itself. This is
// intended, not a bug to "fix": a zero-duration range represents an instant
// with no extent, and half-open semantics make its containment set empty
// rather than a single point.
@Test func zeroDurationRangeContainsNothing() {
    let r = TimeRange(start: Nanoseconds(100), duration: Nanoseconds(0))
    #expect(!r.contains(Nanoseconds(100)))
    #expect(!r.contains(Nanoseconds(99)))
    #expect(!r.contains(Nanoseconds(101)))
}

// Touching ranges (a.end == b.start) must NOT overlap — this is the
// half-open contract `Graph.EvidenceRef.sourceInterval` relies on so two
// adjacent evidence intervals never both claim the same instant.
@Test func touchingRangesDoNotOverlap() {
    let a = TimeRange(start: Nanoseconds(0), duration: Nanoseconds(100))   // [0, 100)
    let b = TimeRange(start: Nanoseconds(100), duration: Nanoseconds(100)) // [100, 200)
    #expect(!a.overlaps(b))
    #expect(!b.overlaps(a))
}

@Test func rangesOverlappingBySingleNanosecondDoOverlap() {
    let a = TimeRange(start: Nanoseconds(0), duration: Nanoseconds(101))   // [0, 101)
    let b = TimeRange(start: Nanoseconds(100), duration: Nanoseconds(100)) // [100, 200)
    #expect(a.overlaps(b))
    #expect(b.overlaps(a))
}

@Test func identicalRangesOverlap() {
    let r = TimeRange(start: Nanoseconds(0), duration: Nanoseconds(100))
    #expect(r.overlaps(r))
}

@Test func disjointRangesDoNotOverlap() {
    let a = TimeRange(start: Nanoseconds(0), duration: Nanoseconds(50))
    let b = TimeRange(start: Nanoseconds(200), duration: Nanoseconds(50))
    #expect(!a.overlaps(b))
    #expect(!b.overlaps(a))
}

@Test func timeRangeRoundTripsThroughCodable() throws {
    let r = TimeRange(start: Nanoseconds(10), duration: Nanoseconds(20))
    let decoded = try JSONDecoder().decode(TimeRange.self, from: JSONEncoder().encode(r))
    #expect(decoded == r)
}

@Test func equalTimeRangesCompareEqual() {
    #expect(TimeRange(start: Nanoseconds(1), duration: Nanoseconds(2))
            == TimeRange(start: Nanoseconds(1), duration: Nanoseconds(2)))
}
