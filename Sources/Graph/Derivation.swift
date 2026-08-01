import Foundation
import Geometry
import Timeline

/// Names the producer that computed a value — `"framing-producer"`,
/// `"beat-producer"`. A string wrapper rather than an enum because producers
/// arrive one phase at a time and a closed enum here would force every later
/// phase to edit this module.
///
/// `Hashable` so a `Derivation` is, and `RawRepresentable` so it encodes as a
/// bare JSON string rather than a wrapping object.
public struct ProducerID: Hashable, Sendable, RawRepresentable {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(rawValue: String) { self.rawValue = rawValue }
}

extension ProducerID: Codable {
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension ProducerID: CustomStringConvertible {
    public var description: String { rawValue }
}

/// Why a gate rejected a derivation — `"insufficient-evidence"`,
/// `"stale-evidence"`, `"below-confidence-threshold"`. A string wrapper for the
/// same reason as `ProducerID`: the gates are defined by the phases that add
/// them, not by this module.
public struct GateCode: Hashable, Sendable, RawRepresentable {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(rawValue: String) { self.rawValue = rawValue }
}

extension GateCode: Codable {
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension GateCode: CustomStringConvertible {
    public var description: String { rawValue }
}

/// Whether the producer's gates accepted the derivation, and if not, which gate
/// rejected it.
///
/// A rejected derivation is still recorded, with its evidence: "the producer ran
/// and refused" is a different, and more useful, fact than "nothing happened".
/// It is digest-significant — a value whose gate verdict flipped is not the same
/// thing a person approved.
public enum Outcome: Codable, Hashable, Sendable {
    case accepted
    case rejected(GateCode)
}

/// The record of one producer run that yielded a value (design doc D-P4).
///
/// **`evidence` is non-optional and `Evidence` has no empty representation**, so
/// `Origin.generated` cannot be spelled without at least one citation. That is
/// the whole point: an uncited generated value is not a runtime check that could
/// be skipped, it is unrepresentable. Phase 6's evaluations harness then asserts
/// a property the type system already guarantees.
public struct Derivation: Codable, Hashable, Sendable {
    public let producer: ProducerID
    /// The producer's own version. Bumping it re-derives: two values computed by
    /// different versions of the same producer are different claims, so this is
    /// digest-significant and an approval does not carry across a bump.
    public let producerVersion: Int
    public let evidence: Evidence
    public let outcome: Outcome

    public init(producer: ProducerID, producerVersion: Int, evidence: Evidence, outcome: Outcome) {
        self.producer = producer
        self.producerVersion = producerVersion
        self.evidence = evidence
        self.outcome = outcome
    }
}

/// A human's act of authoring or overriding a value.
///
/// **It carries no evidence, deliberately.** A person owes no citation — that
/// asymmetry is the product thesis in the type system: automation must justify
/// itself, a person need not.
///
/// **It carries a timestamp, and the timestamp IS digest-significant.** Decided
/// explicitly rather than discovered later, because both halves of that choice
/// are load-bearing:
///
/// * *Why carry one at all.* Adding a field to a digested type later changes
///   every digest ever computed — the exact hazard `CanonicalEncoding.version`
///   exists for. The field exists from the first version, so later versions
///   populate it without a re-approval event.
/// * *Why digest it.* The same value authored at two different moments is two
///   distinct human acts. An approval bound to one should not validate the
///   other; re-authoring is a thing a person did, and the gate should see it.
///
/// `at` is optional, and `nil` is distinguished from any real instant by a
/// presence byte in the canonical encoding — not folded onto the reference date,
/// whose bit pattern is all zeroes. It is optional because this package cannot
/// mint a `Date`: `Date()` is a banned symbol (§ Determinism), so every
/// timestamp is passed in from the app, and a caller that has no timestamp to
/// pass must be able to say so rather than invent one.
public struct Authorship: Codable, Hashable, Sendable {
    /// What the person said about the override. Free text, and it is digested:
    /// the note is part of what a reviewer read.
    public let note: String
    public let at: Date?

