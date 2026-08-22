import Testing
import Foundation
@testable import Geometry

private let displayA = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!
private let displayB = UUID(uuidString: "6BA7B811-9DAD-11D1-80B4-00C04FD430C8")!

/// Not `String(format:)`: an unsafe construct under `.strictMemorySafety()`.
private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { byte in
        let s = String(byte, radix: 16)
        return s.count == 1 ? "0" + s : s
    }.joined()
}

// MARK: - The digest function

/// Known-answer vectors computed independently of this implementation, so a
/// disagreement means the implementation is wrong, not the vectors. The
/// `"foobar"` value is `0x8594_4171_f739_67e8`; the widely-circulated
/// `0x8595_8bf0_63e0_1d17` is a transcription corruption, not FNV-1a/64.
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
/// different geometry.
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

/// Pins the byte layout, not just the digest, so a field reordering that
/// preserved the digest is still caught. Computed out of band from the spec
/// (version byte ‖ RFC 4122 UUID bytes ‖ LE int64 ‖ LE int64 ‖ IEEE-754 bit
/// pattern); changing it is a breaking change requiring a version bump.
@Test func canonicalBytesArePinned() {
    let g = DisplayGeometry(displayUUID: displayA, pixelWidth: 3840, pixelHeight: 2160, scale: 2)
    #expect(hex(g.canonicalBytes) == "016ba7b8109dad11d180b400c04fd430c8"
                                   + "000f00000000000070080000000000000000000000000040")
}

/// Guards the `Hasher` trap and any change to the canonical encoding. The
/// literal was computed out of band in a different process, so it is not a
/// per-process hash seed under another name.
@Test func revisionIsPinned() {
    let g = DisplayGeometry(displayUUID: displayA, pixelWidth: 3840, pixelHeight: 2160, scale: 2)
    #expect(g.revision.id == 0xbcf4_9ed7_dcb4_2be0)
}

/// The revision must not be `hashValue` under another name.
@Test func revisionIsNotTheSeededHashValue() {
    let g = DisplayGeometry(displayUUID: displayA, pixelWidth: 3840, pixelHeight: 2160, scale: 2)
    #expect(UInt64(bitPattern: Int64(g.hashValue)) != g.revision.id)
}

// MARK: - Floating point

/// `scale` is digested bit-exactly, so two doubles a lossy rendering would
/// collapse must not share a revision. A switch to `String(scale)` is caught
/// by `canonicalBytesArePinned`, not by this test.
@Test func scaleIsDigestedBitExactly() {
    let a = DisplayGeometry(displayUUID: displayA, pixelWidth: 100, pixelHeight: 100, scale: 1.0)
    let b = DisplayGeometry(displayUUID: displayA, pixelWidth: 100, pixelHeight: 100,
                            scale: 1.0.nextUp)
    #expect(a.revision != b.revision)
}

// MARK: - Serialization round-trip

/// A value that survives a `Codable` round-trip still digests to the same revision.
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

// MARK: - Decode validation

/// Untrusted input must not bypass `init`'s finite-positive-scale check. The
/// JSON is hand-built because `init` traps before such a value could be
/// encoded. `.dataCorrupted` specifically: a revert to fully-synthesised
/// `Codable` would decode this successfully and never throw at all.
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

/// The same guard for the independent dimensions check, so dropping either
/// `guard` in `init(from:)` reddens a test.
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
