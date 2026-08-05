import Foundation
import Testing
@testable import Geometry
import Graph

/// The package half of the one digest vector crossing the package/app boundary. This
/// package compares digests and never computes one, so the two literals below are
/// shared with `scripts/cross-boundary-digest-probe.swift`, which hashes them app
/// side. Nothing in `swift test` can prove the arrow between the two constants.

private let displayA = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!

/// `DisplayGeometry(displayA, 3840 × 2160, scale 2).canonicalBytes`, 41 bytes.
/// `scale: 2` on purpose: at `scale: 1` the field is `0x3ff0000000000000`, a value a
/// bug could produce by accident.
let pinnedCanonicalBytesHex =
    "016ba7b8109dad11d180b400c04fd430c8"
    + "000f00000000000070080000000000000000000000000040"

/// SHA-256 of exactly the bytes above, computed twice with independent
/// implementations rather than by hand.
let pinnedSHA256Hex =
    "564a19db7b51ffcdccc38bacde29f69fb293d833e85f574c5db9434d45db3bfe"

/// Not `String(format:)`, which is unsafe under `.strictMemorySafety()` and warns.
private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { byte in
        let s = String(byte, radix: 16)
        return s.count == 1 ? "0" + s : s
    }.joined()
}

private func bytes(fromHex string: String) -> [UInt8] {
    var result: [UInt8] = []
    var pending: Character?
    for character in string {
        if let high = pending {
            result.append(UInt8(String([high, character]), radix: 16)!)
            pending = nil
        } else {
            pending = character
        }
    }
    precondition(pending == nil, "odd-length hex string")
    return result
}

// MARK: - The bytes half

/// The input side: if the canonical encoding changes, the app-side probe is hashing
/// something else, and this goes red first, where the encoding lives.
@Test func pinnedCanonicalBytesAreTheOnesTheAppSideProbeHashes() {
    let geometry = DisplayGeometry(displayUUID: displayA, pixelWidth: 3840, pixelHeight: 2160, scale: 2)
    #expect(hex(geometry.canonicalBytes) == pinnedCanonicalBytesHex)
}

@Test func pinnedCanonicalBytesAreTheFrozenWidth() {
    #expect(bytes(fromHex: pinnedCanonicalBytesHex).count == 41)
}

// MARK: - The digest half — compared, never computed

/// The constant both halves share, and its rendering is the literal the probe prints:
/// mistyped, the probe would compare against nonsense, so it is checked, not trusted.
@Test func pinnedSHA256IsAWellFormedContentDigest() {
    let digest = ContentDigest(bytes(fromHex: pinnedSHA256Hex))
    #expect(digest.bytes.count == ContentDigest.byteCount)
    #expect(digest.description == "ContentDigest(\(pinnedSHA256Hex))")
}

/// Comparison must discriminate a **single flipped bit**, not merely two wholly
/// different values: the realistic failure is a truncated hash re-padded, a byte-swap
/// or a length-only check, none of which `EvidenceTests`' `0x11…`/`0x22…` can catch.
@Test func contentDigestComparisonSeparatesASingleFlippedBit() {
    let original = bytes(fromHex: pinnedSHA256Hex)
    for index in [0, 31] {
        var mutated = original
        mutated[index] ^= 0x01
        #expect(ContentDigest(original) != ContentDigest(mutated),
                "a digest differing in one bit of byte \(index) compared equal")
    }
}
