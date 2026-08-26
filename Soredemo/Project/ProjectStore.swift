import AppKit
import Compositing
import Foundation
import Framing
import Geometry
import Project
import Timeline
import UniformTypeIdentifiers
import Variants

/// Saving a recording somewhere it will still be there tomorrow, and opening it again.
///
/// **A recording is a package, not a file, and saving is a copy rather than a serialisation.**
/// What the recorder produces is a directory — `media/master-00.mov` beside
/// `observations/segment-00.jsonl` — written to a scratch location that is swept at launch.
/// The video and the observations are the evidence and they are already on disk in their final
/// form; a save that re-encoded them would be slower and would produce a second, lossier copy
/// of something that already exists. So a save copies the directory and adds `project.json`.
///
/// **What is added is only what a person decided** — see `EditState`. Everything else is
/// re-derived from the observations on open, so a project made before a gate improved gets the
/// better answer with the same corrections applied on top.
enum ProjectStore {
    /// The package extension. A directory rather than a flat file, and marked as a package so
    /// the Finder shows it as one thing rather than a folder a person can take apart by
    /// accident — the observation log and the media have to stay together or the edits refer
    /// to nothing.
    static let packageExtension = "soredemo"

    /// Where the media sits inside a package, and where a recording's own scratch directory
    /// puts it. One constant, because a save that copied to a different layout than the
    /// recorder writes would produce a package that only the saver can read.
    static let mediaDirectory = "media"

    /// The package a media URL belongs to — `<package>/media/<file>` walked back up.
    static func packageURL(forMediaAt mediaURL: URL) -> URL {
        mediaURL.deletingLastPathComponent().deletingLastPathComponent()
    }

    // MARK: - saving

    /// Copies the recording's package to `destination` and writes the edit into it.
    ///
    /// **Written to a temporary sibling and moved into place**, so an interrupted save leaves
    /// the previous file rather than half of the new one. A recording is not reproducible —
    /// nobody can perform the same demo twice — which makes a torn write worse here than in
    /// software where the input still exists.
    static func save(recordingAt mediaURL: URL, edit: EditState, to destination: URL) throws {
        let source = packageURL(forMediaAt: mediaURL)
        let fileManager = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).saving",
                       directoryHint: .isDirectory)

        try? fileManager.removeItem(at: staging)
        try fileManager.copyItem(at: source, to: staging)

        let snapshot = try snapshotForSaving(at: staging, edit: edit)
        try ProjectPackageIO.save(snapshot, to: staging)

        // Replace rather than remove-then-move: `replaceItemAt` is atomic where the filesystem
        // supports it, and leaves the original in place when it is not.
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
        try? fileManager.removeItem(at: staging)

        // The Finder shows a directory with this bit as one document rather than a folder.
        try? fileManager.setAttributes([.extensionHidden: false], ofItemAtPath: destination.path)
    }

    /// The snapshot to write. Reuses whatever the package already had — a recording's own
    /// package may carry a segment table and a geometry registry — and replaces only the edit,
    /// so saving does not discard what the recorder recorded.
    private static func snapshotForSaving(at packageURL: URL, edit: EditState) throws -> ProjectSnapshot {
        let existing = try? ProjectPackageIO.load(from: packageURL)
        let media = try mediaFilenames(in: packageURL)
        var snapshot = existing ?? ProjectSnapshot(
            schemaVersion: ProjectSnapshot.currentSchemaVersion,
            geometries: GeometryRegistry(), mediaFilenames: media)
        snapshot.edit = edit
        // The recorder writes the media before anything writes a manifest, so a package saved
        // for the first time has files the snapshot has never heard of.
        if snapshot.mediaFilenames.isEmpty { snapshot.mediaFilenames = media }
        return snapshot
    }

    private static func mediaFilenames(in packageURL: URL) throws -> [String] {
        let directory = packageURL.appending(path: mediaDirectory, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    // MARK: - opening

    /// The media and the edit inside a saved package.
    ///
    /// `nil` for the edit when the package has none, which is what a package produced by an
    /// older build looks like — and what a recording's own scratch directory looks like before
    /// anyone saves it.
    static func open(_ packageURL: URL) throws -> (mediaURL: URL, edit: EditState) {
        let snapshot = try ProjectPackageIO.load(from: packageURL)
        let media = try mediaFilenames(in: packageURL)
        guard let first = snapshot.mediaFilenames.first ?? media.first else {
            throw ProjectStoreError.noMedia(packageURL.lastPathComponent)
        }
        let mediaURL = packageURL.appending(path: mediaDirectory, directoryHint: .isDirectory)
            .appending(path: first)
        guard FileManager.default.fileExists(atPath: mediaURL.path) else {
            // The manifest names a file the package does not have. Said plainly rather than
            // opening an empty editor: a package missing its media is not a project a person
            // can do anything with, and the name is the only clue to what happened to it.
            throw ProjectStoreError.mediaMissing(first)
        }
        return (mediaURL, snapshot.edit)
    }

    // MARK: - panels

    /// The save panel. Named for the recording rather than "Untitled": a person saving a demo
    /// they just recorded is choosing WHERE, not what to call it, and a default name they have
    /// to replace is a step in the way.
    @MainActor
    static func chooseSaveDestination(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: packageExtension) ?? .package]
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    static func chooseProjectToOpen() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: packageExtension) ?? .package]
        panel.allowsMultipleSelection = false
        // A package IS a directory, so both have to be allowed or the panel refuses to select
        // one — and `canChooseDirectories` alone would let a person pick any folder.
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}

enum ProjectStoreError: Error, CustomStringConvertible, Equatable {
    case noMedia(String)
    case mediaMissing(String)

    var description: String {
        switch self {
        case .noMedia(let package):
            "\(package) has no recording in it"
        case .mediaMissing(let name):
            "the project refers to \(name), which is not in the package"
        }
    }
}
