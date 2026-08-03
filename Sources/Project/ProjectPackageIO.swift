import Foundation

/// Reads and writes a `ProjectSnapshot` document to and from its on-disk
/// package layout (D-P3):
///
/// ```
/// MyDemo.soredemo/          UTType(exportedAs:conformingTo: .package)
/// ├─ project.json           atomically replaced on save
/// ├─ media/…                write-once, never mutated
/// └─ observations/…jsonl    append-only
/// ```
///
/// **Why only the manifest is atomic.** `ARCHITECTURE.md` D5 says "atomic
/// writes" without addressing gigabytes. The textbook temp-directory-and-
/// rename copies every byte on every save, which is fine for `project.json`
/// (kilobytes) and a non-starter for footage (gigabytes). So media sidecars
/// are written once, under names the app mints, and never mutated
/// afterwards — which means the only thing a save has to make atomic is the
/// small manifest. `save` therefore never touches `media/` beyond creating
/// the directory if absent, and it never consults `unreferencedSidecars` —
/// deleting media is `compact`'s job alone, on purpose, so that a save can
/// never destroy footage as a side effect.
///
/// **Atomicity is not durability — recorded as a decision (Controller
/// addendum ruling 4).** `FileManager.replaceItemAt` guarantees a reader
/// sees the old manifest or the new one, never a torn one, because the
/// underlying `rename(2)` is atomic with respect to concurrent opens. It
/// does NOT guarantee the new bytes have reached the platter; that needs an
/// explicit `fcntl(fd, F_FULLFSYNC)` on the temp file before the rename,
/// which this type deliberately does not call. Losing the last save's edit
/// state to a power cut is an acceptable loss, because the media referenced
/// by that edit state is already durable — it was written once, closed, and
/// never reopened for writing. This package chooses atomicity over
/// durability; it does not omit durability by not having thought about it.
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

    /// Ruling 1: the fixed sibling temp name for the atomic manifest
    /// replace. Not random — this package has no ambient randomness to draw
    /// one from (`AGENTS.md`: no `UUID()`, checked at link time), and a
    /// fixed, deterministic name is exactly what's needed here: `save` is
    /// single-writer by construction (one document, one process, one save
    /// call at a time), so there is no concurrent writer to collide with.
    /// Two processes saving the same package concurrently is a case Phase 1
    /// does not handle — a random name would not fix that (both writers
    /// would still race on the final `replaceItemAt`), it would only hide
    /// the missing guarantee, which would be worse than naming it here.
    private static func manifestTempURL(in packageURL: URL) -> URL {
        packageURL.appending(path: "project.json.new", directoryHint: .notDirectory)
    }

    /// Writes `project.json` only, atomically. Creates the package
    /// directory and its `media/` and `observations/` subdirectories if
    /// absent. Never touches an existing `media/` entry, never deletes
    /// anything, and never consults `unreferencedSidecars` — see the type
    /// doc comment for why that split exists.
    public static func save(_ snapshot: ProjectSnapshot, to packageURL: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: mediaURL(in: packageURL), withIntermediateDirectories: true)
        try fm.createDirectory(at: observationsURL(in: packageURL), withIntermediateDirectories: true)

        let data = try ProjectSnapshot.makeEncoder().encode(snapshot)
        let tempURL = manifestTempURL(in: packageURL)
        try data.write(to: tempURL)

        // `replaceItemAt` creates the destination if it does not yet exist
        // (first save) and otherwise performs the atomic rename; either way
        // it removes `tempURL` on success, so no trace of the fixed temp
        // name survives a successful save.
        _ = try fm.replaceItemAt(manifestURL(in: packageURL), withItemAt: tempURL)
    }

    /// Loads and migrates `project.json` via `ProjectUpgrade.load`, which
    /// probes the schema version before decoding anything else (see that
    /// type's documentation for why the order matters).
    public static func load(from packageURL: URL) throws -> ProjectSnapshot {
        let data = try Data(contentsOf: manifestURL(in: packageURL))
        return try ProjectUpgrade.load(data)
    }

    /// Media filenames are minted by the app, never by this package
    /// (Controller addendum ruling 1 — the package refuses to violate
    /// write-once, it does not invent identity). Throws
    /// `ProjectFormatError.sidecarAlreadyExists(name)` — without writing a
    /// single byte — if a sidecar of that name is already on disk, which is
    /// "write-once, never mutated" made mechanical.
    ///
    /// Task 17 review, Important 3: `name` is required to be a single path
    /// component. Names are app-minted, so a traversal name reaching here
    /// is hardening rather than a live bug, but the consequence is not a
    /// merely stray file: anything written outside `media/` is invisible to
    /// `unreferencedSidecars`, which only ever scans that one directory —
    /// making it a permanent orphan by construction, in a format whose
    /// whole point is that orphans are sweepable. Refused before a single
    /// byte is written, same as the write-once check below.
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

    /// Names present under `media/` that `snapshot.mediaFilenames` does not
    /// reference, sorted so the result is comparable and testable. Does not
    /// delete anything — see `compact`.
    ///
    /// Task 17 review, Important 2: this function's entire purpose is never
    /// deleting something it shouldn't ("a save must never delete media" is
    /// the row's completion criterion), so it must not report — and
    /// `compact` must not therefore recursively delete — anything that
    /// isn't a plain sidecar file. Two things `contentsOfDirectory(atPath:)`
    /// would otherwise hand back are filtered out explicitly, not silently
    /// dropped by an option flag alone:
    ///   - **hidden files** (`.DS_Store` and similar) — `.skipsHiddenFiles`
    ///     excludes these at the enumeration level;
    ///   - **subdirectories** — `.skipsHiddenFiles` does NOT exclude a
    ///     non-hidden directory an app might later create under `media/`,
    ///     so each entry is checked with `.isRegularFileKey` and anything
    ///     that isn't a regular file is skipped, never reported as an
    ///     orphan. `compact`'s `removeItem` is recursive on a directory —
    ///     reporting a subdirectory here would make `compact` capable of
    ///     deleting an entire tree, which is exactly what this function
    ///     exists to prevent.
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

    /// **Observation logs whose header names a media file the snapshot no
    /// longer references.**
    ///
    /// Reports only, and it is deliberately **not** wired into `compact`.
    /// `compact`'s whole contract is that it deletes exactly what
    /// `unreferencedSidecars` reports and never anything else — a save must
    /// never be able to destroy footage, and a compaction that quietly grew a
    /// second kind of delete is the same failure by a different door. So this
    /// is the `unreferencedSidecars` half of the pair with no `compact` half,
    /// on purpose, until something has a reason to remove a log.
    ///
    /// **What it is for.** `ObservationLogHeader.mediaFilename` is the format's
    /// join field: it is how a log found on its own says which recording it
    /// describes. A segment whose media was discarded by a writer failure, or
    /// swept by `compact`, leaves `segment-NN.jsonl` behind pointing at a file
    /// that is not there — a dangling key in the one field the join depends on.
    /// Nothing else in the package would notice.
    ///
    /// A log whose first line does not decode as a header is reported too, and
    /// under the same name: it cannot state which media it belongs to, which is
    /// the same failure as naming media that is gone.
    ///
    /// **That includes a log written by a build with a different
    /// `ObservationLog.schemaVersion`**, which is not the same fault and is
    /// worth knowing about before acting on this list. Since this function only
    /// ever *reports* — deleting is nobody's job here, see above — conflating
    /// them costs a reader a second look rather than a file. The distinction is
    /// available to anyone who wants it: `ObservationLogReadReport.read` throws
    /// `ProjectFormatError.unsupportedLegacyVersion` or `.tooNew` by name for
    /// that case, and `DecodingError` for damage.
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

    /// The only path by which media is ever deleted. Removes exactly the
    /// names `unreferencedSidecars` reports and returns them — never called
    /// implicitly by `save`.
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
