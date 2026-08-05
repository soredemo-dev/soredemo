import Foundation
import Geometry
import Timeline

/// Names the producer that computed a value. A string wrapper, not an enum, so
/// later phases can add producers without editing this module; `RawRepresentable`
/// so it encodes as a bare JSON string.
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

/// Why a gate rejected a derivation. A string wrapper for the same reason as
/// `ProducerID`: gates are defined by the phases that add them.
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
/// rejected it. Rejected derivations are still recorded, and the verdict is
/// digest-significant.
public enum Outcome: Codable, Hashable, Sendable {
    case accepted
    case rejected(GateCode)
}

/// The record of one producer run that yielded a value. `evidence` is
/// non-optional and `Evidence` has no empty representation, so `Origin.generated`
/// cannot be spelled without at least one citation.
public struct Derivation: Codable, Hashable, Sendable {
    public let producer: ProducerID
    /// The producer's own version. Digest-significant: an approval does not carry
    /// across a bump.
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

/// A human's act of authoring or overriding a value. It carries no evidence by
/// design, and its timestamp is digest-significant. `at` is optional because
/// `Date()` is a banned symbol here, so callers pass every timestamp in; `nil`
/// is distinguished from any real instant by a presence byte in the encoding.
public struct Authorship: Codable, Hashable, Sendable {
    /// What the person said about the override. Free text, and digested.
    public let note: String
    public let at: Date?

    /// Traps on a non-finite `at`: NaN has many bit patterns, so it would give one
    /// value many digests.
    public init(note: String, at: Date? = nil) {
        if let at {
            precondition(at.timeIntervalSinceReferenceDate.isFinite,
                         "Authorship.at must be a finite instant")
        }
        self.note = note
        self.at = at
    }
}

/// Where a value came from. `.generated` requires a `Derivation`, and therefore
/// non-empty `Evidence`; `.authored` requires no citation.
public enum Origin: Codable, Hashable, Sendable {
    case generated(Derivation)
    case authored(Authorship)
}

// MARK: - Canonical encoding
//
// FROZEN. `Derived.approvalBytes` concatenates these, so any change invalidates
// every recorded approval and must bump `CanonicalEncoding.version` and ship a
// re-approval path. Separate from `Codable`, the document path. Fields are
// fixed-width little-endian except where a length prefix is noted.

extension EvidenceKind {
    /// One frozen byte per kind, keeping this record fixed-width and independent of
    /// the JSON spelling. A new case takes the next unused number, never a reused one.
    var canonicalTag: UInt8 {
        switch self {
        case .observation: 0x01
        case .transcript:  0x02
        case .release:     0x03
        }
    }
}

extension HostRange {
    /// 32 bytes: `epoch.id` (16, RFC 4122 byte order) ‖ `start` ‖ `duration`
    /// (16, nanoseconds, two's complement little-endian). The epoch is
    /// digest-significant: offsets alone are ambiguous across a reboot. A plain
    /// method, not a conformance, since neither type belongs to this module.
    func encodeCanonically(into bytes: inout [UInt8]) {
        // Expanded by hand: `.strictMemorySafety()` forbids `withUnsafeBytes`.
        let u = epoch.id.uuid
        bytes.append(contentsOf: [u.0, u.1, u.2,  u.3,  u.4,  u.5,  u.6,  u.7,
                                  u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15])
        CanonicalEncoding.appendInt64(start.rawValue, to: &bytes)
        CanonicalEncoding.appendInt64(duration.rawValue, to: &bytes)
    }
}

extension EvidenceRef: CanonicallyEncodable {
    /// 82 bytes, fixed width, which is what lets `Evidence` prefix only a count:
    /// `kind.canonicalTag` (1) ‖ `id` (16, RFC 4122 byte order) ‖
    /// `contentDigest.bytes` (32) ‖ `sourceInterval` presence byte (1, `0x00`/`0x01`)
    /// ‖ the interval (32), or 32 zero bytes when absent. The presence byte is not
    /// redundant: `nil` and a zero-length range at a fixed epoch share payload bytes.
    public func encodeCanonically(into bytes: inout [UInt8]) {
        bytes.append(kind.canonicalTag)
        // Expanded by hand: `.strictMemorySafety()` forbids `withUnsafeBytes`. The
        // tuple order is the UUID's network byte order, so this is endian-independent.
        let u = id.uuid
        bytes.append(contentsOf: [u.0, u.1, u.2,  u.3,  u.4,  u.5,  u.6,  u.7,
                                  u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15])
        bytes.append(contentsOf: contentDigest.bytes)
        if let sourceInterval {
            bytes.append(0x01)
            sourceInterval.encodeCanonically(into: &bytes)
        } else {
            bytes.append(0x00)
            bytes.append(contentsOf: [UInt8](repeating: 0, count: 32))
        }
    }
}

extension Evidence: CanonicallyEncodable {
    /// A `UInt64` count, then that many fixed-width `EvidenceRef` records. Order is
    /// digest-significant.
    public func encodeCanonically(into bytes: inout [UInt8]) {
        CanonicalEncoding.appendCount(count, to: &bytes)
        for ref in self { ref.encodeCanonically(into: &bytes) }
    }
}

extension Outcome: CanonicallyEncodable {
    /// `0x01` accepted; `0x02` rejected, followed by the length-prefixed UTF-8 of
    /// the gate code. Tags start at 1 so a zeroed buffer encodes nothing valid.
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
    /// ‖ `evidence` (count-prefixed, 82 bytes each — see `EvidenceRef.encodeCanonically`)
    /// ‖ `outcome` (self-delimiting).
    public func encodeCanonically(into bytes: inout [UInt8]) {
        CanonicalEncoding.appendLengthPrefixed(producer.rawValue, to: &bytes)
        CanonicalEncoding.appendInt64(Int64(producerVersion), to: &bytes)
        evidence.encodeCanonically(into: &bytes)
        outcome.encodeCanonically(into: &bytes)
    }
}

extension Authorship: CanonicallyEncodable {
    /// `note` (length-prefixed UTF-8) ‖ a presence byte for `at` ‖ 8 bytes:
    /// `at.timeIntervalSinceReferenceDate`'s bit pattern, or zeroes when absent. The
    /// presence byte is load-bearing: the reference date's interval is itself zero,
    /// so without it "no timestamp" and the reference date would digest alike.
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
    /// `0x01` generated, followed by the derivation; `0x02` authored, followed by
    /// the authorship.
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
