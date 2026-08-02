import Testing
import Foundation
@testable import Graph
import Geometry
import Timeline

// MARK: - Fixtures
//
// Deliberately NOT at an identity element (AGENTS.md, "every fixture set needs a
// non-identity value for every transform applied to it"). Specifically:
//
//   * evidence has TWO refs, never one — a single-element `Evidence` has an empty
//     `tail`, and an encoding that forgot its count prefix or dropped the tail
//     entirely would still pass every single-ref test.
//   * one ref carries a `sourceInterval` and one does not — `nil` vs `.some` is
//     Hashable-significant on `EvidenceRef` and must stay digest-significant.
//   * the values under test include a `Double`-bearing payload (`NormalizedFrame`),
//     because a payload routed through `Codable` would render `Double` as decimal
//     text rather than a bit pattern, and no `Int` fixture can catch that.

private let observationID = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!
private let transcriptID = UUID(uuidString: "6BA7B811-9DAD-11D1-80B4-00C04FD430C8")!
private let releaseID = UUID(uuidString: "6BA7B812-9DAD-11D1-80B4-00C04FD430C8")!

private let testEpoch = BootEpoch(id: UUID(uuidString: "6495B81D-14D1-4E05-8851-DD30BE41D757")!)

private func digest(_ seed: UInt8) -> ContentDigest {
    ContentDigest(Array(repeating: seed, count: ContentDigest.byteCount))
}

/// Deliberately not `String(format:)`, which is an unsafe construct under
/// `.strictMemorySafety()` and warns. Matches the helper in `EvidenceTests.swift`.
private func hex(_ bytes: Data) -> String {
    bytes.map { byte in
        let s = String(byte, radix: 16)
        return s.count == 1 ? "0" + s : s
    }.joined()
}

private let refWithInterval = EvidenceRef(
    kind: .observation, id: observationID, contentDigest: digest(0x11),
    sourceInterval: HostRange(epoch: testEpoch, start: Nanoseconds(1_000), duration: Nanoseconds(250)))

private let refWithoutInterval = EvidenceRef(
    kind: .transcript, id: transcriptID, contentDigest: digest(0x22))

private let twoRefs = Evidence(refWithInterval, refWithoutInterval)

private let acceptedDerivation = Derivation(
    producer: ProducerID("reference-producer"), producerVersion: 3,
    evidence: twoRefs, outcome: .accepted)

/// `Derived<Int>` — the shape the plan's Task 13/14 snippets use.
private func generated(_ value: Int) -> Derived<Int> {
    Derived(value: value, origin: .generated(acceptedDerivation))
}

private let revision = GeometryRevision(id: 0xbcf4_9ed7_dcb4_2be0)

/// A `Double`-bearing payload, authored rather than generated.
private let authoredFrame = Derived(
    value: NormalizedFrame(origin: NormalizedPoint(x: 0.25, y: 0.5),
                           size: NormalizedSize(width: 0.5, height: 0.25),
                           revision: revision),
    origin: .authored(Authorship(note: "operator override",
                                 at: Date(timeIntervalSinceReferenceDate: 1_000_000.5))))

// MARK: - `.generated` cannot be spelled without evidence
//
// The load-bearing property of D-P4, and it is a *type-system* property: there is
// no runtime assertion to test, because `Derivation.init` takes a non-optional
// `Evidence`, and `Evidence` has no empty representation at all (Task 12). The
// test below is the closest observable form — every generated origin reachable
// through the API cites at least one ref — and the real guarantee is that the
// alternative does not compile.

@Test func everyGeneratedOriginCitesAtLeastOneRef() {
    guard case .generated(let derivation) = generated(1).origin else {
        Issue.record("expected .generated"); return
    }
    #expect(derivation.evidence.count >= 1)
    #expect(!derivation.evidence.isEmpty)
}

@Test func authoredOriginCarriesNoDerivation() {
    guard case .authored(let authorship) = authoredFrame.origin else {
        Issue.record("expected .authored"); return
    }
    #expect(authorship.note == "operator override")
}

// MARK: - approvalBytes: the version prefix

@Test func approvalBytesCarryAVersionPrefix() {
    #expect(generated(42).approvalBytes.first == CanonicalEncoding.version)
    #expect(authoredFrame.approvalBytes.first == CanonicalEncoding.version)
}

// MARK: - approvalBytes: review is never covered
//
// The single most important property in this task. Approving mutates `review`;
// if `review` were digested, the approval would invalidate the very bytes it was
// just recorded against, and a person's approval would be worthless the instant
// it was made.

