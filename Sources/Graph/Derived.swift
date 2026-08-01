import Foundation
import Geometry

/// Where a value stands with the person who has to decide about it.
///
/// Deliberately **not** part of `approvalBytes`: see `Derived.approvalBytes`.
/// `String`-backed so the document spelling is stable and legible, and so adding
/// a state later is a document-format question rather than a digest question.
public enum ReviewState: String, Codable, Hashable, Sendable {
    /// Proposed, not yet decided. The state everything starts in — automation
    /// proposes, a person decides.
    case pending
    /// A person approved this exact value. What Phase 8's `approval-gate` binds
    /// to the value's `approvalBytes`.
    case approved
    /// A person looked at this and said no. Distinct from `pending`: a producer
    /// re-run must not read "rejected" as "not looked at yet".
    case rejected
}

/// A value together with where it came from and where it stands with a human
/// (design doc D-P4).
///
/// **Citation is a field of the value's type, not a side table.** A side-table
/// provenance graph costs the same in both directions, but it allows a value to
/// exist with no edge pointing at it — which makes "uncited claims cannot be
/// approved" a runtime check rather than a compile-time guarantee. Here,
/// `Origin.generated` requires a `Derivation`, which requires non-empty
/// `Evidence`: an uncited generated value cannot be spelled.
///
/// **`Value: CanonicallyEncodable`, not merely `Codable`.** The payload is the
/// part actually being approved, so its bytes must be ours — see
/// `CanonicallyEncodable`. `Codable` is required too, and is the document path.
public struct Derived<Value: CanonicallyEncodable & Codable & Hashable & Sendable>:
    Codable, Hashable, Sendable {

    public let value: Value
    public let origin: Origin
    /// The only mutable field, and the only one `approvalBytes` does not cover.
    public var review: ReviewState

    public init(value: Value, origin: Origin, review: ReviewState = .pending) {
        self.value = value
        self.origin = origin
        self.review = review
    }

    /// The canonical bytes an approval binds to: `value` + `origin`, **never
    /// `review`**.
    ///
    /// **Why `review` is excluded.** Approving *mutates* `review`. A digest that
    /// covered it would be invalidated by the very act of recording the approval
    /// — the approval would refer to bytes that no longer exist the instant it
    /// was made, and every approved value would read as tampered with. This is
    /// the single most important line in this type.
    ///
    /// The package emits bytes; **the app hashes them** (SHA-256, via CryptoKit).
    /// `SoredemoCore` compares digests and never computes one — see
    /// `ContentDigest`.
    ///
    /// Layout, frozen:
    ///
    /// | offset | bytes | field |
    /// | --- | --- | --- |
    /// | 0 | 1 | `CanonicalEncoding.version` |
    /// | 1 | 8 | length of the value payload, little-endian |
    /// | 9 | *n* | `value.encodeCanonically` |
    /// | 9+*n* | … | `origin.encodeCanonically`, self-delimiting |
    ///
    /// The value's length prefix is not optional even when `Value` is
    /// fixed-width: `Value` is generic, so nothing here can know its width, and
    /// an unprefixed variable-length payload would let a longer value borrow
    /// bytes from the origin that follows it. (`String` prefixes itself as well,
    /// so that it composes inside larger payloads; the outer prefix is the
    /// generic one and the redundancy is deliberate.)
    ///
    /// Hand-written, never routed through `Codable`. `JSONEncoder` does not
    /// encode deterministically without `.sortedKeys`, and even with it renders
    /// `Double` as decimal text; more fundamentally, reusing the document
    /// encoding would couple every stored approval to the document format, so a
    /// later schema change would silently change digests — validation quietly
    /// checking a different thing, which is worse than failing.
    ///
    /// The version byte is `CanonicalEncoding.version`, **not**
    /// `ProjectSnapshot.schemaVersion`: a document schema upgrade must leave
    /// existing approvals verifiable, so the two version lines move
    /// independently.
    public var approvalBytes: Data {
        var bytes: [UInt8] = [CanonicalEncoding.version]
        var payload: [UInt8] = []
        value.encodeCanonically(into: &payload)
        CanonicalEncoding.appendLengthPrefixed(payload, to: &bytes)
        origin.encodeCanonically(into: &bytes)
        return Data(bytes)
    }

    /// The only way a producer may write a result (design doc D-P4, plugin rule
    /// 7).
    ///
    /// The type system guarantees that anything generated cites evidence. It
    /// does **not** by itself stop a producer overwriting a human's value, so
    /// this is the enforced write path: producers never assign to a `Derived`
    /// directly, they hand their result here.
    ///
    /// Three rules, in order:
    ///
    /// 1. **An authored value wins, always.** `self` is returned untouched —
    ///    value, origin and review — no matter what the producer computed.
    /// 2. **A re-run that changes nothing keeps its review.** If the produced
    ///    value and origin are equal to the current ones, `approvalBytes` are
    ///    unchanged, so an existing approval still describes exactly what is
    ///    there. Dropping it would be a spurious re-approval prompt, and
    ///    prompting for approvals that do not matter is how a person learns to
    ///    click through the ones that do.
    /// 3. **Otherwise the review resets to `.pending`.** The bytes a person
    ///    approved are gone; the approval does not follow the value. The
    ///    producer's own `review` is discarded rather than copied — a producer
    ///    must never be able to mark its own output approved.
    ///
    /// Traps if `produced` is `.authored`. A producer cannot author, and this is
    /// the door through which a fabricated `.authored` origin would enter and
    /// then be immune to every later production pass. Like every precondition in
    /// this package it cannot be exercised with `#expect`, because a precondition
    /// failure kills the process.
    public func applyingProduced(_ produced: Derived<Value>) -> Derived<Value> {
        if case .authored = produced.origin {
            preconditionFailure("""
                applyingProduced received an .authored origin. A producer cannot author; \
                route human edits through a new Derived instead.
                """)
        }
        // Rule 1: authored wins, always.
        if case .authored = origin { return self }
        // Rule 2: nothing that the approval binds to has changed.
        if produced.value == value && produced.origin == origin { return self }
        // Rule 3: new bytes, so the old review does not describe them.
        return Derived(value: produced.value, origin: produced.origin, review: .pending)
    }
}
