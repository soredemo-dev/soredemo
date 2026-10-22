import Foundation
import Geometry

/// A project's persisted state: everything needed to reopen a document and
/// resolve its own coordinates.
///
/// `geometries` is not optional: normalized frames elsewhere reference a
/// `GeometryRevision`, so a document without the registry cannot resolve its own
/// coordinates after reopening. `mediaFilenames` holds relative paths only.
///
/// `schemaVersion` is the document format version, deliberately independent of
/// `CanonicalEncoding.version`: a schema upgrade must leave existing approvals
/// verifiable, so the two lines are never coupled.
public struct ProjectSnapshot: Codable, Sendable, Equatable {
    /// The document schema version this build writes. Bump this, never
    /// `CanonicalEncoding.version`, when an existing key's meaning or shape
    /// changes — something an older build would misread rather than not have.
    ///
    /// Not bumped for `segments`, which is additive and absence-tolerant. That
    /// trade holds only while nothing persists a segment table: an older build
    /// opening a newer document would decode the key and silently drop it on the
    /// next save. A future additive field must re-make this decision, not inherit it.
    public static let currentSchemaVersion: Int = 1

    public var schemaVersion: Int
    public var geometries: GeometryRegistry
    public var mediaFilenames: [String]

    /// The master's timeline. Defaults to `.empty` so callers predating this field,
    /// and the v0→v1 migration, can construct a snapshot without a table.
    public var segments: SegmentTable

    /// What a person decided about this recording. Defaults to untouched, so every existing
    /// caller and every document written before the field existed opens unedited.
    ///
    /// **Only authored values** — see `EditState`. A snapshot storing derived ones would keep
    /// a stale answer when the derivation improved.
    public var edit: EditState

    public init(schemaVersion: Int, geometries: GeometryRegistry, mediaFilenames: [String],
                segments: SegmentTable = .empty, edit: EditState = .untouched) {
        self.schemaVersion = schemaVersion
        self.geometries = geometries
        self.mediaFilenames = mediaFilenames
        self.segments = segments
        self.edit = edit
    }
}

extension ProjectSnapshot {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, geometries, mediaFilenames, segments, edit
    }

    /// Hand-written so `segments` may be absent: a v1 document written before the
    /// field existed has no such key, and synthesis would require one. There is no
    /// separate migration step for it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        geometries = try container.decode(GeometryRegistry.self, forKey: .geometries)
        let names = try container.decode([String].self, forKey: .mediaFilenames)
        // **Untrusted, and refused where it enters.** A package is a document people send each
        // other, and a name like `../../private.mov` would be opened as the recording — any file
        // this unsandboxed app can read. The same rule `writeSidecar` already applied on the way
        // out, applied on the way in.
        if let unsafe = names.first(where: { !ProjectPackageIO.isSafeMediaName($0) }) {
            throw DecodingError.dataCorruptedError(
                forKey: .mediaFilenames, in: container,
                debugDescription: "\"\(unsafe)\" is not a file name inside the package's media folder")
        }
        mediaFilenames = names
        segments = try container.decodeIfPresent(SegmentTable.self, forKey: .segments) ?? .empty
        // **Absent means unedited, and the version does NOT move for it.** `segments` above
        // took that trade once and its comment says a future additive field must re-make the
        // decision rather than inherit it. Re-made, and it holds for the same reason plus one
        // more: an older build opening a newer document would drop this key on the next save,
        // and what it would drop is a person's edits rather than a table nothing yet writes.
        // That is worse — so the mitigation is not the schema version, which cannot stop it,
        // but that `EditState` holds only AUTHORED values. A build that cannot read them
        // re-derives everything and loses corrections, not footage.
        edit = try container.decodeIfPresent(EditState.self, forKey: .edit) ?? .untouched
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(geometries, forKey: .geometries)
        try container.encode(mediaFilenames, forKey: .mediaFilenames)
        try container.encode(segments, forKey: .segments)
        try container.encode(edit, forKey: .edit)
    }
}

extension ProjectSnapshot {
    /// The encoder every save path must use. `.sortedKeys` is required: without it
    /// one snapshot encodes to different bytes in different processes, which makes
    /// every future diff unanswerable. Fresh per call — `JSONEncoder` is a
    /// non-`Sendable` reference type.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
