/// 32 opaque bytes identifying the exact content evidence was cited against
/// (design doc D-P4).
///
/// **This package compares digests. It never computes one.** Computing a
/// cryptographic digest here would need CryptoKit, which `import Foundation`-only
/// D6 forbids; a hand-rolled hash would be the wrong way to obtain one either
/// way. The value is injected by whoever produced the evidence — the app, via
/// CryptoKit's SHA-256 — the same shape as time and randomness (§ Determinism).
///
/// **Deliberately not `fnv1a64`.** `GeometryRevision` is a 64-bit non-cryptographic
/// identity hash: fine for registry lookup, where the only adversary is
/// coincidence. `ContentDigest` sits on the evidence path Phase 8's
/// `approval-gate` binds per-post human approval to, over input
/// `ARCHITECTURE.md § Agentic security` designates attacker-controllable.
/// FNV-1a collisions can be constructed to order, which would let an approval
/// bound to reviewed text be redeemed against substituted text. `fnv1a64`
/// stays `internal` to `Geometry` and is not visible here, so there is no route
/// by which the identity hash reaches the evidence path.
///
/// Validated in two places, for two different reasons: `init(_:)` **traps** on
/// the wrong byte count, because a caller in this package handing in the wrong
/// length is a programmer error. `init(from:)` **throws**, because a digest
/// decoded from disk is untrusted input — corrupted, hand-edited, or written
/// by a future version of this app — and trapping on untrusted input is how a
/// bad file becomes an unopenable document (same split as
/// `GeometryRegistry.insert` vs `init(from:)`).
public struct ContentDigest: Hashable, Sendable {
    /// SHA-256 output length. Frozen: changing it is a breaking change to
    /// every digest already on disk.
    public static let byteCount = 32

    public let bytes: [UInt8]

    /// Traps if `bytes.count != Self.byteCount`. Like every precondition in
    /// this package, this cannot be exercised with `#expect` — a precondition
    /// failure kills the process — so it is not covered by
    /// `EvidenceTests.swift`; the untrusted-input path (`init(from:)`, below)
    /// is what stands between a corrupted digest and the rest of the program,
    /// and that path throws instead, so it is what the test suite exercises.
    public init(_ bytes: [UInt8]) {
        precondition(bytes.count == Self.byteCount,
                     "ContentDigest must be \(Self.byteCount) bytes, got \(bytes.count)")
        self.bytes = bytes
    }
}

extension ContentDigest: Codable {
    /// A digest decoded from disk whose byte count is not `ContentDigest.byteCount`
    /// — corruption, a hand edit, or a future encoding this version does not
    /// understand. Thrown, never trapped: see the type's documentation.
    public struct DecodingFailure: Error, Equatable {
        public let byteCount: Int
    }

    /// Untrusted input: throws `DecodingFailure` rather than trapping when the
    /// decoded byte count is wrong.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let decoded = try container.decode([UInt8].self)
        guard decoded.count == Self.byteCount else {
            throw DecodingFailure(byteCount: decoded.count)
        }
        self.bytes = decoded
    }

    /// Encodes as a flat JSON array of 32 numbers — no wrapping object, so
    /// there is no key order for `.sortedKeys` to have any effect on and
    /// nothing here can be a source of the per-process byte-order hazard
    /// (design doc § Canonical encoding, point 0).
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(bytes)
    }
}

extension ContentDigest: CustomStringConvertible {
    /// Fixed-width hex, matching `GeometryRevision.description`, so a digest
    /// is greppable and comparable in a log instead of printing as an opaque
    /// Swift array literal.
    public var description: String {
        let hex = bytes.map { byte -> String in
            let s = String(byte, radix: 16)
            return s.count == 1 ? "0" + s : s
        }.joined()
        return "ContentDigest(\(hex))"
    }
}
