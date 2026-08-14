import AppKit
import Foundation
import Geometry
// `Capture` since Phase 3A-4 — `MediaSink` and `Minting`.
import Capture
import Project
import SwiftUI
import Synchronization

/// Hand-written `NSDocument` coordinator for a `.soredemo` package. SwiftUI's
/// `ReadableDocument`/`WritableDocument` are macOS 27+, above this app's macOS 26
/// floor. Storage lives in `Sources/Project`; this class only coordinates.
final class ProjectDocument: NSDocument {
    /// Must match `UTExportedTypeDeclarations` in `Soredemo-Info.plist`.
    static let contentTypeIdentifier = "com.soredemo.project"

    /// Document state. `nonisolated` behind a `Mutex`: `NSDocument`'s `read` and
    /// `writeSafely` overrides are `nonisolated` and cannot be `@MainActor`.
    private nonisolated let state: Mutex<ProjectSnapshot>

    /// A value copy of the current state, safe to read without holding the lock.
    nonisolated var snapshot: ProjectSnapshot {
        state.withLock { $0 }
    }

    override init() {
        state = Mutex(ProjectSnapshot(
            schemaVersion: ProjectSnapshot.currentSchemaVersion,
            geometries: GeometryRegistry(),
            mediaFilenames: []
        ))
        super.init()
    }

    // MARK: - Reading

    /// `url` is the package directory; only `project.json` is read, never
    /// `media/` or `observations/`. `ProjectPackageIO.load` probes the schema
    /// first, so a future build's document throws `ProjectFormatError.tooNew`
    /// rather than being partially read.
    override nonisolated func read(from url: URL, ofType typeName: String) throws {
        let loaded = try ProjectPackageIO.load(from: url)
        state.withLock { $0 = loaded }
    }

    // MARK: - Writing

    /// Bypasses `super`'s safe-save, which copies the whole package (all of
    /// `media/`) into a temporary and swaps it in — leaving `media/` empty,
    /// since `write(to:ofType:)` writes only the manifest. `ProjectPackageIO.save`
    /// makes that manifest atomic via `replaceItemAt`; write-once media needs no
    /// atomicity. This also drops `super`'s `NSFileCoordinator` coordinated
    /// write, with nothing replacing it.
    override nonisolated func writeSafely(to url: URL,
                                          ofType typeName: String,
                                          for saveOperation: NSDocument.SaveOperationType) throws {
        try write(to: url, ofType: typeName)
    }

    /// Writes `project.json` and nothing else. Creates the package directory and
    /// its `media/`/`observations/` subdirectories if absent.
    override nonisolated func write(to url: URL, ofType typeName: String) throws {
        try ProjectPackageIO.save(snapshot, to: url)
    }

    /// `false`: the hand-rolled partial write above must not run unattended.
    override nonisolated class var autosavesInPlace: Bool { false }

    // MARK: - Media

    /// Writes a media sidecar under a freshly minted name, records it in the
    /// snapshot, and returns the name. Minted here because `Project` has no
    /// ambient randomness; `writeSidecar` refuses a name already on disk.
    @MainActor
    func addMedia(_ data: Data, fileExtension: String) throws -> String {
        try addMedia(data, named: "\(Minting.newIdentifier().uuidString.lowercased()).\(fileExtension)")
    }

    /// The same, under a name the caller already minted — `CaptureSession` mints
    /// a segment's filename at `beginSegment`, before any bytes exist. Capture
    /// must route through here, not `ProjectPackageIO.writeSidecar`: the
    /// `mediaFilenames` append makes the file referenced, and `updateChangeCount`
    /// keeps the document from closing unprompted and leaving the sidecar for
    /// the next `compactMedia()` to delete as unreferenced.
    @MainActor
    @discardableResult
    func addMedia(_ data: Data, named name: String) throws -> String {
        guard let packageURL = fileURL else { throw MediaError.documentHasNoURL }
        try ProjectPackageIO.writeSidecar(data, named: name, into: packageURL)
        state.withLock { $0.mediaFilenames.append(name) }
        updateChangeCount(.changeDone)
        return name
    }

    /// Names under `media/` this document no longer references; reports only,
    /// deleting is `compactMedia()`. Throws when the document has no URL rather
    /// than returning `[]`, which is indistinguishable from a clean package.
    @MainActor
    func unreferencedMedia() throws -> [String] {
        guard let packageURL = fileURL else { throw MediaError.documentHasNoURL }
        return try ProjectPackageIO.unreferencedSidecars(in: packageURL, snapshot: snapshot)
    }

    /// The only path by which this app deletes media. Never called from
    /// `write`/`writeSafely`: a save must not delete footage as a side effect.
    @MainActor
    @discardableResult
    func compactMedia() throws -> [String] {
        guard let packageURL = fileURL else { throw MediaError.documentHasNoURL }
        return try ProjectPackageIO.compact(packageURL, snapshot: snapshot)
    }

    enum MediaError: Error {
        /// The document has never been saved, so there is no package.
        case documentHasNoURL
    }

    /// The document's package directory, for a caller writing a sibling of
    /// `media/`. `nil` until the document has been saved.
    @MainActor
    var packageURL: URL? { fileURL }

    // MARK: - Window

    override func makeWindowControllers() {
        let hosting = NSHostingController(rootView: ProjectDocumentView(snapshot: snapshot))
        let window = NSWindow(contentViewController: hosting)
        window.title = displayName ?? "Untitled"
        addWindowController(NSWindowController(window: window))
    }
}

extension ProjectDocument: MediaSink {
    /// `CaptureSession`'s route into `addMedia(_:named:)`, and nothing more.
    func acceptMedia(_ data: Data, named name: String) throws {
        try addMedia(data, named: name)
    }
}

/// Phase 1's document window: what came out of an opened package's manifest.
/// Opaque, no `.glassEffect()` (D7). Takes a `Sendable` snapshot value rather
/// than the document, so it does not update when the snapshot changes.
private struct ProjectDocumentView: View {
    let snapshot: ProjectSnapshot

    var body: some View {
        Form {
            LabeledContent("Schema version", value: "\(snapshot.schemaVersion)")
            LabeledContent("Display geometries", value: "\(snapshot.geometries.revisions.count)")
            LabeledContent("Media files", value: "\(snapshot.mediaFilenames.count)")
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 240)
    }
}
