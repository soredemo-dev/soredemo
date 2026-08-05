import Testing
import Foundation
@testable import Graph
import Geometry
import Timeline

// MARK: - Fixtures
//
// Not at an identity element: TWO refs (one hides a dropped tail or count prefix),
// exactly one carrying a `sourceInterval` (`nil` vs `.some` must stay significant),
// and a `Double`-bearing payload (no `Int` catches a `Codable` route to decimal).

private let observationID = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!
private let transcriptID = UUID(uuidString: "6BA7B811-9DAD-11D1-80B4-00C04FD430C8")!
private let releaseID = UUID(uuidString: "6BA7B812-9DAD-11D1-80B4-00C04FD430C8")!

private let testEpoch = BootEpoch(id: UUID(uuidString: "6495B81D-14D1-4E05-8851-DD30BE41D757")!)

private func digest(_ seed: UInt8) -> ContentDigest {
    ContentDigest(Array(repeating: seed, count: ContentDigest.byteCount))
}

/// Not `String(format:)`, which is unsafe under `.strictMemorySafety()` and warns.
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

/// `Derived<Int>` — the simplest payload shape.
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
// A type-system property: `Derivation.init` takes a non-optional `Evidence`, which
// has no empty representation. The real guarantee is that the alternative won't build.

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
// Approving mutates `review`; if `review` were digested, the approval would
// invalidate the very bytes it was just recorded against.

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

/// The case a single-ref fixture cannot reach: a dropped tail or a lost count prefix.
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

/// A zero-length interval **at the zero epoch** on purpose: it is the only fixture
/// that catches an encoder writing payload but no `nil`/`.some` discriminator, since
/// both sides are all-zero payload bytes. `testEpoch` here would defeat that.
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
    // Same total extent, different split: an encoder digesting `end` alone collapses.
    #expect(cited(1_000, 250) != cited(1_250, 0))
}

/// Identical `start`/`duration` under different boot epochs are different citations;
/// an encoder that dropped `epoch` would pass every other test in this file.
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

/// The fixed-width invariant: `Evidence` prefixes a bare count and nothing else, so
/// present-interval payload and absent-interval padding must stay the same width.
@Test func evidenceRefEncodesToTheSameWidthWithAndWithoutAnInterval() {
    var withInterval: [UInt8] = []
    refWithInterval.encodeCanonically(into: &withInterval)
    var withoutInterval: [UInt8] = []
    refWithoutInterval.encodeCanonically(into: &withoutInterval)
    #expect(withInterval.count == withoutInterval.count)
    #expect(withInterval.count == 82)
}

// MARK: - Length prefixes: adjacent variable-length fields must not run together

/// The classic concatenation collapse: these two differ only in where the boundary
/// falls, so without length prefixes they encode identically.
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

/// Variable-length and self-delimiting in neither direction — the only fixture that
/// exercises the outer length prefix (`Int` is fixed-width, `String` prefixes itself).
private struct RawPayload: CanonicallyEncodable, Codable, Hashable, Sendable {
    let bytes: [UInt8]
    init(_ bytes: [UInt8]) { self.bytes = bytes }
    func encodeCanonically(into out: inout [UInt8]) { out.append(contentsOf: bytes) }
}

/// Why the *value*'s length prefix is load-bearing: delete it and a rejected
/// derivation whose gate code ends in an authored origin's bytes collides with it.
@Test func valueLengthPrefixDefeatsAConstructedCollision() {
    let inner = Origin.authored(Authorship(note: "n"))
    var innerBytes: [UInt8] = []
    inner.encodeCanonically(into: &innerBytes)

    let outer = Origin.generated(Derivation(
        producer: ProducerID("p"), producerVersion: 1, evidence: twoRefs,
        outcome: .rejected(GateCode(String(decoding: innerBytes, as: UTF8.self)))))
    var outerBytes: [UInt8] = []
    outer.encodeCanonically(into: &outerBytes)

    // The construction means nothing unless the inner origin really is a suffix.
    #expect(Array(outerBytes.suffix(innerBytes.count)) == innerBytes)

    let generated = Derived(value: RawPayload([]), origin: outer)
    let authored = Derived(value: RawPayload(Array(outerBytes.dropLast(innerBytes.count))),
                           origin: inner)
    #expect(generated.approvalBytes != authored.approvalBytes)
}

