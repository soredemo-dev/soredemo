import Testing
import Foundation
@testable import Graph
import Timeline

private let observationID = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!
private let transcriptID = UUID(uuidString: "6BA7B811-9DAD-11D1-80B4-00C04FD430C8")!
private let releaseID = UUID(uuidString: "6BA7B812-9DAD-11D1-80B4-00C04FD430C8")!

private func digest(_ seed: UInt8) -> ContentDigest {
    ContentDigest(Array(repeating: seed, count: ContentDigest.byteCount))
}

/// Deliberately not `String(format:)`, which is an unsafe construct under
/// `.strictMemorySafety()` and warns. Matches the helper in `DigestTests.swift`.
private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { byte in
        let s = String(byte, radix: 16)
        return s.count == 1 ? "0" + s : s
    }.joined()
}

// MARK: - ContentDigest: construction

@Test func contentDigestAcceptsExactly32Bytes() {
    let d = ContentDigest(Array(repeating: 0xAB, count: 32))
    #expect(d.bytes.count == 32)
}

@Test func contentDigestByteCountIs32() {
    #expect(ContentDigest.byteCount == 32)
}

// MARK: - ContentDigest: decode validation (the untrusted-input path)

/// This is the case the design doc's staleness/approval-binding rationale
/// actually depends on: a digest arriving from disk, not one this package
/// constructed itself.
@Test func contentDigestRejects31BytesOnDecode() {
    let json = Data(("[" + (0..<31).map { _ in "1" }.joined(separator: ",") + "]").utf8)
    #expect(throws: ContentDigest.DecodingFailure.self) {
        _ = try JSONDecoder().decode(ContentDigest.self, from: json)
    }
}

@Test func contentDigestRejects33BytesOnDecode() {
    let json = Data(("[" + (0..<33).map { _ in "1" }.joined(separator: ",") + "]").utf8)
    #expect(throws: ContentDigest.DecodingFailure.self) {
        _ = try JSONDecoder().decode(ContentDigest.self, from: json)
    }
}

@Test func contentDigestDecodingFailureNamesTheOffendingByteCount() {
    let json = Data(("[" + (0..<31).map { _ in "1" }.joined(separator: ",") + "]").utf8)
    do {
        _ = try JSONDecoder().decode(ContentDigest.self, from: json)
        Issue.record("expected DecodingFailure")
    } catch let failure as ContentDigest.DecodingFailure {
        #expect(failure.byteCount == 31)
    } catch {
        Issue.record("expected ContentDigest.DecodingFailure, got \(error)")
    }
}

@Test func contentDigestAccepts32BytesOnDecode() throws {
    let json = Data(("[" + (0..<32).map { _ in "7" }.joined(separator: ",") + "]").utf8)
    let decoded = try JSONDecoder().decode(ContentDigest.self, from: json)
    #expect(decoded.bytes == Array(repeating: 7, count: 32))
}

// MARK: - ContentDigest: encode/round-trip

@Test func contentDigestSurvivesACodableRoundTrip() throws {
    let d = digest(0x42)
    let decoded = try JSONDecoder().decode(ContentDigest.self, from: JSONEncoder().encode(d))
    #expect(decoded == d)
}

/// Encodes as a flat array of numbers, not a wrapping object — there is no
/// key for `.sortedKeys` to have anything to do here.
@Test func contentDigestEncodesAsAFlatArray() throws {
    let d = digest(0x01)
    let data = try JSONEncoder().encode(d)
    let raw = try JSONDecoder().decode([UInt8].self, from: data)
    #expect(raw.count == 32)
    #expect(raw == d.bytes)
}

// MARK: - ContentDigest: identity/comparison

@Test func contentDigestsWithEqualBytesAreEqual() {
    #expect(digest(0x11) == digest(0x11))
}

@Test func contentDigestsWithDifferentBytesAreNotEqual() {
    #expect(digest(0x11) != digest(0x22))
}

@Test func contentDigestDescriptionIsFixedWidthHex() {
    let d = ContentDigest(Array(repeating: 0x0A, count: 32))
    #expect(d.description == "ContentDigest(" + String(repeating: "0a", count: 32) + ")")
}

