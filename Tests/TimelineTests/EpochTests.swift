import Testing
import Foundation
@testable import Timeline

private let epochA = BootEpoch(id: UUID(uuidString: "6495B81D-14D1-4E05-8851-DD30BE41D757")!)
private let epochB = BootEpoch(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)

@Test func instantsInTheSameEpochCompare() {
    let early = HostInstant(epoch: epochA, hostTime: Nanoseconds(100))
    let late  = HostInstant(epoch: epochA, hostTime: Nanoseconds(200))
    #expect(early < late)
    #expect(!(late < early))
}

@Test func rangeContainsAnInstantOfItsOwnEpoch() {
    let r = HostRange(epoch: epochA, start: Nanoseconds(100), duration: Nanoseconds(50))
    #expect(r.contains(HostInstant(epoch: epochA, hostTime: Nanoseconds(120))))
    #expect(!r.contains(HostInstant(epoch: epochA, hostTime: Nanoseconds(150))))  // half-open
    #expect(r.end == Nanoseconds(150))
}

/// The point of the type. Two boots produce overlapping host times, and without
/// this guard a comparison between them succeeds and is wrong.
@Test func aRangeRejectsAnInstantFromAnotherEpoch() {
    let r = HostRange(epoch: epochA, start: Nanoseconds(100), duration: Nanoseconds(50))
    #expect(r.contains(HostInstant(epoch: epochB, hostTime: Nanoseconds(120))) == false)
    #expect(r.isComparable(with: HostInstant(epoch: epochB, hostTime: Nanoseconds(120))) == false)
}

/// Codable round trip, because these travel to disk in the observation log.
@Test func epochStampedValuesRoundTrip() throws {
    let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
    let r = HostRange(epoch: epochA, start: Nanoseconds(7), duration: Nanoseconds(11))
    let back = try JSONDecoder().decode(HostRange.self, from: try enc.encode(r))
    #expect(back == r)
    let a = EpochAnchor(epoch: epochA, hostTime: Nanoseconds(42), wallClockUnixNanos: 1_785_018_171_184_367_000)
    let backA = try JSONDecoder().decode(EpochAnchor.self, from: try enc.encode(a))
    #expect(backA == a)
}

/// Wall clock runs backwards under NTP correction, so it is not an ordering key.
/// Anchors are unordered by construction: there is no Comparable conformance to
/// reach for, which is the enforcement — a comment would not be.
@Test func anchorsCarryTheirEpochAndAreNotOrdered() {
    let a = EpochAnchor(epoch: epochA, hostTime: Nanoseconds(1), wallClockUnixNanos: 100)
    #expect(a.epoch == epochA)
    // There is deliberately no Comparable conformance, so there is nothing to
    // sort by. That is the enforcement — a runtime assertion could not express
    // it, and a comment would not hold. If someone adds Comparable later, this
    // test still passes and the doc comment on EpochAnchor is what stops them;
    // recorded here as a known limit rather than a check that looks like one.
}
