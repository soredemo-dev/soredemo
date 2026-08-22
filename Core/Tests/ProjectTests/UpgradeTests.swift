import Testing
import Foundation
@testable import Project
import Geometry
import Timeline

// MARK: - Fixtures
//
// AGENTS.md: every fixture set needs a non-identity value for every
// transform applied to it.
//
// - Two entries with DIFFERENT revisions, so a round trip that silently
//   dropped an entry would be caught (an empty or single-entry registry
//   round-trips fine even if a broken encoder loses entries). This does NOT
//   cover array order: `GeometryRegistry.Equatable` compares the underlying
//   dictionaries, so a decode that silently reordered the encoded array
//   would still compare `==` here — order is `GeometryRegistry`'s own
//   contract, pinned by its own tests (`RegistryTests.swift`), not this
//   file's business.
// - One `DisplayGeometry` with `scale: 2` — `scale: 1` is the identity that
//   once hid a real points↔pixels bug.
// - `mediaFilenames` deliberately NOT in sorted order, so round-trip proves
//   order is preserved rather than coincidentally reproduced.

private let displayA = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!
private let displayB = UUID(uuidString: "F47AC10B-58CC-4372-A567-0E02B2C3D479")!
private let bootEpoch = BootEpoch(id: UUID(uuidString: "9E107D9D-372B-4826-9D9D-2A1F4E7A6D9A")!)

private func richRegistry() -> GeometryRegistry {
    var registry = GeometryRegistry()
    registry.insert(DisplayGeometry(displayUUID: displayA, pixelWidth: 3840, pixelHeight: 2160, scale: 2), observedAt: 100)
    registry.insert(DisplayGeometry(displayUUID: displayB, pixelWidth: 2560, pixelHeight: 1440, scale: 1), observedAt: 200)
    return registry
}

private let segmentRevA = GeometryRevision(id: 0x1111_0000_0000_0001)
private let segmentRevB = GeometryRevision(id: 0x2222_0000_0000_0002)

/// Non-empty, per the fixture rule: `SegmentTable.empty` is the identity
/// value for this field, so a `richSnapshot()` that carried the empty table
/// would round-trip whether or not `ProjectSnapshot`'s new `segments` field
/// actually encoded and decoded correctly. Two DIFFERENT revisions — a
/// single shared revision is the identity of "does the boundary's
/// `newRevision` payload actually get carried forward and matched to the
/// next segment's own `revision`", exactly the mistake the `scale: 1`
/// entry in `AGENTS.md`'s fixture table warns about, one field over.
/// `endedBy: .displayReconfigured(newRevision:)` rather than `.paused` for
/// the same reason: `.paused`/`.stopped` carry no associated value, so a
/// round trip that silently dropped `SegmentBoundary`'s payload would pass
/// unnoticed with either of them. The two
/// segments touch exactly at the boundary — "close together" is the
/// realistic shape for a reconfiguration-forced file split, immediately
/// closing one segment and opening the next with no capture gap.
private func richSegments() throws -> SegmentTable {
    try SegmentTable(segments: [
        MasterSegment(index: 0, mediaFilename: "clip-01.mov",
                      hostRange: HostRange(epoch: bootEpoch, start: Nanoseconds(1_000), duration: Nanoseconds(1_000)),
                      revision: segmentRevA, endedBy: .displayReconfigured(newRevision: segmentRevB)),
        MasterSegment(index: 1, mediaFilename: "clip-02.mov",
                      hostRange: HostRange(epoch: bootEpoch, start: Nanoseconds(2_000), duration: Nanoseconds(1_500)),
                      revision: segmentRevB, endedBy: .stopped),
    ])
}

private func richSnapshot() throws -> ProjectSnapshot {
    ProjectSnapshot(
        schemaVersion: ProjectSnapshot.currentSchemaVersion,
        geometries: richRegistry(),
        mediaFilenames: ["clip-03.mov", "clip-01.mov", "clip-02.mov"],
        segments: try richSegments()
    )
}

// MARK: - ProjectSnapshot: round trip and encoding determinism

@Test func currentSchemaVersionIsOne() {
    #expect(ProjectSnapshot.currentSchemaVersion == 1)
}

@Test func roundTripPreservesAllFields() throws {
    let snapshot = try richSnapshot()
    let data = try ProjectSnapshot.makeEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(ProjectSnapshot.self, from: data)
    #expect(decoded == snapshot)
}

@Test func roundTripPreservesMediaFilenameOrder() throws {
    let snapshot = try richSnapshot()
    let data = try ProjectSnapshot.makeEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(ProjectSnapshot.self, from: data)
    #expect(decoded.mediaFilenames == ["clip-03.mov", "clip-01.mov", "clip-02.mov"])
}

