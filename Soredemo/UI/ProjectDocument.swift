import AppKit
import Foundation
import Geometry
import Project
import SwiftUI
import Synchronization

/// The hand-written `NSDocument` coordinator for a `.soredemo` package
/// (design doc D-P3, F3, F4).
///
/// **Why `NSDocument` and not SwiftUI's document protocols.** macOS 27's
/// `ReadableDocument`/`WritableDocument` handle a package directory correctly —
/// their `Source`/`Destination` associated types merely default to `URL`, so a
/// reader may read one small manifest and leave gigabytes alone, verified by
/// compilation in F3. But they live in SwiftUI and are `@available(macOS 27, *)`,
/// and this app's floor is macOS 26 (D2), so they are unusable. F4 verified
/// `NSDocument` reaches the same place at the floor.
///
/// **The cost, recorded up front (F4).** `read(from:ofType:)` and
/// `writeSafely(to:ofType:for:)` are `nonisolated` on `NSDocument`; marking an
/// override `@MainActor` is a hard compile error — *"main actor-isolated
/// instance method has different actor isolation from nonisolated overridden
/// declaration"*. Document state therefore cannot live behind the class's own
/// main-actor isolation, and lives in a `Mutex` instead. The macOS 27 protocol
/// avoids this by making `snapshot(contentType:)` `@MainActor` and handing a
/// `sending` value to a `@concurrent` writer. This is an ongoing tax on every
/// piece of state this class grows, not a one-off.
///
/// This class **coordinates**; it does not reimplement storage. Every read,
/// write, sidecar and sweep below is a call into `Sources/Project` — the atomic
/// manifest replace, the schema probe, the upgrade chain, the write-once check
/// and the orphan scan all live there and are tested there. A `replaceItemAt`
/// or a `JSONDecoder` appearing in this file would be the two halves starting
/// to drift.
final class ProjectDocument: NSDocument {
    /// Must match `UTExportedTypeDeclarations` in `Soredemo-Info.plist`.
    static let contentTypeIdentifier = "com.soredemo.project"

    /// Document state. `nonisolated` and behind a `Mutex` because the two
    /// overrides that touch it cannot be main-actor isolated — see the class
    /// documentation.
    private nonisolated let state: Mutex<ProjectSnapshot>

    /// The snapshot as of this instant. A value copy: callers get something
    /// they can read without holding the lock, which is what makes it safe to
    /// hand to a SwiftUI view.
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

    /// `url` is the package **directory**. Only `project.json` is read;
    /// `media/` and `observations/` are never opened, which is what keeps
    /// opening a document independent of how much footage it holds.
    ///
    /// `ProjectPackageIO.load` routes through `SchemaProbe` before decoding
    /// anything, so a document written by a future build throws
    /// `ProjectFormatError.tooNew` rather than being partially read — the
    /// failure that matters is not a bad read, it is a partial read followed by
    /// a save that silently drops every field this build does not know about.
    override nonisolated func read(from url: URL, ofType typeName: String) throws {
        let loaded = try ProjectPackageIO.load(from: url)
        state.withLock { $0 = loaded }
    }

    // MARK: - Writing

    /// **This override exists to bypass `NSDocument`'s whole-package copy, and
    /// that is the entire point of it.**
    ///
    /// `super.writeSafely(to:ofType:for:)` implements the textbook safe-save:
    /// write the complete document into a temporary directory, then swap it
    /// into place. For a package document that means every byte of `media/` is
    /// copied on every save — gigabytes of footage, to persist a few kilobytes
    /// of edit state. Worse than slow, it is *wrong* here: this class's
    /// `write(to:ofType:)` writes the manifest and nothing else, by design
    /// (D-P3: media is write-once and a save must never be able to destroy it),
    /// so letting `super` swap a freshly built temporary directory over the
    /// real package would leave a package whose `media/` is empty.
    ///
    /// So the safety is relocated rather than dropped: `ProjectPackageIO.save`
    /// makes the *manifest alone* atomic via `replaceItemAt`, and media needs
    /// no atomicity because it is never mutated after it is written. Saves stay
    /// in milliseconds regardless of footage size, on any filesystem.
    ///
    /// (Atomicity is not durability. `replaceItemAt` guarantees a reader sees
    /// the old manifest or the new one, never a torn one; it does not guarantee
    /// the bytes reached the platter, which would need `fcntl(F_FULLFSYNC)`.
    /// D-P3 records that as a decision — one save's edit state is an acceptable
    /// loss because the media it references is already durable.)
    override nonisolated func writeSafely(to url: URL,
                                          ofType typeName: String,
                                          for saveOperation: NSDocument.SaveOperationType) throws {
        try write(to: url, ofType: typeName)
    }

