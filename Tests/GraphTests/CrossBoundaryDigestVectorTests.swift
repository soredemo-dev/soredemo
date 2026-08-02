import Foundation
import Testing
@testable import Geometry
import Graph

/// The package half of the one vector that crosses the package/app boundary
/// (design doc § "Half of `ContentDigest` has no test, and it is the half
/// Phase 8 depends on").
///
/// The chain Phase 8's `approval-gate` binds on is: **the package produces
/// canonical bytes → the app computes SHA-256 over them via CryptoKit → the
/// digest is stored → it is verified later.** Task 13 proved the first link is
/// stable across processes and `EvidenceTests` covers the last, but the middle
/// link — the hashing — lives in the **app target**, where this package's test
/// targets cannot reach and where the app has no test target of its own.
///
/// So the vector is split at the boundary rather than skipped:
///
/// - **here**: the canonical bytes for a fixed fixture are pinned, and the
///   expected SHA-256 of exactly those bytes is pinned beside them as a
///   constant. This package **compares digests and never computes one** — D6
///   forbids CryptoKit here — so nothing below hashes anything;
/// - **app side**: `scripts/cross-boundary-digest-probe.swift` runs
///   `Minting.digest(of:)` over the same bytes and asserts the same constant.
///
/// The two halves share the two literals below, which is what makes them one
/// vector. Drift in the canonical encoding turns this file red; drift in
/// CryptoKit or in `Minting` turns the probe red.
///
/// **The honest limit:** nothing in `swift test` can prove the arrow between
/// the two constants. That check is the probe, and the probe is not a standing
/// regression test — see the task 18 report.

private let displayA = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!

/// `DisplayGeometry(displayA, 3840 × 2160, scale 2).canonicalBytes`, the same
/// fixture `GeometryTests/DigestTests.swift` pins. 41 bytes.
///
/// **A non-identity fixture on purpose** (`AGENTS.md`, the identity-fixture
/// table): `scale: 2`, not `1`. At `scale: 1` the scale field is
/// `0x3ff0000000000000`, a value a bug could produce by accident; at `2` it is
/// `0x4000000000000000` and the trailing bytes below are load-bearing.
let pinnedCanonicalBytesHex =
    "016ba7b8109dad11d180b400c04fd430c8"
    + "000f00000000000070080000000000000000000000000040"

/// SHA-256 of exactly the bytes above.
///
/// Not hand-computed: derived twice with independent implementations — Python
/// `hashlib.sha256(bytes.fromhex(…))` and `xxd -r -p | shasum -a 256` — which
/// agreed, and agreed with the value in the task brief. `AGENTS.md` treats a
/// hand-computed constant in a brief as a guess until something computes it;
/// this one was computed.
let pinnedSHA256Hex =
    "564a19db7b51ffcdccc38bacde29f69fb293d833e85f574c5db9434d45db3bfe"

/// Deliberately not `String(format:)`, which is an unsafe construct under
/// `.strictMemorySafety()` and warns.
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

/// The input side of the cross-boundary vector. If the canonical encoding
/// changes, the app-side probe is hashing something else and this goes red
/// first, here, where the encoding lives.
@Test func pinnedCanonicalBytesAreTheOnesTheAppSideProbeHashes() {
    let geometry = DisplayGeometry(displayUUID: displayA, pixelWidth: 3840, pixelHeight: 2160, scale: 2)
    #expect(hex(geometry.canonicalBytes) == pinnedCanonicalBytesHex)
}

@Test func pinnedCanonicalBytesAreTheFrozenWidth() {
    #expect(bytes(fromHex: pinnedCanonicalBytesHex).count == 41)
}

// MARK: - The digest half — compared, never computed

/// The pinned digest is a well-formed `ContentDigest`, and its rendering is the
/// literal the probe prints. This is the constant both halves share; if it is
/// mistyped, the probe's comparison would be against nonsense, so it is checked
/// here rather than trusted.
@Test func pinnedSHA256IsAWellFormedContentDigest() {
    let digest = ContentDigest(bytes(fromHex: pinnedSHA256Hex))
    #expect(digest.bytes.count == ContentDigest.byteCount)
    #expect(digest.description == "ContentDigest(\(pinnedSHA256Hex))")
}

/// `ContentDigest`'s comparison must discriminate a **single flipped bit**, not
/// merely two wholly different values.
///
/// `EvidenceTests` compares `0x11…` against `0x22…` — thirty-two differing
/// bytes, which an equality that looked at only one byte, or only the length,
/// would still separate. The realistic failure on the evidence path is one bit:
/// a truncated hash re-padded, a byte-swap, a length-only check. This is the
/// non-identity fixture for the comparison itself.
@Test func contentDigestComparisonSeparatesASingleFlippedBit() {
    let original = bytes(fromHex: pinnedSHA256Hex)
    for index in [0, 31] {
        var mutated = original
        mutated[index] ^= 0x01
        #expect(ContentDigest(original) != ContentDigest(mutated),
                "a digest differing in one bit of byte \(index) compared equal")
    }
}