@Test func approvalBytesIgnoreReviewState() {
    var d = generated(42)
    let before = d.approvalBytes
    d.review = .approved
    #expect(d.approvalBytes == before)
    d.review = .rejected
    #expect(d.approvalBytes == before)
    d.review = .pending
    #expect(d.approvalBytes == before)
}

@Test func approvalBytesIgnoreReviewStateOnAnAuthoredValue() {
    var d = authoredFrame
    let before = d.approvalBytes
    d.review = .approved
    #expect(d.approvalBytes == before)
}

@Test func twoDerivedDifferingOnlyInReviewShareApprovalBytes() {
    let pending = Derived(value: 42, origin: .generated(acceptedDerivation), review: .pending)
    let approved = Derived(value: 42, origin: .generated(acceptedDerivation), review: .approved)
    #expect(pending != approved)                                  // they are different values …
    #expect(pending.approvalBytes == approved.approvalBytes)      // … and the same approval
}

// MARK: - approvalBytes: value and origin are both covered

@Test func approvalBytesChangeWithValue() {
    #expect(generated(42).approvalBytes != generated(43).approvalBytes)
}

@Test func approvalBytesChangeWithOriginCase() {
    let sameValue = Derived(value: 42, origin: .authored(Authorship(note: "operator override")))
    #expect(generated(42).approvalBytes != sameValue.approvalBytes)
}

@Test func approvalBytesChangeWithProducer() {
    let other = Derivation(producer: ProducerID("other-producer"), producerVersion: 3,
                           evidence: twoRefs, outcome: .accepted)
    #expect(generated(42).approvalBytes
         != Derived(value: 42, origin: .generated(other)).approvalBytes)
}

@Test func approvalBytesChangeWithProducerVersion() {
    let other = Derivation(producer: ProducerID("reference-producer"), producerVersion: 4,
                           evidence: twoRefs, outcome: .accepted)
    #expect(generated(42).approvalBytes
         != Derived(value: 42, origin: .generated(other)).approvalBytes)
}

@Test func approvalBytesChangeWithOutcome() {
    let rejected = Derivation(producer: ProducerID("reference-producer"), producerVersion: 3,
                              evidence: twoRefs, outcome: .rejected(GateCode("insufficient-evidence")))
    #expect(generated(42).approvalBytes
         != Derived(value: 42, origin: .generated(rejected)).approvalBytes)
}

@Test func approvalBytesChangeWithGateCode() {
    func rejected(_ code: String) -> Data {
        Derived(value: 42, origin: .generated(
            Derivation(producer: ProducerID("reference-producer"), producerVersion: 3,
                       evidence: twoRefs, outcome: .rejected(GateCode(code))))).approvalBytes
    }
    #expect(rejected("insufficient-evidence") != rejected("stale-evidence"))
}

// MARK: - approvalBytes: the evidence is covered, element by element

/// The case a single-ref fixture cannot reach: dropping the tail, or losing the
/// count prefix, leaves one-ref evidence encoding identically either way.
@Test func approvalBytesChangeWithEvidenceCount() {
    let one = Derivation(producer: ProducerID("reference-producer"), producerVersion: 3,
                         evidence: Evidence(refWithInterval), outcome: .accepted)
    #expect(generated(42).approvalBytes
         != Derived(value: 42, origin: .generated(one)).approvalBytes)
}

@Test func approvalBytesChangeWithEvidenceOrder() {
    let reversed = Derivation(producer: ProducerID("reference-producer"), producerVersion: 3,
                              evidence: Evidence(refWithoutInterval, refWithInterval),
                              outcome: .accepted)
    #expect(generated(42).approvalBytes
         != Derived(value: 42, origin: .generated(reversed)).approvalBytes)
}

@Test func approvalBytesChangeWithACitedContentDigest() {
    let restated = EvidenceRef(kind: .observation, id: observationID, contentDigest: digest(0x12),
                               sourceInterval: HostRange(epoch: testEpoch, start: Nanoseconds(1_000), duration: Nanoseconds(250)))
    let other = Derivation(producer: ProducerID("reference-producer"), producerVersion: 3,
                           evidence: Evidence(restated, refWithoutInterval), outcome: .accepted)
    #expect(generated(42).approvalBytes
         != Derived(value: 42, origin: .generated(other)).approvalBytes)
}

@Test func approvalBytesChangeWithACitedEvidenceKind() {
    let asRelease = EvidenceRef(kind: .release, id: transcriptID, contentDigest: digest(0x22))
    let other = Derivation(producer: ProducerID("reference-producer"), producerVersion: 3,
                           evidence: Evidence(refWithInterval, asRelease), outcome: .accepted)
    #expect(generated(42).approvalBytes
         != Derived(value: 42, origin: .generated(other)).approvalBytes)
}