// MARK: - EvidenceRef

@Test func evidenceRefStoresAllFields() {
    let interval = TimeRange(start: Nanoseconds(0), duration: Nanoseconds(1_000))
    let ref = EvidenceRef(kind: .observation, id: observationID, contentDigest: digest(1), sourceInterval: interval)
    #expect(ref.kind == .observation)
    #expect(ref.id == observationID)
    #expect(ref.contentDigest == digest(1))
    #expect(ref.sourceInterval == interval)
}

@Test func evidenceRefSourceIntervalDefaultsToNil() {
    let ref = EvidenceRef(kind: .release, id: releaseID, contentDigest: digest(2))
    #expect(ref.sourceInterval == nil)
}

@Test func evidenceRefRoundTripsThroughCodableWithAnInterval() throws {
    let interval = TimeRange(start: Nanoseconds(500), duration: Nanoseconds(250))
    let ref = EvidenceRef(kind: .transcript, id: transcriptID, contentDigest: digest(3), sourceInterval: interval)
    let decoded = try JSONDecoder().decode(EvidenceRef.self, from: JSONEncoder().encode(ref))
    #expect(decoded == ref)
}

@Test func evidenceRefRoundTripsThroughCodableWithoutAnInterval() throws {
    let ref = EvidenceRef(kind: .observation, id: observationID, contentDigest: digest(4))
    let decoded = try JSONDecoder().decode(EvidenceRef.self, from: JSONEncoder().encode(ref))
    #expect(decoded == ref)
    #expect(decoded.sourceInterval == nil)
}

@Test func evidenceRefKindsRoundTripAsTheirRawStrings() throws {
    #expect(try JSONDecoder().decode(EvidenceKind.self, from: JSONEncoder().encode(EvidenceKind.observation)) == .observation)
    #expect(try JSONDecoder().decode(EvidenceKind.self, from: JSONEncoder().encode(EvidenceKind.transcript)) == .transcript)
    #expect(try JSONDecoder().decode(EvidenceKind.self, from: JSONEncoder().encode(EvidenceKind.release)) == .release)
}

// MARK: - Evidence: construction

@Test func evidenceVariadicInitStoresHeadAndTail() {
    let a = EvidenceRef(kind: .observation, id: observationID, contentDigest: digest(1))
    let b = EvidenceRef(kind: .transcript, id: transcriptID, contentDigest: digest(2))
    let evidence = Evidence(a, b)
    #expect(evidence.head == a)
    #expect(evidence.tail == [b])
}

@Test func evidenceVariadicInitAllowsASingleElement() {
    let a = EvidenceRef(kind: .release, id: releaseID, contentDigest: digest(1))
    let evidence = Evidence(a)
    #expect(evidence.head == a)
    #expect(evidence.tail.isEmpty)
}

/// The reason `Evidence` needs this initialiser at all: Swift cannot splat an
/// array into a variadic parameter, and Phase 3's framing producers hold
/// `[EvidenceRef]`.
@Test func evidenceArrayInitStoresHeadAndTail() throws {
    let a = EvidenceRef(kind: .observation, id: observationID, contentDigest: digest(1))
    let b = EvidenceRef(kind: .transcript, id: transcriptID, contentDigest: digest(2))
    let c = EvidenceRef(kind: .release, id: releaseID, contentDigest: digest(3))
    let evidence = try #require(Evidence([a, b, c]))
    #expect(evidence.head == a)
    #expect(evidence.tail == [b, c])
}

/// The load-bearing case: an uncited generated value must be unrepresentable,
/// in memory, not merely on disk.
@Test func evidenceArrayInitReturnsNilForAnEmptyArray() {
    #expect(Evidence([]) == nil)
}

@Test func evidenceArrayInitOfOneElementHasAnEmptyTail() throws {
    let a = EvidenceRef(kind: .observation, id: observationID, contentDigest: digest(1))
    let evidence = try #require(Evidence([a]))
    #expect(evidence.head == a)
    #expect(evidence.tail.isEmpty)
}

// MARK: - Evidence: RandomAccessCollection