    /// Writes `project.json` and nothing else. Creates the package directory
    /// and its `media/`/`observations/` subdirectories if absent, so a
    /// Save-As to a fresh URL produces a well-formed package.
    override nonisolated func write(to url: URL, ofType typeName: String) throws {
        try ProjectPackageIO.save(snapshot, to: url)
    }

    /// `false`, deliberately. Autosaving in place drives saves through
    /// `NSFileCoordinator` on a schedule the user did not ask for; a document
    /// whose save path is a hand-rolled partial write (above) should not be
    /// doing that unattended until Phase 2 has a real editing model to say what
    /// a "change" even is.
    override nonisolated class var autosavesInPlace: Bool { false }

    // MARK: - Media

    /// Writes a media sidecar under a freshly minted name and records it in the
    /// snapshot.
    ///
    /// The name is minted here because the package cannot mint one — it has no
    /// ambient randomness by construction (`AGENTS.md` § Determinism), which is
    /// why `ProjectPackageIO.writeSidecar` takes a name rather than inventing
    /// one. `writeSidecar` refuses, without writing a byte, if that name is
    /// already on disk; a UUID collision is not a real risk, but write-once is
    /// an invariant and an invariant that is only true by probability is not
    /// mechanical.
    ///
    /// Returns the name, which is what the caller stores in whatever references
    /// the media.
    @MainActor
    func addMedia(_ data: Data, fileExtension: String) throws -> String {
        guard let packageURL = fileURL else { throw MediaError.documentHasNoURL }
        let name = "\(Minting.newIdentifier().uuidString.lowercased()).\(fileExtension)"
        try ProjectPackageIO.writeSidecar(data, named: name, into: packageURL)
        state.withLock { $0.mediaFilenames.append(name) }
        return name
    }

    /// Names under `media/` this document no longer references. Reports only;
    /// deleting is `compactMedia()`.
    @MainActor
    func unreferencedMedia() throws -> [String] {
        guard let packageURL = fileURL else { return [] }
        return try ProjectPackageIO.unreferencedSidecars(in: packageURL, snapshot: snapshot)
    }

    /// The only path by which this app deletes media, and it is explicit.
    /// Never called from `write`/`writeSafely`: a save that could delete
    /// footage as a side effect is the failure D-P3 is built to prevent.
    @MainActor
    @discardableResult
    func compactMedia() throws -> [String] {
        guard let packageURL = fileURL else { return [] }
        return try ProjectPackageIO.compact(packageURL, snapshot: snapshot)
    }

    enum MediaError: Error {
        /// The document has never been saved, so there is no package to write
        /// a sidecar into.
        case documentHasNoURL
    }

    // MARK: - Window

    override func makeWindowControllers() {
        let hosting = NSHostingController(rootView: ProjectDocumentView(snapshot: snapshot))
        let window = NSWindow(contentViewController: hosting)
        window.title = displayName ?? "Untitled"
        addWindowController(NSWindowController(window: window))
    }
}

/// Phase 1's document window: enough to show that a `.soredemo` package opened
/// and what came out of its manifest.
///
/// Standard SwiftUI, opaque, no `.glassEffect()` — `AGENTS.md` architecture
/// rule 6.
///
/// Takes a snapshot **value**, not the document: `ProjectSnapshot` is `Sendable`
/// and this view is main-actor, whereas the document's state deliberately is
/// not. The consequence is that this view does not update when the snapshot
/// changes, which is correct for Phase 1 — there is no editing yet, so there is
/// nothing to observe. Phase 2 introduces an observable model between the two.
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