/// Why `Evidence`'s count prefix is load-bearing: strip it and two-refs-accepted
/// collides with one-ref-rejected replaying the second citation in its gate code.
@Test func evidenceCountPrefixDefeatsAConstructedCollision() {
    // 4a00000000000000 = 74, little-endian, in the first eight bytes.
    let craftedID = UUID(uuidString: "4A000000-0000-0000-6162-636465666768")!
    let craftedDigest = ContentDigest(Array("0123456789abcdef0123456789abcdef".utf8))
    let secondRef = EvidenceRef(kind: .transcript, id: craftedID, contentDigest: craftedDigest)

    // UUID's second half ‖ digest ‖ absent-interval padding ‖ the .accepted tag.
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

/// `Authorship`'s timestamp IS digest-significant: two moments, two human acts.
@Test func approvalBytesChangeWithTheAuthoringTimestamp() {
    func authored(_ seconds: Double) -> Data {
        Derived(value: 42, origin: .authored(
            Authorship(note: "operator override",
                       at: Date(timeIntervalSinceReferenceDate: seconds)))).approvalBytes
    }
    #expect(authored(1_000_000.5) != authored(1_000_000.75))
}

/// The presence discriminator again: a `nil` timestamp must not collide with the
/// reference date, whose bit pattern is all zeroes.
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

/// Why `Value` is `CanonicallyEncodable` and not `Codable`: a `JSONEncoder` route
/// renders `Double` as decimal text, and adjacent doubles must not collapse.
@Test func doubleValuedPayloadsAreDigestedBitExactly() {
    let a = NormalizedFrame(origin: NormalizedPoint(x: 0.25, y: 0.5),
                            size: NormalizedSize(width: 0.5, height: 0.25), revision: revision)
    let b = NormalizedFrame(origin: NormalizedPoint(x: 0.25.nextUp, y: 0.5),
                            size: NormalizedSize(width: 0.5, height: 0.25), revision: revision)
    #expect(Derived(value: a, origin: .authored(Authorship(note: "n"))).approvalBytes
         != Derived(value: b, origin: .authored(Authorship(note: "n"))).approvalBytes)
}

/// The payload's geometry revision participates: the same numbers normalised against
/// a different display configuration are a different frame.
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

/// `String`'s canonical bytes are raw UTF-8 with no normalisation, so equivalent
/// strings compare `==` yet differ here. Deliberate and fail-closed: NFC would tie
/// the digest to the running OS's ICU tables and invalidate stored approvals.
@Test func canonicallyEquivalentStringsDoNotShareApprovalBytes() {
    let precomposed = "caf\u{00E9}"          // é as one scalar
    let decomposed = "cafe\u{0301}"          // e + combining acute
    #expect(precomposed == decomposed)       // Swift says these are the same String
    #expect(Derived(value: precomposed, origin: .authored(Authorship(note: "n"))).approvalBytes
         != Derived(value: decomposed, origin: .authored(Authorship(note: "n"))).approvalBytes)
}

// MARK: - The pinned encoding
//
// THE CROSS-PROCESS CHECK: a hash seed is fixed for a process's lifetime, so
// computing the same bytes twice in one test proves nothing. Each literal below was
// computed in a different process from the spec, and pins layout as well as value.
// Frozen: changing one is a breaking change needing a `CanonicalEncoding.version` bump.

/// Field order: version, length-prefixed value, origin tag, length-prefixed producer,
/// producer version, evidence count, the two refs, then the outcome tag.
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

/// The authored counterpart: four double bit patterns, the revision id, note, stamp.
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

/// Not `hashValue` under another name: `Hasher` is seeded per process, so a digest
/// built on it would differ on every launch.
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

/// Approval binds to `approvalBytes`, so a re-derived value must lose its approval.
@Test func applyingProducedResetsReviewWhenTheApprovalBytesChange() {
    var existing = generated(2)
    existing.review = .approved
    let result = existing.applyingProduced(generated(7))
    #expect(result.review == .pending)
    #expect(result.approvalBytes != existing.approvalBytes)
}

/// The converse: same bytes keeps the approval, or every re-run prompts spuriously.
@Test func applyingProducedKeepsReviewWhenTheApprovalBytesAreUnchanged() {
    var existing = generated(2)
    existing.review = .approved
    let result = existing.applyingProduced(generated(2))
    #expect(result.review == .approved)
    #expect(result.approvalBytes == existing.approvalBytes)
}

/// A producer may not mark its own output approved: its `review` is always discarded.
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

/// An override survives any number of production passes, not just the first.
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

/// A value that has been to disk and back must still bind to the same approval.
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

/// `Evidence`'s non-empty decode guarantee reaches `Derived`, so the document path
/// cannot smuggle in citation-free evidence.
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
