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

    public init(schemaVersion: Int, geometries: GeometryRegistry, mediaFilenames: [String],
                segments: SegmentTable = .empty) {
        self.schemaVersion = schemaVersion
        self.geometries = geometries
        self.mediaFilenames = mediaFilenames
        self.segments = segments
    }
}

extension ProjectSnapshot {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, geometries, mediaFilenames, segments
    }

    /// Hand-written so `segments` may be absent: a v1 document written before the
    /// field existed has no such key, and synthesis would require one. There is no
    /// separate migration step for it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        geometries = try container.decode(GeometryRegistry.self, forKey: .geometries)
        mediaFilenames = try container.decode([String].self, forKey: .mediaFilenames)
        segments = try container.decodeIfPresent(SegmentTable.self, forKey: .segments) ?? .empty
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(geometries, forKey: .geometries)
        try container.encode(mediaFilenames, forKey: .mediaFilenames)
        try container.encode(segments, forKey: .segments)
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