@Test func approvalBytesChangeWithACitedEvidenceID() {
    let otherID = EvidenceRef(kind: .transcript, id: releaseID, contentDigest: digest(0x22))
    let other = Derivation(producer: ProducerID("reference-producer"), producerVersion: 3,
                           evidence: Evidence(refWithInterval, otherID), outcome: .accepted)
    #expect(generated(42).approvalBytes
         != Derived(value: 42, origin: .generated(other)).approvalBytes)
}

/// Task 12 recorded that `sourceInterval`'s `nil`-versus-`.some` is
/// `Hashable`-significant; it must stay digest-significant too. A zero-length
/// interval **at the zero epoch** is the exact fixture that catches an encoder
/// writing only the payload and no discriminator: `nil` and
/// `HostRange(epoch: BootEpoch(id: .zero), start: 0, duration: 0)` both have
/// all-zero payload bytes. Task 2 changed `sourceInterval` from `TimeRange` to
/// `HostRange`, which added the epoch's 16 bytes to the payload — using
/// `testEpoch` here (a non-zero UUID) would have made this collision
/// impossible to construct by accident, and so no longer a fixture that
/// exercises the discriminator at all.
@Test func approvalBytesDistinguishNoIntervalFromAZeroLengthInterval() {
    let zeroEpoch = BootEpoch(id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
    let zero = EvidenceRef(kind: .transcript, id: transcriptID, contentDigest: digest(0x22),
                           sourceInterval: HostRange(epoch: zeroEpoch, start: Nanoseconds(0), duration: Nanoseconds(0)))
    let other = Derivation(producer: ProducerID("reference-producer"), producerVersion: 3,
                           evidence: Evidence(refWithInterval, zero), outcome: .accepted)
    #expect(generated(42).approvalBytes
         != Derived(value: 42, origin: .generated(other)).approvalBytes)
}

@Test func approvalBytesChangeWithACitedIntervalsStartAndDuration() {
    func cited(_ start: Int64, _ duration: Int64) -> Data {
        let ref = EvidenceRef(kind: .observation, id: observationID, contentDigest: digest(0x11),
                              sourceInterval: HostRange(epoch: testEpoch, start: Nanoseconds(start), duration: Nanoseconds(duration)))
        return Derived(value: 42, origin: .generated(
            Derivation(producer: ProducerID("reference-producer"), producerVersion: 3,
                       evidence: Evidence(ref, refWithoutInterval), outcome: .accepted))).approvalBytes
    }
    #expect(cited(1_000, 250) != cited(1_001, 250))
    #expect(cited(1_000, 250) != cited(1_000, 251))
    // Same total extent, different split: an encoder that digested `end` alone
    // would collapse these two distinct citations.
    #expect(cited(1_000, 250) != cited(1_250, 0))
}