/// `.sortedKeys` is mandatory on every encoder whose output must be
/// deterministic across processes (design § Canonical encoding point 0):
/// plain `JSONEncoder` was measured producing five distinct byte sequences
/// across five processes for a struct array with no dictionary at all.
/// `ProjectSnapshot` is not digested, but an encoder that varies its output
/// makes every future diff and "did this change?" question unanswerable.
@Test func topLevelKeysEncodeInSortedOrder() throws {
    let data = try ProjectSnapshot.makeEncoder().encode(try richSnapshot())
    let text = String(decoding: data, as: UTF8.self)
    let g = try #require(text.range(of: "\"geometries\""))
    let m = try #require(text.range(of: "\"mediaFilenames\""))
    let s = try #require(text.range(of: "\"schemaVersion\""))
    // "segments" is asserted too: a hand-written
    // `Codable` (`ProjectSnapshot.encode(to:)`) is exactly
    // the place a key can be emitted out of position — synthesis can't get
    // key order wrong on its own, but a hand-written `container.encode(...,
    // forKey:)` call sequence can, and `.sortedKeys` is what recovers from
    // that regardless of call order. "schemaVersion" < "segments"
    // alphabetically ('c' < 'e' at the fourth character), so it belongs
    // last of these four.
    let e = try #require(text.range(of: "\"segments\""))
    #expect(g.lowerBound < m.lowerBound)
    #expect(m.lowerBound < s.lowerBound)
    #expect(s.lowerBound < e.lowerBound)
}

/// Design § Canonical encoding point 2: `ProjectSnapshot.schemaVersion` (the
/// document version) and `CanonicalEncoding.version` (the digest version)
/// must never be derived one from the other — a document schema upgrade
/// must leave existing approvals verifiable.
///
/// What this test actually establishes, and no more: both constants equal
/// `1` today. It does NOT prove they are independent — the two assertions
/// below would both still pass if `currentSchemaVersion` were rewritten as
/// `Int(CanonicalEncoding.version)`, because the values coincide. Two
/// constants that happen to be equal is the one case a value-pinning test
/// cannot distinguish from a coupled one; catching an actual coupling is a
/// code-review invariant (there is no `Int(CanonicalEncoding.version)`
/// anywhere in `ProjectSnapshot`), not something this test can detect on
/// its own. It is named for what it pins, not for a guarantee it cannot
/// make.
@Test func documentSchemaVersionAndCanonicalEncodingVersionArePinnedAsSeparateConstants() {
    #expect(ProjectSnapshot.currentSchemaVersion == 1)
    #expect(CanonicalEncoding.version == 1)
}

// MARK: - SchemaProbe: reads the version without decoding the document

@Test func probeReadsVersionOfAWellFormedV1Document() throws {
    let data = try ProjectSnapshot.makeEncoder().encode(try richSnapshot())
    #expect(try SchemaProbe.version(of: data) == 1)
}

/// The entire reason `SchemaProbe` exists: it must succeed on a document
/// that is NOT decodable as a full `ProjectSnapshot`. Here `geometries` and
/// `mediaFilenames` — both required, non-optional fields — are absent, and
/// an unknown key from a hypothetical future build is present instead. A
/// probe that decoded into `ProjectSnapshot` and read `.schemaVersion` off
/// it would throw a `DecodingError` on this input; the minimal-struct probe
/// must not.
@Test func probeReadsVersionWithoutRequiringTheRestOfTheDocumentToDecode() throws {
    let data = Data("""
    {"schemaVersion":1,"aFieldFromAFutureBuild":"opaque"}
    """.utf8)
    #expect(try SchemaProbe.version(of: data) == 1)
}

/// Asserts the specific case, not merely the error type: `ProjectFormatError`
/// has three cases, and `#expect(throws: ProjectFormatError.self)` alone
/// would also pass for `.tooNew` or `.unsupportedLegacyVersion` — so a probe
/// that returned the wrong case here would go undetected under that form.
@Test func probeThrowsMalformedWhenSchemaVersionIsAbsent() {
    let data = Data("""
    {"geometries":[],"mediaFilenames":[]}
    """.utf8)
    do {
        _ = try SchemaProbe.version(of: data)
        Issue.record("expected ProjectFormatError.malformed to be thrown")
    } catch let error as ProjectFormatError {
        guard case .malformed = error else {
            Issue.record("expected .malformed, got \(error)")
            return
        }
    } catch {
        Issue.record("expected ProjectFormatError, got \(error)")
    }
}

/// See `probeThrowsMalformedWhenSchemaVersionIsAbsent` — same reasoning for
/// asserting the case rather than only the error type.
@Test func probeThrowsMalformedOnInvalidJSON() {
    let data = Data("not json".utf8)
    do {
        _ = try SchemaProbe.version(of: data)
        Issue.record("expected ProjectFormatError.malformed to be thrown")
    } catch let error as ProjectFormatError {
        guard case .malformed = error else {
            Issue.record("expected .malformed, got \(error)")
            return
        }
    } catch {
        Issue.record("expected ProjectFormatError, got \(error)")
    }
}

// MARK: - ProjectUpgrade: v0 migrates, v1 decodes, future throws

