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

/// Two boots produce overlapping host times, so without this guard a comparison
/// between them succeeds and is wrong.
@Test func aRangeRejectsAnInstantFromAnotherEpoch() {
    let r = HostRange(epoch: epochA, start: Nanoseconds(100), duration: Nanoseconds(50))
    #expect(r.contains(HostInstant(epoch: epochB, hostTime: Nanoseconds(120))) == false)
    #expect(r.isComparable(with: HostInstant(epoch: epochB, hostTime: Nanoseconds(120))) == false)
}

/// Untrusted input must not bypass `init`'s negative-duration check. The JSON is
/// hand-built because `init` traps before such a value could be encoded.
/// `.dataCorrupted` specifically: a bare `precondition` would trap instead of
/// throw, and synthesised `Codable` would not throw at all.
@Test func decodingANegativeDurationHostRangeThrows() throws {
    let json = Data("""
    {"epoch":{"id":"6495B81D-14D1-4E05-8851-DD30BE41D757"},
     "start":{"rawValue":1000},"duration":{"rawValue":-1}}
    """.utf8)
    do {
        _ = try JSONDecoder().decode(HostRange.self, from: json)
        Issue.record("expected decoding a negative-duration HostRange to throw")
    } catch let error as DecodingError {
        guard case .dataCorrupted = error else {
            Issue.record("expected .dataCorrupted (HostRange's own validation), got \(error)")
            return
        }
    } catch {
        Issue.record("expected DecodingError, got \(error)")
    }
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

/// Wall clock runs backwards under NTP correction, so it is not an ordering key;
/// the absence of a Comparable conformance is the enforcement.
@Test func anchorsCarryTheirEpochAndAreNotOrdered() {
    let a = EpochAnchor(epoch: epochA, hostTime: Nanoseconds(1), wallClockUnixNanos: 100)
    #expect(a.epoch == epochA)
    // Known limit: adding Comparable later would not redden this test.
}

/// The ONE composition-offset → host-instant conversion. `1a98402` happened at a
/// caller doing this addition by hand on two bare `Nanoseconds`; the anchor doing
/// it returns a value that carries its domain, which is what lets the track
/// queries refuse a bare number at compile time.
@Test func anAnchorConvertsACompositionOffsetIntoItsOwnEpoch() {
    let a = EpochAnchor(epoch: epochA, hostTime: Nanoseconds(1_000), wallClockUnixNanos: 100)
    let instant = a.instant(atOffset: Nanoseconds(250))
    #expect(instant == HostInstant(epoch: epochA, hostTime: Nanoseconds(1_250)))
}

/// Offset zero is the anchor itself — the identity is stated because every other
/// fixture here uses a non-identity value, per the fixture rule.
@Test func anAnchorAtOffsetZeroIsTheAnchorInstant() {
    let a = EpochAnchor(epoch: epochB, hostTime: Nanoseconds(42), wallClockUnixNanos: 7)
    #expect(a.instant(atOffset: Nanoseconds(0))
            == HostInstant(epoch: epochB, hostTime: Nanoseconds(42)))
}