/// Task 2's load-bearing property, tested directly rather than left to the
/// pinned vectors below to catch incidentally: two citations with identical
/// `start`/`duration` but different boot epochs are different citations
/// (D2-11), and an approval bound to one must not validate the other. An
/// encoder that dropped `epoch` from the encoding — the exact mutation this
/// test was written to catch — would still pass every other test in this
/// file; only the pinned-vector byte counts would move, and only because they
/// happen to pin a fixture that has an epoch at all. This test fails for the
/// right reason even if the pinned vectors were deleted.
@Test func approvalBytesChangeWithACitedIntervalsEpoch() {
    let otherEpoch = BootEpoch(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
    func cited(_ epoch: BootEpoch) -> Data {
        let ref = EvidenceRef(kind: .observation, id: observationID, contentDigest: digest(0x11),
                              sourceInterval: HostRange(epoch: epoch, start: Nanoseconds(1_000), duration: Nanoseconds(250)))
        return Derived(value: 42, origin: .generated(
            Derivation(producer: ProducerID("reference-producer"), producerVersion: 3,
                       evidence: Evidence(ref, refWithoutInterval), outcome: .accepted))).approvalBytes
    }
    #expect(cited(testEpoch) != cited(otherEpoch))
}

// MARK: - Length prefixes: adjacent variable-length fields must not run together

/// The classic concatenation collapse. `DisplayGeometry.canonicalBytes` is
/// unambiguous because every field is fixed-width; `Derived` cannot be, because
/// `Evidence` is variable-length by nature and `ProducerID` is a string. These
/// two values differ only in where the boundary between a `String` value and the
/// producer name falls — without length prefixes they encode identically.
@Test func stringValueAndProducerNameDoNotRunTogether() {
    func d(_ value: String, _ producer: String) -> Data {
        Derived(value: value, origin: .generated(
            Derivation(producer: ProducerID(producer), producerVersion: 1,
                       evidence: twoRefs, outcome: .accepted))).approvalBytes
    }
    #expect(d("ab", "cde") != d("abc", "de"))
}

@Test func gateCodeDoesNotRunIntoTheFieldsBeforeIt() {
    func d(_ producer: String, _ code: String) -> Data {
        Derived(value: 42, origin: .generated(
            Derivation(producer: ProducerID(producer), producerVersion: 1,
                       evidence: twoRefs, outcome: .rejected(GateCode(code))))).approvalBytes
    }
    #expect(d("ab", "cde") != d("abc", "de"))
}

/// A payload that is variable-length and does NOT delimit itself. Legitimate as
/// a top-level `Value` — `approvalBytes` supplies its length — and it is the only
/// fixture that can exercise that outer prefix at all: `Int` is fixed-width and
/// `String` prefixes itself, so with either of them the outer prefix can be
/// deleted and every behavioural test still passes.
private struct RawPayload: CanonicallyEncodable, Codable, Hashable, Sendable {
    let bytes: [UInt8]
    init(_ bytes: [UInt8]) { self.bytes = bytes }
    func encodeCanonically(into out: inout [UInt8]) { out.append(contentsOf: bytes) }
}

/// The second constructed collision, and the reason the *value*'s length prefix
/// is load-bearing.
///
/// Delete it and these two values encode identically: the first has an empty
/// payload and a generated origin whose gate code happens to end with the exact
/// bytes of an authored origin; the second moves that boundary, putting all but
/// those trailing bytes into its payload and carrying the authored origin
/// itself. One is a producer's rejected derivation citing two pieces of
/// evidence. The other is a human's override. Nothing about them is the same
/// except, without the prefix, their bytes.
///
/// The gate code is spelled from the inner origin's own encoding, which is all
/// ASCII and NULs and therefore valid UTF-8 — no byte here is hypothetical.
@Test func valueLengthPrefixDefeatsAConstructedCollision() {
    let inner = Origin.authored(Authorship(note: "n"))
    var innerBytes: [UInt8] = []
    inner.encodeCanonically(into: &innerBytes)

    let outer = Origin.generated(Derivation(
        producer: ProducerID("p"), producerVersion: 1, evidence: twoRefs,
        outcome: .rejected(GateCode(String(decoding: innerBytes, as: UTF8.self)))))
    var outerBytes: [UInt8] = []
    outer.encodeCanonically(into: &outerBytes)

    // The construction only means anything if the inner origin really is a
    // suffix of the outer one; assert that rather than assume it.
    #expect(Array(outerBytes.suffix(innerBytes.count)) == innerBytes)

    let generated = Derived(value: RawPayload([]), origin: outer)
    let authored = Derived(value: RawPayload(Array(outerBytes.dropLast(innerBytes.count))),
                           origin: inner)
    #expect(generated.approvalBytes != authored.approvalBytes)
}

/// A *constructed* collision, not a hypothetical one, and the reason
/// `Evidence`'s count prefix is load-bearing rather than tidy.
///
/// Strip the count prefix and these two derivations — one citing two refs and
/// accepting, one citing a single ref and rejecting — encode to byte-identical
/// strings, because the second citation's bytes can be replayed inside a gate
/// code. The construction is exact: the second ref's kind tag is `transcript`
/// (`0x02`), which is also the `.rejected` tag; its UUID's first eight bytes
/// read back as the little-endian length `74`; and the remaining 74 bytes of the
/// ref, plus the trailing `.accepted` tag, are valid UTF-8 and so can be spelled
/// as a `GateCode`. Computed out of band in Python before it was written here.
///
/// **The `74` moved from `58` in Task 2**, when `sourceInterval` widened from
/// `TimeRange?` to `HostRange?` and the absent-interval padding grew from 16 to
/// 32 zero bytes — the same width change documented on
/// `EvidenceRef.encodeCanonically`. Recomputed, not adjusted by hand.
///
/// One of these two values cites a whole extra piece of evidence than the other.
/// An approval bound to one must never validate the other.
@Test func evidenceCountPrefixDefeatsAConstructedCollision() {
    // 4a00000000000000 = 74, little-endian, in the first eight bytes.
    let craftedID = UUID(uuidString: "4A000000-0000-0000-6162-636465666768")!
    let craftedDigest = ContentDigest(Array("0123456789abcdef0123456789abcdef".utf8))
    let secondRef = EvidenceRef(kind: .transcript, id: craftedID, contentDigest: craftedDigest)

    // "abcdefgh" (the crafted UUID's second half) ‖ the digest ‖ the absent-interval
    // discriminator and its thirty-two zero bytes ‖ the .accepted tag.
    let replay = "abcdefgh0123456789abcdef0123456789abcdef"
        + String(repeating: "\u{0}", count: 33) + "\u{1}"

    let two = Derived(value: 1, origin: .generated(
        Derivation(producer: ProducerID("p"), producerVersion: 1,
                   evidence: Evidence(refWithInterval, secondRef), outcome: .accepted)))
    let one = Derived(value: 1, origin: .generated(
        Derivation(producer: ProducerID("p"), producerVersion: 1,
                   evidence: Evidence(refWithInterval), outcome: .rejected(GateCode(replay)))))

    #expect(two.approvalBytes != one.approvalBytes)
}

@Test func authorshipNoteDoesNotRunIntoTheValueBeforeIt() {
    func d(_ value: String, _ note: String) -> Data {
        Derived(value: value, origin: .authored(Authorship(note: note))).approvalBytes
    }
    #expect(d("ab", "cde") != d("abc", "de"))
}

// MARK: - Authorship

/// Recorded deliberately, in the source and here: `Authorship` carries a
/// timestamp and it IS digest-significant. Authoring the same value at two
/// different moments is two distinct human acts, and an approval bound to one
/// must not validate the other.
@Test func approvalBytesChangeWithTheAuthoringTimestamp() {
    func authored(_ seconds: Double) -> Data {
        Derived(value: 42, origin: .authored(
            Authorship(note: "operator override",
                       at: Date(timeIntervalSinceReferenceDate: seconds)))).approvalBytes
    }
    #expect(authored(1_000_000.5) != authored(1_000_000.75))
}

/// The presence discriminator again: a `nil` timestamp must not collide with the
/// reference date itself, whose `timeIntervalSinceReferenceDate` is exactly 0 and
/// whose bit pattern is all zeroes.
@Test func approvalBytesDistinguishNoTimestampFromTheReferenceDate() {
    let none = Derived(value: 42, origin: .authored(Authorship(note: "n")))
    let epoch = Derived(value: 42, origin: .authored(
        Authorship(note: "n", at: Date(timeIntervalSinceReferenceDate: 0))))
    #expect(none.approvalBytes != epoch.approvalBytes)
}

@Test func approvalBytesChangeWithTheAuthorshipNote() {
    #expect(Derived(value: 42, origin: .authored(Authorship(note: "a"))).approvalBytes
         != Derived(value: 42, origin: .authored(Authorship(note: "b"))).approvalBytes)
}

