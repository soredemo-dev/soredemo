import Foundation
import Geometry

/// Where a value stands with the person who decides about it. Not part of
/// `approvalBytes`. `String`-backed so the document spelling is stable and adding
/// a state stays a document-format question rather than a digest question.
public enum ReviewState: String, Codable, Hashable, Sendable {
    /// Proposed, not yet decided; the state everything starts in.
    case pending
    /// A person approved this exact value; an approval binds to its `approvalBytes`.
    case approved
    /// A person said no. Distinct from `pending`: a producer re-run must not read
    /// "rejected" as "not looked at yet".
    case rejected
}

/// A value together with where it came from and where it stands with a human.
///
/// Citation is a field of the value, not a side table: `Origin.generated` requires
/// a `Derivation`, which requires non-empty `Evidence`, so an uncited generated
/// value cannot be spelled. `Value: CanonicallyEncodable` because the approved
/// payload's bytes must be ours; `Codable` is the separate document path.
public struct Derived<Value: CanonicallyEncodable & Codable & Hashable & Sendable>:
    Codable, Hashable, Sendable {

    public let value: Value
    public let origin: Origin
    /// The only mutable field, and the only one `approvalBytes` does not cover.
    public var review: ReviewState

    /// Public because the app mints authored values through it and the decoder needs
    /// it; nothing stops a producer bypassing `applyingProduced` with it. The
    /// `review: .pending` default is convention only, not enforcement.
    public init(value: Value, origin: Origin, review: ReviewState = .pending) {
        self.value = value
        self.origin = origin
        self.review = review
    }

    /// The canonical bytes an approval binds to: `value` + `origin`, never `review`
    /// — approving mutates `review`, so covering it would invalidate the approval as
    /// it was recorded. The package emits bytes; the app hashes them (SHA-256).
    ///
    /// Frozen layout: byte 0 `CanonicalEncoding.version`; bytes 1-8 value payload
    /// length, little-endian; `value.encodeCanonically`; `origin.encodeCanonically`
    /// (self-delimiting). The length prefix is required even for a fixed-width
    /// `Value`, which is generic here, or a longer value could borrow the origin's
    /// bytes. Hand-written, never `Codable`, whose output is not deterministic and
    /// would tie digests to the document schema; versioned by
    /// `CanonicalEncoding.version`, not `ProjectSnapshot.schemaVersion`.
    public var approvalBytes: Data {
        var bytes: [UInt8] = [CanonicalEncoding.version]
        var payload: [UInt8] = []
        value.encodeCanonically(into: &payload)
        CanonicalEncoding.appendLengthPrefixed(payload, to: &bytes)
        origin.encodeCanonically(into: &bytes)
        return Data(bytes)
    }

    /// The path a producer is meant to use to write a result; `init` is public, so
    /// this is the correct path, not a guarded one. Three rules, in order:
    ///
    /// 1. An authored value wins: `self` is returned untouched.
    /// 2. If produced value and origin equal the current ones, `approvalBytes` are
    ///    unchanged and the existing review is kept.
    /// 3. Otherwise review resets to `.pending`; the producer's own `review` is
    ///    discarded, never copied, so it cannot approve its own output.
    ///
    /// Traps if `produced` is `.authored`: a producer cannot author, and a fabricated
    /// `.authored` origin would be immune to every later production pass.
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
