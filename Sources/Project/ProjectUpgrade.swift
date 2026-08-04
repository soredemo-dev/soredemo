import Foundation
import Geometry

/// Everything that can go wrong opening OR writing a `ProjectSnapshot`
/// document and its package (Task 17 widened this from "opening" alone when
/// `sidecarAlreadyExists` and `invalidSidecarName` were added — both are
/// write-path failures from `ProjectPackageIO`, not document-open failures).
///
/// `tooNew` is the load-bearing case (Controller addendum ruling 3): a
/// document written by a future build must throw BEFORE any field is read
/// into a snapshot. The failure mode being guarded against is not a bad
/// read — it is a partial read followed by a save, which would silently
/// delete every field the newer build wrote and this build does not know
/// about.
public enum ProjectFormatError: Error, Equatable {
    /// The document is not a well-formed project document at all — invalid
    /// JSON, or missing/malformed `schemaVersion`.
    case malformed(String)
    /// `found` is newer than `supported`. Refuse to read a single other
    /// field: see the type's documentation.
    case tooNew(found: Int, supported: Int)
    /// A negative schema version — never produced by any real build, only
    /// by damage. There is no upgrade path for it because there is nothing
    /// to upgrade FROM.
    case unsupportedLegacyVersion(Int)
    /// Task 17 (Controller addendum ruling 1): `ProjectPackageIO.writeSidecar`
    /// refused to write because a sidecar of this name already exists.
    /// Media is write-once and never mutated (D-P3) — this is that
    /// invariant made mechanical. Extended onto this enum rather than a
    /// second error type: like the other cases here, it is "the on-disk
    /// document is not in the shape this build is willing to write to."
    case sidecarAlreadyExists(String)
    /// Task 17 review, Important 3: `name` is not a single path component —
    /// it contains `/` or `\`, or is `.` or `..`, or starts with `.`. Names
    /// are minted by the app, not this package, but a name that escapes
    /// `media/` (`"../escaped.mov"`) would write outside the directory
    /// `unreferencedSidecars` scans, making it a permanent orphan that no
    /// `compact` call could ever reach. Refused before a single byte is
    /// written.
    case invalidSidecarName(String)
}

/// Decodes a `ProjectSnapshot` from any schema version this build knows how
/// to read, migrating older documents forward on the way in.
///
/// `v0` never shipped. It is synthetic — defined as v1 without
/// `mediaFilenames` — so the upgrade chain has a real second link rather
/// than a `switch` with one arm (Controller addendum ruling 4).
public enum ProjectUpgrade {
    /// v0's wire shape: `ProjectSnapshot` minus `mediaFilenames`. Kept
    /// private to `ProjectUpgrade` — nothing outside the migration path has
    /// any business constructing a v0 document.
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
