import Foundation
import Geometry

/// A project's persisted state: everything needed to reopen a document and
/// resolve its own coordinates, and nothing Phase 2 hasn't asked for yet
/// (Controller addendum ruling 1 — YAGNI).
///
/// `geometries` is not optional: normalized frames elsewhere in this
/// document reference a `GeometryRevision`, so a document that does not
/// persist the registry cannot resolve its own coordinates after reopening.
///
/// `mediaFilenames` holds relative paths only, never absolute
/// (`docs/ARCHITECTURE.md` D5) — it is this snapshot's half of Task 17's
/// `unreferencedSidecars(in:snapshot:)` contract.
///
/// `schemaVersion` is the DOCUMENT format version. It is deliberately a
/// separate number from `CanonicalEncoding.version` — see
/// `documentSchemaVersionAndCanonicalEncodingVersionAreIndependentConstants`
/// and the design doc § Canonical encoding point 2: a document schema
/// upgrade must leave existing approvals verifiable, so the two version
/// lines are never coupled or derived from one another.
public struct ProjectSnapshot: Codable, Sendable, Equatable {
    /// The current document schema version this build writes. Bump this,
    /// never `CanonicalEncoding.version`, when `ProjectSnapshot`'s own shape
    /// changes.
    public static let currentSchemaVersion: Int = 1

    public var schemaVersion: Int
    public var geometries: GeometryRegistry
    public var mediaFilenames: [String]

    public init(schemaVersion: Int, geometries: GeometryRegistry, mediaFilenames: [String]) {
        self.schemaVersion = schemaVersion
        self.geometries = geometries
        self.mediaFilenames = mediaFilenames
    }
}

extension ProjectSnapshot {
    /// The encoder every save path must use. Measured, not assumed (design §
    /// Canonical encoding point 0): a plain `JSONEncoder` with no
    /// `.sortedKeys`, encoding a plain `Codable` struct array with no
    /// dictionary anywhere in it, produced five distinct byte sequences
    /// across five processes — with `.sortedKeys`, one. `ProjectSnapshot` is
    /// not digested (unlike `DisplayGeometry.canonicalBytes` or
    /// `Derived.approvalBytes`), so it stays on `JSONEncoder` rather than
    /// `CanonicallyEncodable` — but a save that differs byte-for-byte for no
    /// reason still makes every future diff, and every future "did this
    /// change?" question, unanswerable.
    ///
    /// Returns a fresh instance per call rather than a shared `static let`:
    /// `JSONEncoder` is a reference type and not `Sendable`.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