@Test func evidenceCollectionOrderMatchesHeadThenTail() {
    let a = EvidenceRef(kind: .observation, id: observationID, contentDigest: digest(1))
    let b = EvidenceRef(kind: .transcript, id: transcriptID, contentDigest: digest(2))
    let c = EvidenceRef(kind: .release, id: releaseID, contentDigest: digest(3))
    let evidence = Evidence(a, b, c)
    #expect(Array(evidence) == [a, b, c])
    #expect(evidence.count == 3)
}

@Test func evidenceIsNeverEmptyAsACollection() {
    let evidence = Evidence(EvidenceRef(kind: .observation, id: observationID, contentDigest: digest(1)))
    #expect(!evidence.isEmpty)
    #expect(evidence.count == 1)
}

/// `Collection.first` is synthesised from `startIndex`/`subscript`, not from
/// the stored `head` property — they must agree, or `Evidence` has exactly
/// the `first`-shadowing trap this type was built to avoid by naming the
/// property `head` instead of `first`. `genericFirst` goes through a fully
/// generic `Collection` context, the path the design doc says silently
/// resolves to a *different* member when the stored property is named
/// `first`.
private func genericFirst<C: Collection>(_ c: C) -> C.Element? { c.first }

@Test func collectionFirstAgreesWithHead() {
    let a = EvidenceRef(kind: .observation, id: observationID, contentDigest: digest(1))
    let b = EvidenceRef(kind: .transcript, id: transcriptID, contentDigest: digest(2))
    let evidence = Evidence(a, b)
    #expect(evidence.first == evidence.head)
    #expect(genericFirst(evidence) == evidence.head)
}

// MARK: - Evidence: Codable, flat array shape

@Test func evidenceEncodesAsAFlatArrayNotAnObject() throws {
    let a = EvidenceRef(kind: .observation, id: observationID, contentDigest: digest(1))
    let b = EvidenceRef(kind: .transcript, id: transcriptID, contentDigest: digest(2))
    let evidence = Evidence(a, b)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(evidence)

    // Decoding the same bytes as a plain [EvidenceRef] must succeed and match
    // exactly, proving the wire shape is a flat array with no head/tail keys.
    let asPlainArray = try JSONDecoder().decode([EvidenceRef].self, from: data)
    #expect(asPlainArray == [a, b])
}

@Test func evidenceRoundTripsThroughCodable() throws {
    let a = EvidenceRef(kind: .observation, id: observationID, contentDigest: digest(1))
    let b = EvidenceRef(kind: .transcript, id: transcriptID, contentDigest: digest(2))
    let c = EvidenceRef(kind: .release, id: releaseID, contentDigest: digest(3))
    let evidence = Evidence(a, b, c)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let decoded = try JSONDecoder().decode(Evidence.self, from: encoder.encode(evidence))
    #expect(decoded == evidence)
    #expect(Array(decoded) == Array(evidence))
}

/// The load-bearing case, disk side: the non-empty guarantee must survive a
/// round trip through storage, not just live in memory. Without this
/// rejection, a corrupted or hand-edited document could read back as valid,
/// citation-free "evidence".
@Test func evidenceRejectsAnEmptyJSONArrayOnDecode() {
    let json = Data("[]".utf8)
    #expect(throws: Evidence.DecodingFailure.self) {
        _ = try JSONDecoder().decode(Evidence.self, from: json)
    }
}

@Test func evidenceDecodesASingleElementArray() throws {
    let a = EvidenceRef(kind: .observation, id: observationID, contentDigest: digest(9))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode([a])
    let decoded = try JSONDecoder().decode(Evidence.self, from: data)
    #expect(decoded.head == a)
    #expect(decoded.tail.isEmpty)
}

/// A malformed `contentDigest` nested inside one of the cited refs must still
/// surface as a decode failure — `Evidence`'s own emptiness check does not
/// swallow errors from the elements it decodes.
@Test func evidenceDecodePropagatesAMalformedNestedContentDigest() {
    let badRefJSON = """
    {"kind":"observation","id":"\(observationID.uuidString)","contentDigest":[1,2,3]}
    """
    let json = Data("[\(badRefJSON)]".utf8)
    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(Evidence.self, from: json)
    }
}
