import Testing
import Foundation
@testable import Graph

// MARK: - Fixtures
//
// Every property AGENTS.md requires of a fixture set for this transform
// (§ "Every fixture set needs a non-identity value for every transform
// applied to it"):
//
// - `nodeA` cites TWO evidence refs (`ref1`, `ref2`) — a single-ref fixture
//   cannot distinguish "indexes the head" from "indexes all of them".
// - `nodeA` and `nodeC` both cite `ref1` — so `dependents(of:)` returning a
//   *set*, not a single node, is actually exercised.
// - `nodeB` is `.authored` and cites nothing — tested against a populated
//   index, not an empty one.
// - `rebuildAfterInvalidationReflectsNewEdges` rebuilds from an edge set
//   disjoint from the first (`ref3`/`nodeD`), so a merge-instead-of-replace
//   bug shows up: overlapping edges would pass either way.
//
// IDs are built from `UUID(uuid:)` over injected bytes, never `UUID()` —
// this package bans ambient randomness (§ Determinism).

private func digest(_ seed: UInt8) -> ContentDigest {
    ContentDigest(Array(repeating: seed, count: ContentDigest.byteCount))
}

private func evidenceRef(_ seed: UInt8) -> EvidenceRef {
    EvidenceRef(
        kind: .observation,
        id: UUID(uuid: (seed, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
        contentDigest: digest(seed))
}

private func nodeID(_ seed: UInt8) -> NodeID {
    NodeID(rawValue: UUID(uuid: (0, seed, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
}

private func generatedEntry(_ node: UInt8, citing refs: EvidenceRef...) throws -> ReverseIndex.Entry {
    let evidence = try #require(Evidence(refs))
    return ReverseIndex.Entry(node: nodeID(node), origin: .generated(Derivation(
        producer: ProducerID("test-producer"),
        producerVersion: 1,
        evidence: evidence,
        outcome: .accepted)))
}

private func authoredEntry(_ node: UInt8) -> ReverseIndex.Entry {
    ReverseIndex.Entry(node: nodeID(node), origin: .authored(Authorship(note: "authored fixture")))
}

private let ref1 = evidenceRef(1)
private let ref2 = evidenceRef(2)

/// `nodeA` cites `{ref1, ref2}`; `nodeC` also cites `{ref1}` — the same
/// evidence as `nodeA`; `nodeB` is authored and cites nothing.
private func populatedFixture() throws -> [ReverseIndex.Entry] {
    [
        try generatedEntry(0xA, citing: ref1, ref2),
        authoredEntry(0xB),
        try generatedEntry(0xC, citing: ref1),
    ]
}

// MARK: - Before any rebuild

@Test func dependentsIsEmptyBeforeAnyRebuild() {
    let index = ReverseIndex()
    #expect(index.isCurrent == false)
    #expect(index.dependents(of: ref1.id).isEmpty)
}

// MARK: - Cache hit / invalidation pairing (AGENTS.md: "Cache invalidation pairing")

@Test func cacheHitAfterRebuild() throws {
    var index = ReverseIndex()
    index.rebuild(from: try populatedFixture())
    #expect(index.isCurrent)
    #expect(index.dependents(of: ref1.id) == [nodeID(0xA), nodeID(0xC)])
    #expect(index.dependents(of: ref2.id) == [nodeID(0xA)])
}

@Test func invalidationClearsTheCache() throws {
    var index = ReverseIndex()
    index.rebuild(from: try populatedFixture())
    index.invalidate()
    #expect(index.isCurrent == false)
    // Not "fewer entries" -- nothing. A stale answer would silently
    // under-invalidate, which is the failure mode that matters here.
    #expect(index.dependents(of: ref1.id).isEmpty)
    #expect(index.dependents(of: ref2.id).isEmpty)
}

@Test func rebuildAfterInvalidationReflectsNewEdges() throws {
    var index = ReverseIndex()
    index.rebuild(from: try populatedFixture())
    index.invalidate()

    // Disjoint from the first fixture's edges: nodeD cites ref3, which
    // nothing in `populatedFixture()` touches. A merge-instead-of-replace
    // bug would leave ref1/ref2 still answering as before; a correct
    // replace answers only for ref3.
    let ref3 = evidenceRef(3)
    let nodeD = nodeID(0xD)
    index.rebuild(from: [try generatedEntry(0xD, citing: ref3)])

    #expect(index.isCurrent)
    #expect(index.dependents(of: ref3.id) == [nodeD])
    #expect(index.dependents(of: ref1.id).isEmpty)
    #expect(index.dependents(of: ref2.id).isEmpty)
}

// MARK: - A node citing more than one evidence ref

@Test func nodeCitingMultipleEvidenceRefsAppearsUnderEachOne() throws {
    var index = ReverseIndex()
    index.rebuild(from: try populatedFixture())
    #expect(index.dependents(of: ref1.id).contains(nodeID(0xA)))
    #expect(index.dependents(of: ref2.id).contains(nodeID(0xA)))
}

// MARK: - Two nodes citing the same evidence

@Test func twoNodesCitingTheSameEvidenceBothAppear() throws {
    var index = ReverseIndex()
    index.rebuild(from: try populatedFixture())
    let dependents = index.dependents(of: ref1.id)
    #expect(dependents.count == 2)
    #expect(dependents.contains(nodeID(0xA)))
    #expect(dependents.contains(nodeID(0xC)))
}

// MARK: - Authored nodes contribute no edges

@Test func authoredNodeContributesNoEdges() throws {
    var index = ReverseIndex()
    index.rebuild(from: try populatedFixture())
    // nodeB is .authored in the fixture and cites nothing: it must not
    // appear under ref1 or ref2, the only evidence the fixture actually
    // cites, even though the index is populated (not empty).
    #expect(!index.dependents(of: ref1.id).contains(nodeID(0xB)))
    #expect(!index.dependents(of: ref2.id).contains(nodeID(0xB)))
}

// MARK: - Evidence nothing cites

@Test func dependentsOfUncitedEvidenceIsEmpty() throws {
    var index = ReverseIndex()
    index.rebuild(from: try populatedFixture())
    #expect(index.dependents(of: evidenceRef(99).id).isEmpty)
}
