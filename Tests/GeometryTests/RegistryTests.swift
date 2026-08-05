import Testing
import Foundation
@testable import Geometry

private let displayA = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!

private func sample(width: Int) -> DisplayGeometry {
    DisplayGeometry(displayUUID: displayA, pixelWidth: width, pixelHeight: 100, scale: 1)
}

/// Pulls every `"id":<digits>` out of the raw JSON in document order. No
/// `DisplayGeometry` field is named `id`, so this only matches
/// `GeometryRevision.id`, without depending on `JSONEncoder`'s formatting.
private func extractRevisionIDs(from json: String) -> [UInt64] {
    var ids: [UInt64] = []
    var rest = Substring(json)
    let marker = "\"id\":"
    while let range = rest.range(of: marker) {
        rest = rest[range.upperBound...]
        let digits = rest.prefix { $0.isNumber }
        if let value = UInt64(digits) { ids.append(value) }
        rest = rest[digits.endIndex...]
    }
    return ids
}

// MARK: - insert / lookup

@Test func insertThenLookup() {
    var registry = GeometryRegistry()
    let geometry = sample(width: 100)
    registry.insert(geometry, observedAt: 42)
    #expect(registry.geometry(for: geometry.revision) == geometry)
    #expect(registry.firstObserved(for: geometry.revision) == 42)
    #expect(registry.revisions == [geometry.revision])
}

@Test func unknownRevisionLooksUpToNil() {
    let registry = GeometryRegistry()
    #expect(registry.geometry(for: GeometryRevision(id: 0)) == nil)
    #expect(registry.firstObserved(for: GeometryRevision(id: 0)) == nil)
}

/// First observation wins: re-inserting an identical geometry must not clobber
/// `firstObserved` with the later timestamp.
@Test func reinsertingKeepsTheFirstObservation() {
    var registry = GeometryRegistry()
    let geometry = sample(width: 100)
    registry.insert(geometry, observedAt: 10)
    registry.insert(geometry, observedAt: 999)
    #expect(registry.firstObserved(for: geometry.revision) == 10)
    #expect(registry.revisions.count == 1)
}

/// Identity is the geometry, not the event: two independently built registries
/// observing the same display configuration agree with no coordination.
@Test func twoRegistriesAgreeOnOneGeometry() {
    var r1 = GeometryRegistry()
    var r2 = GeometryRegistry()
    let geometry = sample(width: 100)
    r1.insert(geometry, observedAt: 1)
    r2.insert(geometry, observedAt: 2)
    #expect(r1.revisions == r2.revisions)
    #expect(r1.geometry(for: geometry.revision) == r2.geometry(for: geometry.revision))
}

// MARK: - Decoding untrusted input throws, never traps

/// A corrupt file is input, not program state: it must throw, never trap. The
/// JSON is well-formed but its stored `revision.id` does not match
/// `recompute(geometry).revision`.
@Test func decodingRejectsAMismatchedKey() throws {
    let json = Data("""
    [{"revision":{"id":1},"geometry":{"displayUUID":"6BA7B810-9DAD-11D1-80B4-00C04FD430C8","pixelWidth":100,"pixelHeight":100,"scale":1},"firstObserved":0}]
    """.utf8)
    #expect(throws: GeometryRegistry.DecodingFailure.self) {
        _ = try JSONDecoder().decode(GeometryRegistry.self, from: json)
    }
}

/// Same corrupt input, but inspecting *which* revision the failure names.
@Test func decodingFailureNamesTheOffendingRevision() {
    let json = Data("""
    [{"revision":{"id":1},"geometry":{"displayUUID":"6BA7B810-9DAD-11D1-80B4-00C04FD430C8","pixelWidth":100,"pixelHeight":100,"scale":1},"firstObserved":0}]
    """.utf8)
    do {
        _ = try JSONDecoder().decode(GeometryRegistry.self, from: json)
        Issue.record("expected decoding to throw")
    } catch let failure as GeometryRegistry.DecodingFailure {
        #expect(failure.revision == GeometryRevision(id: 1))
    } catch {
        Issue.record("expected DecodingFailure, got \(error)")
    }
}

/// A self-consistent document decodes cleanly.
@Test func decodingAcceptsAConsistentEntry() throws {
    var registry = GeometryRegistry()
    let geometry = sample(width: 100)
    registry.insert(geometry, observedAt: 7)
    let decoded = try JSONDecoder().decode(GeometryRegistry.self, from: JSONEncoder().encode(registry))
    #expect(decoded == registry)
    #expect(decoded.firstObserved(for: geometry.revision) == 7)
}

@Test func emptyRegistryRoundTrips() throws {
    let registry = GeometryRegistry()
    let decoded = try JSONDecoder().decode(GeometryRegistry.self, from: JSONEncoder().encode(registry))
    #expect(decoded == registry)
    #expect(decoded.revisions.isEmpty)
}

// MARK: - Canonical, sorted encoding

/// Entries appear in ascending `revision.id` order, which is what makes the
/// encoding independent of `Dictionary`'s per-process-random iteration order.
@Test func encodingIsStableAcrossProcesses() throws {
    var registry = GeometryRegistry()
    for i in 1...8 {
        registry.insert(sample(width: 100 * i), observedAt: Int64(i))
    }
    let encoded = try JSONEncoder().encode(registry)
    let text = String(decoding: encoded, as: UTF8.self)
    let ids = extractRevisionIDs(from: text)
    #expect(ids.count == 8, "expected 8 entries in the encoded document")
    #expect(ids == ids.sorted(), "entries must be encoded sorted by revision id")
}

/// Different insertion orders must converge on the same entry order. Only the
/// order is pinned here; identity itself is pinned in `DigestTests.swift`.
@Test func encodingOrderIsIndependentOfInsertionOrder() throws {
    var forward = GeometryRegistry()
    var backward = GeometryRegistry()
    let geometries = (1...6).map { sample(width: 100 * $0) }
    for g in geometries { forward.insert(g, observedAt: 0) }
    for g in geometries.reversed() { backward.insert(g, observedAt: 0) }

    let forwardIDs = extractRevisionIDs(from: String(decoding: try JSONEncoder().encode(forward), as: UTF8.self))
    let backwardIDs = extractRevisionIDs(from: String(decoding: try JSONEncoder().encode(backward), as: UTF8.self))
    #expect(forwardIDs == backwardIDs)
    #expect(forwardIDs == forwardIDs.sorted())
}