// MARK: - The payload is encoded canonically, not through Codable

/// The reason `Value` is constrained to `CanonicallyEncodable` rather than
/// `Codable`: a payload routed through `JSONEncoder` renders `Double` as decimal
/// text, which is exactly what `DisplayGeometry` rejects one layer up. Adjacent
/// doubles must not collapse.
@Test func doubleValuedPayloadsAreDigestedBitExactly() {
    let a = NormalizedFrame(origin: NormalizedPoint(x: 0.25, y: 0.5),
                            size: NormalizedSize(width: 0.5, height: 0.25), revision: revision)
    let b = NormalizedFrame(origin: NormalizedPoint(x: 0.25.nextUp, y: 0.5),
                            size: NormalizedSize(width: 0.5, height: 0.25), revision: revision)
    #expect(Derived(value: a, origin: .authored(Authorship(note: "n"))).approvalBytes
         != Derived(value: b, origin: .authored(Authorship(note: "n"))).approvalBytes)
}

/// The payload's own geometry revision participates: the same numbers normalised
/// against a different display configuration are a different frame (D-P2), and an
/// approval must not carry across.
@Test func payloadGeometryRevisionParticipates() {
    let a = NormalizedFrame(origin: NormalizedPoint(x: 0.25, y: 0.5),
                            size: NormalizedSize(width: 0.5, height: 0.25), revision: revision)
    let b = NormalizedFrame(origin: NormalizedPoint(x: 0.25, y: 0.5),
                            size: NormalizedSize(width: 0.5, height: 0.25),
                            revision: GeometryRevision(id: revision.id ^ 1))
    #expect(Derived(value: a, origin: .authored(Authorship(note: "n"))).approvalBytes
         != Derived(value: b, origin: .authored(Authorship(note: "n"))).approvalBytes)
}