    /// Traps on a non-finite `at`. Like every precondition in this package this
    /// cannot be exercised with `#expect` — a precondition failure kills the
    /// process. It is what makes the canonical encoding of `at` well defined:
    /// NaN has many bit patterns, so a NaN timestamp would be many digests for
    /// one value.
    public init(note: String, at: Date? = nil) {
        if let at {
            precondition(at.timeIntervalSinceReferenceDate.isFinite,
                         "Authorship.at must be a finite instant")
        }
        self.note = note
        self.at = at
    }
}

/// Where a value came from (design doc D-P4).
///
/// The two cases are not symmetric, and that asymmetry is the point:
/// `.generated` requires a `Derivation`, which requires non-empty `Evidence`;
/// `.authored` requires none. Automation proposes and must cite; a person
/// decides and need not.
public enum Origin: Codable, Hashable, Sendable {
    case generated(Derivation)
    case authored(Authorship)
}

// MARK: - Canonical encoding
//
// FROZEN. These layouts are what `Derived.approvalBytes` concatenates, and
// therefore what Phase 8's `approval-gate` binds human approval to. Changing any
// of them changes every approval already recorded: it ships with
// `CanonicalEncoding.version` bumped and a re-approval path, never as a quiet
// edit. `Tests/GraphTests/DerivedTests.swift` pins the bytes against literals
// computed out of band, so a change here fails loudly.
//
// None of this goes through `Codable`. The `Codable` conformances above are the
// document path: reusing them would couple every stored approval to the JSON
// shape, so a later change to the document format would silently change digests
// — validation quietly checking a different thing, which is worse than failing.
//
// Every field is fixed-width little-endian except where a length prefix is
// noted; see `CanonicalEncoding` point 4 for why prefixes are permitted here and
// not in `DisplayGeometry`.

extension EvidenceKind {
    /// The digest tag for a kind. Deliberately **not** `rawValue.utf8`: the raw
    /// string is the JSON spelling and belongs to the document path, and it is
    /// variable-length, which would cost this record its fixed width. One byte,
    /// frozen — a case renamed in JSON must not move a digest, and a new case
    /// gets the next unused number, never a reused one.
    var canonicalTag: UInt8 {
        switch self {
        case .observation: 0x01
        case .transcript:  0x02
        case .release:     0x03
        }
    }
}

extension TimeRange {
    /// 16 bytes: `start` ‖ `duration`, nanoseconds, two's complement
    /// little-endian.
    ///
    /// A plain method, deliberately not a `CanonicallyEncodable` conformance:
    /// `TimeRange` belongs to `Timeline` and the protocol to `Geometry`, so
    /// declaring the conformance here — in a third module that owns neither —
    /// would be a retroactive conformance, which two modules could later declare
    /// incompatibly. `Timeline` cannot declare it either: it depends on nothing,
    /// and that is the property that makes it a leaf (D-P1). This encoding is
    /// only ever reached from `EvidenceRef`, inside this module.
    ///
    /// `start` and `duration` rather than `start` and `end`: two citations with
    /// the same total extent but a different split are different citations, and
    /// digesting a derived `end` alone would collapse them.
    func encodeCanonically(into bytes: inout [UInt8]) {
        CanonicalEncoding.appendInt64(start.rawValue, to: &bytes)
        CanonicalEncoding.appendInt64(duration.rawValue, to: &bytes)
    }
}

extension EvidenceRef: CanonicallyEncodable {
    /// 66 bytes, fixed width — which is what lets `Evidence` prefix a count and
    /// nothing else:
    ///
    /// | offset | bytes | field |
    /// | --- | --- | --- |
    /// | 0 | 1 | `kind.canonicalTag` |
    /// | 1 | 16 | `id`, RFC 4122 byte order |
    /// | 17 | 32 | `contentDigest.bytes` |
    /// | 49 | 1 | `sourceInterval` present: `0x00` absent, `0x01` present |
    /// | 50 | 16 | the interval, or sixteen zero bytes when absent |
    ///
    /// **The presence byte is not redundant.** `nil` and
    /// `TimeRange(start: 0, duration: 0)` have identical payload bytes, and Task
    /// 12 recorded that the distinction is `Hashable`-significant on this type.
    /// Without the discriminator, evidence could be re-cited as covering a
    /// whole record instead of an instant of it — narrower or broader than what
    /// was actually reviewed — with no change to the digest.
    public func encodeCanonically(into bytes: inout [UInt8]) {
        bytes.append(kind.canonicalTag)
        // Expanded explicitly rather than via `withUnsafeBytes`, because
        // `.strictMemorySafety()` is enabled package-wide. The tuple order is
        // the UUID's own network byte order, so this is endian-independent.
        let u = id.uuid
        bytes.append(contentsOf: [u.0, u.1, u.2,  u.3,  u.4,  u.5,  u.6,  u.7,
                                  u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15])
        bytes.append(contentsOf: contentDigest.bytes)
        if let sourceInterval {
            bytes.append(0x01)
            sourceInterval.encodeCanonically(into: &bytes)
        } else {
            bytes.append(0x00)
            bytes.append(contentsOf: [UInt8](repeating: 0, count: 16))
        }
    }
}

extension Evidence: CanonicallyEncodable {
    /// A `UInt64` count, then that many fixed-width `EvidenceRef` records in
    /// order. The count is what makes the boundary between the last citation and
    /// whatever follows it determinable from bytes already read.
    ///
    /// Order is digest-significant: the citations are a sequence, and a producer
    /// that reordered them made a different claim about which evidence it read
    /// first.
    public func encodeCanonically(into bytes: inout [UInt8]) {
        CanonicalEncoding.appendCount(count, to: &bytes)
        for ref in self { ref.encodeCanonically(into: &bytes) }
    }
}

extension Outcome: CanonicallyEncodable {
    /// `0x01` accepted; `0x02` rejected, followed by the length-prefixed UTF-8
    /// of the gate code. Tags start at 1 so that a zeroed buffer is not a valid
    /// encoding of anything.
    public func encodeCanonically(into bytes: inout [UInt8]) {
        switch self {
        case .accepted:
            bytes.append(0x01)
        case .rejected(let code):
            bytes.append(0x02)
            CanonicalEncoding.appendLengthPrefixed(code.rawValue, to: &bytes)
        }
    }
}

extension Derivation: CanonicallyEncodable {
    /// `producer` (length-prefixed UTF-8) ‖ `producerVersion` (8, little-endian)
    /// ‖ `evidence` (count-prefixed, 66 bytes each) ‖ `outcome`
    /// (self-delimiting).
    public func encodeCanonically(into bytes: inout [UInt8]) {
        CanonicalEncoding.appendLengthPrefixed(producer.rawValue, to: &bytes)
        CanonicalEncoding.appendInt64(Int64(producerVersion), to: &bytes)
        evidence.encodeCanonically(into: &bytes)
        outcome.encodeCanonically(into: &bytes)
    }
}

extension Authorship: CanonicallyEncodable {
    /// `note` (length-prefixed UTF-8) ‖ a presence byte for `at` ‖ 8 bytes:
    /// `at.timeIntervalSinceReferenceDate`'s bit pattern, or zeroes when absent.
    ///
    /// The presence byte carries real information here: the reference date's own
    /// interval is exactly `0`, whose bit pattern is also all zeroes, so without
    /// it "no timestamp" and "authored at 2001-01-01T00:00:00Z" would digest
    /// identically.
    ///
    /// `timeIntervalSinceReferenceDate` is the *instance* property — a read of a
    /// stored value, not of a clock. The static property of the same name is a
    /// clock read and is a banned symbol; the two differ by one character at the
    /// source level and by one character in their mangled names, which is why
    /// the determinism check matches symbols exactly and never by substring.
    public func encodeCanonically(into bytes: inout [UInt8]) {
        CanonicalEncoding.appendLengthPrefixed(note, to: &bytes)
        if let at {
            bytes.append(0x01)
            CanonicalEncoding.appendDouble(at.timeIntervalSinceReferenceDate, to: &bytes)
        } else {
            bytes.append(0x00)
            bytes.append(contentsOf: [UInt8](repeating: 0, count: 8))
        }
    }
}

extension Origin: CanonicallyEncodable {
    /// `0x01` generated, followed by the derivation; `0x02` authored, followed
    /// by the authorship. Tags start at 1 for the same reason as `Outcome`'s.
    public func encodeCanonically(into bytes: inout [UInt8]) {
        switch self {
        case .generated(let derivation):
            bytes.append(0x01)
            derivation.encodeCanonically(into: &bytes)
        case .authored(let authorship):
            bytes.append(0x02)
            authorship.encodeCanonically(into: &bytes)
        }
    }
}
