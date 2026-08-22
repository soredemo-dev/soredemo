import Testing
import Foundation
@testable import Graph

// MARK: - Fixtures
//
// Deliberately NOT at `ReferenceProducer`'s identity element (AGENTS.md, "every
// fixture set needs a non-identity value for every transform applied to it"):
// the producer counts evidence, so no fixture here has exactly 99 items — the
// authored value under test throughout this file. If one did, the
// producer-value rule's test would pass whether or not the guard in
// `applyingProduced` existed at all, which is exactly the failure mode the
// rule's test form exists to rule out.
//
// IDs are built from `UUID(uuid:)` over an injected byte, never `UUID()` —
// this package bans ambient randomness (§ Determinism), and the architecture
// check enforces it at link time.

private func digest(_ seed: UInt8) -> ContentDigest {
    ContentDigest(Array(repeating: seed, count: ContentDigest.byteCount))
}

private func evidenceRef(_ seed: UInt8) -> EvidenceRef {
    EvidenceRef(
        kind: .observation,
        id: UUID(uuid: (seed, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
        contentDigest: digest(seed))
}

/// `count` distinct refs, numbered from 1 so the zero seed (an all-zero UUID
/// and digest) is never used.
private func evidence(count: Int) throws -> Evidence {
    try #require(Evidence((1...count).map { evidenceRef(UInt8($0)) }))
}

// MARK: - The producer derives from its evidence

@Test func producerDerivesFromItsEvidence() throws {
    let produced = ReferenceProducer.produce(from: try evidence(count: 3))
    #expect(produced.value == 3)
    guard case .generated(let derivation) = produced.origin else {
        Issue.record("expected .generated"); return
    }
    #expect(derivation.producer == ReferenceProducer.id)
    #expect(derivation.evidence.count == 3)
}

@Test func producerCitesExactlyTheEvidenceItCounted() throws {
    let cited = try evidence(count: 4)
    let produced = ReferenceProducer.produce(from: cited)
    guard case .generated(let derivation) = produced.origin else {
        Issue.record("expected .generated"); return
    }
    #expect(Array(derivation.evidence) == Array(cited))
}

// MARK: - The producer-value rule
//
// The mandatory test form (AGENTS.md, task-14 brief): supply a value the
// producer could not have derived, then apply a production over it and
// assert the supplied value wins. `ReferenceProducer` counts evidence, so 99
// qualifies only as long as no fixture in this file has 99 items — see the
// fixtures note above.

@Test func authoredValueSurvivesTheProducer() throws {
    let authored = Derived(value: 99, origin: .authored(Authorship(note: "operator override")),
                           review: .approved)
    let produced = ReferenceProducer.produce(from: try evidence(count: 3))
    let result = authored.applyingProduced(produced)
    #expect(result.value == 99)                                    // producer counts evidence; it can never yield 99
    guard case .authored = result.origin else { Issue.record("origin replaced"); return }
    #expect(result.review == .approved)                            // the human decision must survive too
}

// MARK: - A generated value IS replaced
//
// The rule protects authored values only. If generated values were also
// immune, a re-derivation would never take effect and the producer would be
// pointless.

@Test func aGeneratedValueIsReplacedByFreshProduction() throws {
    var existing = ReferenceProducer.produce(from: try evidence(count: 2))
    existing.review = .rejected
    let fresh = ReferenceProducer.produce(from: try evidence(count: 5))
    let result = existing.applyingProduced(fresh)
    #expect(result.value == 5)
    guard case .generated(let derivation) = result.origin else {
        Issue.record("expected .generated"); return
    }
    #expect(derivation.evidence.count == 5)
    // The bytes actually changed (2 refs -> 5 refs), so the prior review does
    // not describe what is there now — same rule `applyingProduced` already
    // enforces, exercised here through the real producer.
    #expect(result.review == .pending)
}

// MARK: - Repeated production does not erode the override
//
// A guard that holds on the first re-run but leaks on a later one is the
// realistic failure — five successive productions, each with a different
// evidence count, none of which is 99.

@Test func repeatedProductionDoesNotErodeTheOverride() throws {
    var result = Derived(value: 99, origin: .authored(Authorship(note: "operator override")),
                         review: .rejected)
    for count in [1, 2, 3, 4, 5] {
        result = result.applyingProduced(ReferenceProducer.produce(from: try evidence(count: count)))
    }
    #expect(result.value == 99)
    guard case .authored = result.origin else { Issue.record("origin replaced after repeated production"); return }
    #expect(result.review == .rejected)
}