@Test func normalizedFrameCanonicalBytesAreFixedWidth() {
    var bytes: [UInt8] = []
    NormalizedFrame(origin: NormalizedPoint(x: 0.25, y: 0.5),
                    size: NormalizedSize(width: 0.5, height: 0.25),
                    revision: revision).encodeCanonically(into: &bytes)
    #expect(bytes.count == 40)          // 4 doubles + one UInt64 revision
}

/// Recorded rather than discovered later: `String`'s canonical bytes are its raw
/// UTF-8, with no Unicode normalisation. Two canonically-equivalent strings
/// therefore compare `==` in Swift but produce DIFFERENT approval bytes.
///
/// This is deliberate and it fails closed — the mismatch asks a person to
/// re-approve; it never lets an approval be redeemed against different text.
/// The alternative (NFC via `precomposedStringWithCanonicalMapping`) makes the
/// digest depend on the ICU tables of whichever macOS version happens to be
/// running, which would silently invalidate every stored approval on an OS
/// update — a much larger failure, and one whose cause would be invisible.
/// If this test ever goes red because someone added normalisation, read this
/// comment before "fixing" it.
@Test func canonicallyEquivalentStringsDoNotShareApprovalBytes() {
    let precomposed = "caf\u{00E9}"          // é as one scalar
    let decomposed = "cafe\u{0301}"          // e + combining acute
    #expect(precomposed == decomposed)       // Swift says these are the same String
    #expect(Derived(value: precomposed, origin: .authored(Authorship(note: "n"))).approvalBytes
         != Derived(value: decomposed, origin: .authored(Authorship(note: "n"))).approvalBytes)
}

// MARK: - The pinned encoding
//
// THIS IS THE CROSS-PROCESS CHECK, and it is the reason these literals are not
// read off a green run. A process's hash seed is fixed for its lifetime, so
// computing the same bytes twice inside one test proves nothing — that is exactly
// how this class of bug survives ordinary testing (design doc § Canonical
// encoding). Each literal below was computed in a *different* process, by a
// Python program written from the encoding specification in `Derived.swift`, so
// every subsequent `swift test` (a new process, a new seed) compares against
// bytes this implementation did not produce.
//
// They also pin the LAYOUT, not merely the value, so a reordering of fields that
// happened to preserve a digest is still caught and the failure names which field
// moved.
//
// Frozen. Changing any of these is a breaking change to every approval already
// recorded: it ships with `CanonicalEncoding.version` bumped and a re-approval
// path, never as a quiet edit.

