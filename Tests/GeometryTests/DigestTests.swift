import Testing
import Foundation
@testable import Geometry

private let displayA = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!
private let displayB = UUID(uuidString: "6BA7B811-9DAD-11D1-80B4-00C04FD430C8")!

/// Deliberately not `String(format:)`, which is an unsafe construct under
/// `.strictMemorySafety()` and warns.
private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { byte in
        let s = String(byte, radix: 16)
        return s.count == 1 ? "0" + s : s
    }.joined()
}

// MARK: - The digest function

/// Known-answer vectors obtained independently of this implementation — computed
/// with four separate FNV-1a implementations (Python, Ruby, Perl, JavaScript),
/// all four agreeing. If this implementation disagrees, this implementation is
/// wrong, not the vectors.
///
/// NOTE on `"foobar"`: the task brief carried `0x8595_8bf0_63e0_1d17`. That value
/// is wrong — it is not FNV-1a/64 of `"foobar"`, nor of `"foobar\0"`, nor FNV-1,
/// nor any basis/prime variant tried. All four independent implementations give
/// `0x8594_4171_f739_67e8`, which is also the value in the FNV reference test
/// suite; the brief's digits appear transcription-corrupted (8595 vs 8594). The
/// correct vector is used here deliberately, and the discrepancy is recorded in
/// the task report rather than silently reconciled.
@Test func fnv1aMatchesKnownVectors() {
    #expect(fnv1a64([]) == 0xcbf2_9ce4_8422_2325)
    #expect(fnv1a64(Array("a".utf8)) == 0xaf63_dc4c_8601_ec8c)
    #expect(fnv1a64(Array("foobar".utf8)) == 0x8594_4171_f739_67e8)
    #expect(fnv1a64(Array("foo".utf8)) == 0xdcb2_7518_fed9_d577)
}

// MARK: - Revision identity

@Test func identicalGeometryYieldsIdenticalRevision() {
    let a = DisplayGeometry(displayUUID: displayA, pixelWidth: 3840, pixelHeight: 2160, scale: 2)
    let b = DisplayGeometry(displayUUID: displayA, pixelWidth: 3840, pixelHeight: 2160, scale: 2)
    #expect(a.revision == b.revision)
}

@Test func differentDisplaysDoNotCollide() {
    #expect(DisplayGeometry(displayUUID: displayA, pixelWidth: 3840, pixelHeight: 2160, scale: 2).revision
         != DisplayGeometry(displayUUID: displayB, pixelWidth: 3840, pixelHeight: 2160, scale: 2).revision)
}

@Test func scaleParticipates() {
    #expect(DisplayGeometry(displayUUID: displayA, pixelWidth: 3840, pixelHeight: 2160, scale: 2).revision
         != DisplayGeometry(displayUUID: displayA, pixelWidth: 3840, pixelHeight: 2160, scale: 1).revision)
}

/// Width and height must not be interchangeable: a transposed display is a
/// different geometry, and a length-prefixed-free encoding of two equal-width
/// fields is the classic place that collapses.
@Test func dimensionsAreNotInterchangeable() {
    #expect(DisplayGeometry(displayUUID: displayA, pixelWidth: 3840, pixelHeight: 2160, scale: 2).revision
         != DisplayGeometry(displayUUID: displayA, pixelWidth: 2160, pixelHeight: 3840, scale: 2).revision)
}

// MARK: - The encoding itself

@Test func canonicalBytesCarryAVersionPrefix() {
    let g = DisplayGeometry(displayUUID: displayA, pixelWidth: 100, pixelHeight: 100, scale: 1)
    #expect(g.canonicalBytes.first == CanonicalEncoding.version)
}

/// The encoding is fixed-width: 1 version byte + 16 UUID + 8 + 8 + 8.
@Test func canonicalBytesHaveTheFrozenLength() {
    let g = DisplayGeometry(displayUUID: displayA, pixelWidth: 3840, pixelHeight: 2160, scale: 2)
    #expect(g.canonicalBytes.count == 41)
}

/// Pins the byte layout, not just the digest, so a reordering of fields that
/// happened to preserve the digest would still be caught, and so a failure
/// names *which* field moved.
///
/// Frozen. Not read off a green run: computed out of band from the encoding
/// spec (version byte ‖ RFC 4122 UUID bytes ‖ little-endian int64 ‖ int64 ‖
/// IEEE-754 bit pattern), so this asserts the implementation against the
/// specification rather than against itself. Changing it is a breaking change to
/// every approval already recorded; it ships with `CanonicalEncoding.version`
/// bumped and a re-approval path, never as a quiet edit.
///
///   01                                | encoding version
///   6ba7b8109dad11d180b400c04fd430c8  | displayA
///   000f000000000000                  | 3840, little-endian
///   7008000000000000                  | 2160, little-endian
///   0000000000000040                  | 2.0, bit pattern, little-endian
@Test func canonicalBytesArePinned() {
    let g = DisplayGeometry(displayUUID: displayA, pixelWidth: 3840, pixelHeight: 2160, scale: 2)
    #expect(hex(g.canonicalBytes) == "016ba7b8109dad11d180b400c04fd430c8"
                                   + "000f00000000000070080000000000000000000000000040")
}

