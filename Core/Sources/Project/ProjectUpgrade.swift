import Foundation
import Geometry

/// Everything that can go wrong opening or writing a `ProjectSnapshot` document
/// and its package. `tooNew` must throw before any field is read: a partial read
/// followed by a save would silently delete every field the newer build wrote.
public enum ProjectFormatError: Error, Equatable {
    /// Not a well-formed project document — invalid JSON, or a missing or
    /// malformed `schemaVersion`.
    case malformed(String)
    /// `found` is newer than `supported`; no other field may be read.
    case tooNew(found: Int, supported: Int)
    /// A negative schema version: damage, with nothing to upgrade from.
    case unsupportedLegacyVersion(Int)
    /// A sidecar of this name already exists; media is write-once, never mutated.
    case sidecarAlreadyExists(String)
    /// `name` is not a single path component — it contains `/` or `\`, is `.` or
    /// `..`, or starts with `.`. A name escaping `media/` would write outside the
    /// directory `unreferencedSidecars` scans, making a permanent orphan.
    case invalidSidecarName(String)
    /// The named media is not an ordinary file in the package — a symbolic link to somewhere
    /// else, most dangerously, which would open a file this package does not contain.
    case mediaIsNotAFile(String)
    /// More than one observation log names this media file in its header, so which one belongs
    /// to it cannot be decided — the media's name, then the logs' names, sorted.
    case severalLogsNameOneMedia(String, [String])
}

/// Decodes a `ProjectSnapshot` from any schema version this build reads, migrating
/// older documents forward. v0 never shipped; it is synthetic, defined as v1
/// without `mediaFilenames`.
public enum ProjectUpgrade {
    /// v0's wire shape: `ProjectSnapshot` minus `mediaFilenames`.
    private struct V0Snapshot: Codable {
        var schemaVersion: Int
        var geometries: GeometryRegistry
    }

    public static func load(_ data: Data) throws -> ProjectSnapshot {
        let version = try SchemaProbe.version(of: data)
        switch version {
        case 1:
            do {
                return try JSONDecoder().decode(ProjectSnapshot.self, from: data)
            } catch {
                throw ProjectFormatError.malformed(String(describing: error))
            }
        case 0:
            let v0: V0Snapshot
            do {
                v0 = try JSONDecoder().decode(V0Snapshot.self, from: data)
            } catch {
                throw ProjectFormatError.malformed(String(describing: error))
            }
            return ProjectSnapshot(
                schemaVersion: ProjectSnapshot.currentSchemaVersion,
                geometries: v0.geometries,
                mediaFilenames: [],
                segments: .empty
            )
        case let future where future > ProjectSnapshot.currentSchemaVersion:
            throw ProjectFormatError.tooNew(found: future, supported: ProjectSnapshot.currentSchemaVersion)
        default:
            throw ProjectFormatError.unsupportedLegacyVersion(version)
        }
    }
}
