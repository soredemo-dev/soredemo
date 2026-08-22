import Foundation

/// Reads and writes a `ProjectSnapshot` to and from its on-disk package layout:
///
/// ```
/// MyDemo.soredemo/          UTType(exportedAs:conformingTo: .package)
/// ├─ project.json           atomically replaced on save
/// ├─ media/…                write-once, never mutated
/// └─ observations/…jsonl    append-only
/// ```
///
/// Only the manifest is atomic: sidecars are write-once, so no save copies gigabytes.
/// `save` never deletes; deleting media is `compact`'s job alone.
///
/// Atomicity, not durability: `replaceItemAt` guarantees a reader sees the old or the
/// new manifest, never a torn one, but not that the bytes reached the platter —
/// `F_FULLFSYNC` is deliberately not called. Media is already durable.
public enum ProjectPackageIO {
    private static func mediaURL(in packageURL: URL) -> URL {
        packageURL.appending(path: "media", directoryHint: .isDirectory)
    }

    private static func observationsURL(in packageURL: URL) -> URL {
        packageURL.appending(path: "observations", directoryHint: .isDirectory)
    }

    private static func manifestURL(in packageURL: URL) -> URL {
        packageURL.appending(path: "project.json", directoryHint: .notDirectory)
    }

    /// The fixed sibling temp name for the atomic manifest replace. Deterministic: this
    /// package has no ambient randomness and `save` is single-writer by construction.
    /// Concurrent saves of one package are not handled.
    private static func manifestTempURL(in packageURL: URL) -> URL {
        packageURL.appending(path: "project.json.new", directoryHint: .notDirectory)
    }

    /// Writes `project.json` only, atomically, creating the package directory and
    /// its `media/` and `observations/` subdirectories if absent. Never touches an
    /// existing `media/` entry and never deletes anything.
    public static func save(_ snapshot: ProjectSnapshot, to packageURL: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: mediaURL(in: packageURL), withIntermediateDirectories: true)
        try fm.createDirectory(at: observationsURL(in: packageURL), withIntermediateDirectories: true)

        let data = try ProjectSnapshot.makeEncoder().encode(snapshot)
        let tempURL = manifestTempURL(in: packageURL)
        try data.write(to: tempURL)

        // `replaceItemAt` creates the destination on first save, otherwise renames
        // atomically; either way it removes `tempURL` on success.
        _ = try fm.replaceItemAt(manifestURL(in: packageURL), withItemAt: tempURL)
    }

    /// Loads and migrates `project.json` via `ProjectUpgrade.load`, which probes the
    /// schema version before decoding anything else.
    public static func load(from packageURL: URL) throws -> ProjectSnapshot {
        let data = try Data(contentsOf: manifestURL(in: packageURL))
        return try ProjectUpgrade.load(data)
    }

    /// Writes one media sidecar; names are minted by the app, never here. Throws
    /// `sidecarAlreadyExists` without writing a byte if the name is taken — write-once
    /// made mechanical. `name` must be a single path component, also refused before any
    /// byte is written: anything outside `media/` is a permanent orphan.
    public static func writeSidecar(_ data: Data, named name: String, into packageURL: URL) throws {
        guard
            !name.contains("/"), !name.contains("\\"),
            name != ".", name != "..",
            !name.hasPrefix(".")
        else {
            throw ProjectFormatError.invalidSidecarName(name)
        }

        let fm = FileManager.default
        let directory = mediaURL(in: packageURL)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileURL = directory.appending(path: name, directoryHint: .notDirectory)
        guard !fm.fileExists(atPath: fileURL.path) else {
            throw ProjectFormatError.sidecarAlreadyExists(name)
        }
        try data.write(to: fileURL)
    }

    /// Names under `media/` that `snapshot.mediaFilenames` does not reference, sorted.
    /// Deletes nothing — see `compact`. Regular files only: `compact`'s `removeItem` is
    /// recursive, so reporting a subdirectory would let it delete a whole tree.
    public static func unreferencedSidecars(in packageURL: URL, snapshot: ProjectSnapshot) throws -> [String] {
        let fm = FileManager.default
        let directory = mediaURL(in: packageURL)
        guard fm.fileExists(atPath: directory.path) else { return [] }

        let entries = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let regularFileNames = try entries.compactMap { entry -> String? in
            let isRegular = try entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile ?? false
            return isRegular ? entry.lastPathComponent : nil
        }

        let referenced = Set(snapshot.mediaFilenames)
        return regularFileNames.filter { !referenced.contains($0) }.sorted()
    }

    /// Observation logs whose header names media the snapshot no longer references — a
    /// dangling `ObservationLogHeader.mediaFilename`, the format's join field. Reports
    /// only, and deliberately not wired into `compact`, which must delete exactly what
    /// `unreferencedSidecars` reports. A log whose first line does not decode as a
    /// header is reported too; `ObservationLogReadReport.read` tells those cases apart.
    public static func danglingObservationLogs(in packageURL: URL,
                                               snapshot: ProjectSnapshot) throws -> [String] {
        let fm = FileManager.default
        let directory = observationsURL(in: packageURL)
        guard fm.fileExists(atPath: directory.path) else { return [] }

        let entries = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let referenced = Set(snapshot.mediaFilenames)
        var dangling: [String] = []
        for entry in entries {
            let isRegular = try entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile ?? false
            guard isRegular, entry.pathExtension == "jsonl" else { continue }
            let report = try? ObservationLogReadReport.read(logAt: entry)
            guard let named = report?.header?.mediaFilename else {
                dangling.append(entry.lastPathComponent)
                continue
            }
            if !referenced.contains(named) { dangling.append(entry.lastPathComponent) }
        }
        return dangling.sorted()
    }

    /// The only path by which media is deleted: removes exactly the names
    /// `unreferencedSidecars` reports and returns them. Never called by `save`.
    public static func compact(_ packageURL: URL, snapshot: ProjectSnapshot) throws -> [String] {
        let fm = FileManager.default
        let directory = mediaURL(in: packageURL)
        let orphans = try unreferencedSidecars(in: packageURL, snapshot: snapshot)
        for name in orphans {
            try fm.removeItem(at: directory.appending(path: name, directoryHint: .notDirectory))
        }
        return orphans
    }
}
