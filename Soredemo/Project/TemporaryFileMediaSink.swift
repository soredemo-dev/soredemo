import AVFoundation
import CoreGraphics
import Foundation
// `Capture` since Phase 3A-4 — the session, the source, permissions and `Minting`.
import Capture
import Geometry
import Observation
import Project
import Render
@preconcurrency import ScreenCaptureKit
import SwiftUI
import Timeline

/// Writes a `CaptureSession`'s finished segment bytes to a scratch location outside any
/// `.soredemo` package, and remembers where each named file landed. `ContentView` is not
/// document-backed, so there is no `ProjectDocument.addMedia(_:named:)` to route through.
///
/// Directories are cleaned up by `RecordingCoordinator`, not by this type: the outgoing sink is
/// deleted when it was never displayed, the displayed one by `previewWasDismissed()`, and
/// whatever either misses by `sweepLeftoverDirectories()` on the next launch.
///
/// Media lands under `media/` rather than flatly because
/// `ObservationWriter.expectedLogURL(forMediaURL:)` derives the sibling `observations/` path from
/// a `media/master-NN.mov` path; `packageURL` is the root both sit under.
final class TemporaryFileMediaSink: MediaSink, @unchecked Sendable {
    /// The naming convention every directory this type creates carries, and the only thing
    /// `sweepLeftoverDirectories()` trusts to identify one — never the layout inside it.
    private static let directoryNamePrefix = "soredemo-preview-"

    /// The package root — parent of both `media/` and `observations/`.
    private let directory: URL
    private var urlsByName: [String: URL] = [:]

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "\(Self.directoryNamePrefix)\(Minting.newIdentifier().uuidString)",
                      directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory.appending(path: "media", directoryHint: .isDirectory),
            withIntermediateDirectories: true)
    }

    /// Deletes every `soredemo-preview-*` directory under the temporary directory, whatever its
    /// layout. Safe to run unconditionally at launch, before any `mediaURL`/`AVPlayer` exists.
    /// `try?` per entry so one undeletable directory does not stop the sweep.
    static func sweepLeftoverDirectories() {
        let tmp = FileManager.default.temporaryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(directoryNamePrefix) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    @MainActor
    func acceptMedia(_ data: Data, named name: String) throws {
        let url = directory.appending(path: "media", directoryHint: .isDirectory).appending(path: name)
        try data.write(to: url)
        urlsByName[name] = url
    }

    @MainActor
    func url(for name: String) -> URL? { urlsByName[name] }

    /// The package root, for `CaptureSession` to open an `ObservationWriter` under. Never `nil`:
    /// a scratch sink always has somewhere to write the moment it exists.
    @MainActor
    var packageURL: URL? { directory }
}