/// ```
/// 01                                 encoding version
/// 0800000000000000                   value length = 8
/// 2a00000000000000                   Int 42, little-endian
/// 01                                 origin tag: .generated
/// 1200000000000000                   producer length = 18
/// 7265666572656e63652d70726f6475636572   "reference-producer"
/// 0300000000000000                   producerVersion = 3
/// 0200000000000000                   evidence count = 2
/// 01                                 ref 0 kind = observation
/// 6ba7b8109dad11d180b400c04fd430c8   ref 0 id
/// 11 × 32                            ref 0 contentDigest
/// 01                                 ref 0 has a sourceInterval
/// 6495b81d14d14e058851dd30be41d757   ref 0 interval's epoch id (testEpoch)
/// e803000000000000                   start   = 1000ns
/// fa00000000000000                   duration = 250ns
/// 02                                 ref 1 kind = transcript
/// 6ba7b8119dad11d180b400c04fd430c8   ref 1 id
/// 22 × 32                            ref 1 contentDigest
/// 00                                 ref 1 has NO sourceInterval
/// 00 × 32                            zeroed, per the fixed-width rule
/// 01                                 outcome = .accepted
/// ```
///
/// **This vector moved in Task 2.** `sourceInterval` changed from
/// `TimeRange?` to `HostRange?`, which added the epoch's 16 bytes ahead of
/// `start`/`duration` inside a present interval, and widened the
/// absent-interval padding from 16 to 32 zero bytes to match. Every byte of
/// this vector through the end of `ref 0 contentDigest` — the first 109
/// bytes of the full `approvalBytes` stream, not an offset local to
/// `EvidenceRef`'s own table above — is unchanged from the pre-Task-2 vector,
/// confirmed by diffing the two byte-for-byte rather than by inspection; the
/// divergence begins exactly at the interval, the only field that changed
/// shape. Recomputed out of band in Python from the encoding specification
/// above, not read off a green run; see the Task 2 report for the script and
/// the byte-level diff against the old vector.
@Test func approvalBytesArePinnedForAGeneratedValue() {
    #expect(hex(generated(42).approvalBytes) == """
        01\
        08000000000000002a00000000000000\
        01\
        12000000000000007265666572656e63652d70726f6475636572\
        0300000000000000\
        0200000000000000\
        016ba7b8109dad11d180b400c04fd430c8\
        1111111111111111111111111111111111111111111111111111111111111111\
        016495b81d14d14e058851dd30be41d757e803000000000000fa00000000000000\
        026ba7b8119dad11d180b400c04fd430c8\
        2222222222222222222222222222222222222222222222222222222222222222\
        000000000000000000000000000000000000000000000000000000000000000000\
        01
        """)
    #expect(generated(42).approvalBytes.count == 225)
}

/// The `Double`-bearing, authored counterpart:
/// ```
/// 01                                 encoding version
/// 2800000000000000                   value length = 40
/// 000000000000d03f                   0.25   bit pattern
/// 000000000000e03f                   0.5
/// 000000000000e03f                   0.5
/// 000000000000d03f                   0.25
/// e02bb4dcd79ef4bc                   GeometryRevision id
/// 02                                 origin tag: .authored
/// 1100000000000000                   note length = 17
/// 6f70657261746f72206f76657272696465 "operator override"
/// 01                                 a timestamp is present
/// 0000000081842e41                   1000000.5 bit pattern
/// ```
@Test func approvalBytesArePinnedForAnAuthoredDoubleValuedPayload() {
    #expect(hex(authoredFrame.approvalBytes) == """
        01\
        2800000000000000\
        000000000000d03f000000000000e03f000000000000e03f000000000000d03f\
        e02bb4dcd79ef4bc\
        02\
        1100000000000000\
        6f70657261746f72206f76657272696465\
        01\
        0000000081842e41
        """)
    #expect(authoredFrame.approvalBytes.count == 84)
}

/// Pins the rejected branch and its length-prefixed gate code.
///
/// **This vector moved in Task 2** for the same reason
/// `approvalBytesArePinnedForAGeneratedValue`'s did — see that test's comment.
@Test func approvalBytesArePinnedForARejectedOutcome() {
    let rejected = Derived(value: 42, origin: .generated(
        Derivation(producer: ProducerID("reference-producer"), producerVersion: 3,
                   evidence: twoRefs, outcome: .rejected(GateCode("insufficient-evidence")))))
    #expect(hex(rejected.approvalBytes) == """
        01\
        08000000000000002a00000000000000\
        01\
        12000000000000007265666572656e63652d70726f6475636572\
        0300000000000000\
        0200000000000000\
        016ba7b8109dad11d180b400c04fd430c8\
        1111111111111111111111111111111111111111111111111111111111111111\
        016495b81d14d14e058851dd30be41d757e803000000000000fa00000000000000\
        026ba7b8119dad11d180b400c04fd430c8\
        2222222222222222222222222222222222222222222222222222222222222222\
        000000000000000000000000000000000000000000000000000000000000000000\
        02\
        1500000000000000\
        696e73756666696369656e742d65766964656e6365
        """)
    #expect(rejected.approvalBytes.count == 254)
}

/// The bytes must not be `hashValue` under another name, nor derived from it:
/// `Hasher` is seeded per process, and a digest built on it would differ on every
/// launch. Asserted against a value that cannot have come from a seeded hash.
@Test func approvalBytesAreNotDerivedFromTheSeededHashValue() {
    let d = generated(42)
    let seeded = UInt64(bitPattern: Int64(d.hashValue)).littleEndianBytes
    #expect(!hex(d.approvalBytes).contains(hex(Data(seeded))))
}

// MARK: - applyingProduced: the only way a producer may write a result

@Test func applyingProducedLeavesAnAuthoredValueUntouched() {
    let authored = Derived(value: 99, origin: .authored(Authorship(note: "operator override")),
                           review: .approved)
    let produced = generated(2)
    let result = authored.applyingProduced(produced)
    #expect(result.value == 99)
    guard case .authored = result.origin else { Issue.record("origin replaced"); return }
    #expect(result.review == .approved)
}

@Test func applyingProducedReplacesAGeneratedValue() {
    let existing = generated(2)
    let produced = generated(7)
    #expect(existing.applyingProduced(produced).value == 7)
}

/// The hole this closes: a value that was approved, then re-derived to something
/// different, must NOT keep its approval. Approval binds to `approvalBytes`; if
/// those bytes changed, the approval no longer describes what is there.
@Test func applyingProducedResetsReviewWhenTheApprovalBytesChange() {
    var existing = generated(2)
    existing.review = .approved
    let result = existing.applyingProduced(generated(7))
    #expect(result.review == .pending)
    #expect(result.approvalBytes != existing.approvalBytes)
}

/// The converse, and it is not a convenience: a re-run that produces the same
/// value and the same origin produces the same `approvalBytes`, so the existing
/// approval still describes exactly what is there and dropping it would be a
/// spurious re-approval prompt.
@Test func applyingProducedKeepsReviewWhenTheApprovalBytesAreUnchanged() {
    var existing = generated(2)
    existing.review = .approved
    let result = existing.applyingProduced(generated(2))
    #expect(result.review == .approved)
    #expect(result.approvalBytes == existing.approvalBytes)
}

/// A producer may not mark its own output approved. `review` on the produced
/// value is discarded, always.
@Test func applyingProducedDiscardsAProducersOwnReviewState() {
    let existing = generated(2)
    var produced = generated(7)
    produced.review = .approved
    #expect(existing.applyingProduced(produced).review == .pending)
}

@Test func applyingProducedIsIdempotent() {
    let existing = generated(2)
    let once = existing.applyingProduced(generated(7))
    let twice = once.applyingProduced(generated(7))
    #expect(once == twice)
}

/// The producer-value rule, run repeatedly: an override survives any number of
/// production passes, not just the first (the full form lands in Task 14).
@Test func repeatedProductionNeverErasesAnOverride() {
    var result = Derived(value: 99, origin: .authored(Authorship(note: "operator override")),
                         review: .approved)
    for i in 0..<5 { result = result.applyingProduced(generated(i)) }
    #expect(result.value == 99)
    #expect(result.review == .approved)
}

// MARK: - Codable is the document path, and it is separate

@Test func derivedRoundTripsThroughCodable() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let decoded = try JSONDecoder().decode(Derived<Int>.self, from: encoder.encode(generated(42)))
    #expect(decoded == generated(42))
}

/// The property that makes the split safe: a value that has been to disk and
/// back must still bind to the same approval.
@Test func approvalBytesSurviveACodableRoundTrip() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let decoded = try JSONDecoder().decode(Derived<Int>.self, from: encoder.encode(generated(42)))
    #expect(decoded.approvalBytes == generated(42).approvalBytes)

    let frame = try JSONDecoder().decode(Derived<NormalizedFrame>.self,
                                         from: encoder.encode(authoredFrame))
    #expect(frame.approvalBytes == authoredFrame.approvalBytes)
}

@Test func anApprovedReviewStateSurvivesACodableRoundTrip() throws {
    var d = generated(42)
    d.review = .approved
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let decoded = try JSONDecoder().decode(Derived<Int>.self, from: encoder.encode(d))
    #expect(decoded.review == .approved)
}

/// The document path must not be able to smuggle in citation-free evidence: the
/// non-empty guarantee `Evidence` enforces on decode reaches `Derived` too.
@Test func derivedRejectsAGeneratedOriginWithEmptyEvidenceOnDecode() {
    let json = Data("""
    {"value":42,"origin":{"generated":{"_0":{"producer":"p","producerVersion":1,\
    "evidence":[],"outcome":{"accepted":{}}}}},"review":"pending"}
    """.utf8)
    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(Derived<Int>.self, from: json)
    }
}

@Test func reviewStatesRoundTripAsTheirRawStrings() throws {
    for state in [ReviewState.pending, .approved, .rejected] {
        #expect(try JSONDecoder().decode(ReviewState.self,
                                         from: JSONEncoder().encode(state)) == state)
    }
}

@Test func derivedDefaultsToPendingReview() {
    #expect(generated(42).review == .pending)
}

// MARK: - ProducerID / GateCode

@Test func producerIDCarriesItsRawValue() {
    #expect(ProducerID("reference-producer").rawValue == "reference-producer")
    #expect(ProducerID("a") != ProducerID("b"))
}

@Test func gateCodeCarriesItsRawValue() {
    #expect(GateCode("insufficient-evidence").rawValue == "insufficient-evidence")
    #expect(GateCode("a") != GateCode("b"))
}

@Test func producerIDAndGateCodeRoundTripAsBareStrings() throws {
    let producer = try JSONDecoder().decode(ProducerID.self,
                                            from: Data("\"reference-producer\"".utf8))
    #expect(producer == ProducerID("reference-producer"))
    let code = try JSONDecoder().decode(GateCode.self, from: Data("\"stale-evidence\"".utf8))
    #expect(code == GateCode("stale-evidence"))
}