@Test func loadDecodesAWellFormedV1DocumentDirectly() throws {
    let snapshot = try richSnapshot()
    let data = try ProjectSnapshot.makeEncoder().encode(snapshot)
    let loaded = try ProjectUpgrade.load(data)
    #expect(loaded == snapshot)
}

/// v0 is synthetic (Controller addendum ruling 4): v1 without
/// `mediaFilenames`. The fixture's `geometries` is non-empty so this test
/// fails whether the migration drops the registry OR carries it forward
/// wrongly — an empty-geometries v0 fixture would pass either way.
@Test func loadMigratesASyntheticV0DocumentInsertingEmptyMediaFilenames() throws {
    let registry = richRegistry()
    let registryData = try JSONEncoder().encode(registry)
    let registryJSON = String(decoding: registryData, as: UTF8.self)
    let v0JSON = Data("""
    {"schemaVersion":0,"geometries":\(registryJSON)}
    """.utf8)

    let loaded = try ProjectUpgrade.load(v0JSON)
    #expect(loaded.schemaVersion == ProjectSnapshot.currentSchemaVersion)
    #expect(loaded.geometries == registry)
    #expect(loaded.mediaFilenames == [])
}

/// The load-bearing case (Controller addendum ruling 3): a document from a
/// newer build must throw BEFORE any field is read into a snapshot, because
/// a partial read followed by a save would silently delete every field the
/// newer build wrote.
///
/// The fixture must NOT be a v1-shaped document with a bigger number in it —
/// `{"schemaVersion":2,"geometries":[],"mediaFilenames":[...]}` decodes
/// cleanly as `ProjectSnapshot`, so a decode-first implementation ("decode
/// the full snapshot, then check `schemaVersion > 1` and throw `.tooNew`")
/// would pass that fixture unchanged — the exact thing this ruling forbids.
/// This fixture's `geometries` is an object, not an array, which
/// `GeometryRegistry`'s hand-written `init(from:)` cannot decode
/// (`RegistryTests.swift` documents its wire shape as a flat array), and
/// `mediaFilenames` is absent entirely; `newInV2` stands in for a field a
/// real future build might add. A decode-first implementation throws
/// `.malformed` here, not `.tooNew` — a genuinely version-first probe is
/// what makes `.tooNew` reachable at all, because the probe never asks
/// `GeometryRegistry` or `ProjectSnapshot` to decode anything.
@Test func loadThrowsTooNewForAFutureSchemaVersion() {
    let data = Data("""
    {"schemaVersion":2,"geometries":{"v2":"shape"},"newInV2":42}
    """.utf8)
    do {
        _ = try ProjectUpgrade.load(data)
        Issue.record("expected ProjectFormatError.tooNew to be thrown")
    } catch let error as ProjectFormatError {
        #expect(error == .tooNew(found: 2, supported: 1))
    } catch {
        Issue.record("expected ProjectFormatError, got \(error)")
    }
}

/// A v1 document written *before* `segments` existed — a literal, hand-built
/// wire shape (three keys, in the sorted order `topLevelKeysEncodeInSortedOrder`
/// pins: geometries, mediaFilenames, schemaVersion), not `richSnapshot()` run
/// through today's encoder with `"segments"` stripped afterward. The
/// stripped-after-the-fact version would only prove today's decode logic can
/// tolerate a key it just removed from its own output — a much weaker claim
/// than "a document nobody has rebuilt since `segments` was added still
/// opens", which is the actual requirement (a real pre-existing project on a
/// user's disk). Same reasoning as `loadMigratesASyntheticV0DocumentInsertingEmptyMediaFilenames`'s
/// hand-built v0 fixture just above.
@Test func aV1DocumentWrittenBeforeSegmentsExistedStillDecodes() throws {
    let registry = richRegistry()
    let registryData = try JSONEncoder().encode(registry)
    let registryJSON = String(decoding: registryData, as: UTF8.self)
    let preSegmentsV1JSON = Data("""
    {"geometries":\(registryJSON),"mediaFilenames":["clip-01.mov"],"schemaVersion":1}
    """.utf8)

    let loaded = try ProjectUpgrade.load(preSegmentsV1JSON)
    #expect(loaded.schemaVersion == 1)
    #expect(loaded.geometries == registry)
    #expect(loaded.mediaFilenames == ["clip-01.mov"])
    #expect(loaded.segments == SegmentTable.empty)
}

@Test func loadThrowsUnsupportedLegacyVersionForANegativeSchemaVersion() {
    let data = Data("""
    {"schemaVersion":-1,"geometries":[],"mediaFilenames":[]}
    """.utf8)
    do {
        _ = try ProjectUpgrade.load(data)
        Issue.record("expected ProjectFormatError.unsupportedLegacyVersion to be thrown")
    } catch let error as ProjectFormatError {
        #expect(error == .unsupportedLegacyVersion(-1))
    } catch {
        Issue.record("expected ProjectFormatError, got \(error)")
    }
}
