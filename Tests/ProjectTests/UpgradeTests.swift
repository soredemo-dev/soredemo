import Testing
import Foundation
@testable import Project
import Geometry

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
//   hid a real bug in Task 10.5.
// - `mediaFilenames` deliberately NOT in sorted order, so round-trip proves
//   order is preserved rather than coincidentally reproduced.

private let displayA = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!
private let displayB = UUID(uuidString: "F47AC10B-58CC-4372-A567-0E02B2C3D479")!

private func richRegistry() -> GeometryRegistry {
    var registry = GeometryRegistry()
    registry.insert(DisplayGeometry(displayUUID: displayA, pixelWidth: 3840, pixelHeight: 2160, scale: 2), observedAt: 100)
    registry.insert(DisplayGeometry(displayUUID: displayB, pixelWidth: 2560, pixelHeight: 1440, scale: 1), observedAt: 200)
    return registry
}

private func richSnapshot() -> ProjectSnapshot {
    ProjectSnapshot(
        schemaVersion: ProjectSnapshot.currentSchemaVersion,
        geometries: richRegistry(),
        mediaFilenames: ["clip-03.mov", "clip-01.mov", "clip-02.mov"]
    )
}

// MARK: - ProjectSnapshot: round trip and encoding determinism

@Test func currentSchemaVersionIsOne() {
    #expect(ProjectSnapshot.currentSchemaVersion == 1)
}

@Test func roundTripPreservesAllFields() throws {
    let snapshot = richSnapshot()
    let data = try ProjectSnapshot.makeEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(ProjectSnapshot.self, from: data)
    #expect(decoded == snapshot)
}

@Test func roundTripPreservesMediaFilenameOrder() throws {
    let snapshot = richSnapshot()
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
    let data = try ProjectSnapshot.makeEncoder().encode(richSnapshot())
    let text = String(decoding: data, as: UTF8.self)
    let g = try #require(text.range(of: "\"geometries\""))
    let m = try #require(text.range(of: "\"mediaFilenames\""))
    let s = try #require(text.range(of: "\"schemaVersion\""))
    #expect(g.lowerBound < m.lowerBound)
    #expect(m.lowerBound < s.lowerBound)
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
    let data = try ProjectSnapshot.makeEncoder().encode(richSnapshot())
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
    let snapshot = richSnapshot()
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