/// Guards the `Hasher` trap AND any future change to the canonical encoding.
///
/// This is the cross-process check. A process's hash seed is fixed for its
/// lifetime, so computing the same revision twice inside one test proves
/// nothing — that is exactly how seeded-hash bugs survive ordinary testing.
/// The literal below was computed in a *different* process — an out-of-band
/// FNV-1a over the canonical bytes above — and frozen here, so every subsequent
/// `swift test` run (a new process, a new hash seed) compares against a value
/// produced elsewhere. See the design doc § Canonical encoding.
@Test func revisionIsPinned() {
    let g = DisplayGeometry(displayUUID: displayA, pixelWidth: 3840, pixelHeight: 2160, scale: 2)
    #expect(g.revision.id == 0xbcf4_9ed7_dcb4_2be0)
}

/// The revision must not be `hashValue` under another name. `Hasher` is seeded
/// per process, so this asserts against a value that cannot have come from it.
@Test func revisionIsNotTheSeededHashValue() {
    let g = DisplayGeometry(displayUUID: displayA, pixelWidth: 3840, pixelHeight: 2160, scale: 2)
    #expect(UInt64(bitPattern: Int64(g.hashValue)) != g.revision.id)
}

// MARK: - Floating point

/// `scale` is digested bit-exactly, so two doubles a lossy rendering would
/// collapse must not share a revision.
///
/// Measured limitation, recorded rather than assumed: this test alone does NOT
/// catch a switch to `String(scale)`, because Swift's `Double` description is
/// shortest-round-trippable and so still separates these two values. The test
/// that catches a decimal rendering is `canonicalBytesArePinned` — verified by
/// mutating the implementation to `String(scale).utf8` and observing which tests
/// went red.
@Test func scaleIsDigestedBitExactly() {
    let a = DisplayGeometry(displayUUID: displayA, pixelWidth: 100, pixelHeight: 100, scale: 1.0)
    let b = DisplayGeometry(displayUUID: displayA, pixelWidth: 100, pixelHeight: 100,
                            scale: 1.0.nextUp)
    #expect(a.revision != b.revision)
}

// MARK: - Serialization round-trip

/// `Codable` is the document path, never the digest path; a value that survives
/// a round-trip must still digest to the same revision.
@Test func revisionSurvivesACodableRoundTrip() throws {
    let g = DisplayGeometry(displayUUID: displayA, pixelWidth: 3840, pixelHeight: 2160, scale: 2)
    let decoded = try JSONDecoder().decode(DisplayGeometry.self, from: JSONEncoder().encode(g))
    #expect(decoded == g)
    #expect(decoded.revision == g.revision)
}

@Test func revisionSurvivesACodableRoundTripItself() throws {
    let r = GeometryRevision(id: 0x0123_4567_89ab_cdef)
    let decoded = try JSONDecoder().decode(GeometryRevision.self, from: JSONEncoder().encode(r))
    #expect(decoded == r)
}

// MARK: - Decode validation (Task 4.5)

/// Synthesised `Decodable` would assign `scale` directly and never call
/// `init(displayUUID:pixelWidth:pixelHeight:scale:)`, so the finite-positive-
/// scale precondition would go completely unenforced on the one path that
/// carries untrusted input — `GeometryRegistry.init(from:)`'s per-entry
/// decode, reached from `ProjectSnapshot`. This decodes a hand-built JSON
/// literal — not a `DisplayGeometry` encoded from a real value and
/// re-decoded, because that route is closed: `init` traps before an invalid
/// scale could ever be constructed to encode in the first place. The
/// literal's shape was confirmed against this package's own `JSONEncoder`
/// output for the same field values (keys `displayUUID`/`pixelWidth`/
/// `pixelHeight`/`scale`), then hand-transcribed here.
///
/// Asserts `.dataCorrupted` specifically, not merely "a `DecodingError`":
/// a build that reverted to fully-synthesised `Codable` would decode this
/// literal successfully and never throw at all, which a bare
/// `catch is DecodingError` would not distinguish from this test having
/// actually exercised the validation — see the Task 4.5 report for the
/// reversion that confirmed this.
@Test func decodingANonPositiveScaleDisplayGeometryThrows() throws {
    let json = Data("""
    {"displayUUID":"6BA7B810-9DAD-11D1-80B4-00C04FD430C8",
     "pixelWidth":3840,"pixelHeight":2160,"scale":0}
    """.utf8)
    do {
        _ = try JSONDecoder().decode(DisplayGeometry.self, from: json)
        Issue.record("expected decoding a non-positive-scale DisplayGeometry to throw")
    } catch let error as DecodingError {
        guard case .dataCorrupted = error else {
            Issue.record("expected .dataCorrupted (DisplayGeometry's own validation), got \(error)")
            return
        }
    } catch {
        Issue.record("expected DecodingError, got \(error)")
    }
}

/// Same guard, the other precondition: `init`'s dimensions check is
/// independent of the scale check, and a mutation that dropped only one of
/// the two `guard`s in `init(from:)` must be caught by a fixture that
/// exercises the other. See `decodingANonPositiveScaleDisplayGeometryThrows`
/// for the full rationale — this test mirrors it for `pixelWidth`.
@Test func decodingANonPositiveDimensionDisplayGeometryThrows() throws {
    let json = Data("""
    {"displayUUID":"6BA7B810-9DAD-11D1-80B4-00C04FD430C8",
     "pixelWidth":0,"pixelHeight":2160,"scale":2}
    """.utf8)
    do {
        _ = try JSONDecoder().decode(DisplayGeometry.self, from: json)
        Issue.record("expected decoding a non-positive-dimension DisplayGeometry to throw")
    } catch let error as DecodingError {
        guard case .dataCorrupted = error else {
            Issue.record("expected .dataCorrupted (DisplayGeometry's own validation), got \(error)")
            return
        }
    } catch {
        Issue.record("expected DecodingError, got \(error)")
    }
}
