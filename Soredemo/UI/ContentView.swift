//
//  ContentView.swift
//  Soredemo
//
//  Created by Jesse Liang on 2026/8/1.
//

import AVFoundation
import CoreGraphics
import Foundation
// `Capture` since Phase 3A-4 — the session, the source, permissions and `Minting`.
import Capture
import Observation
import Project
@preconcurrency import ScreenCaptureKit
import SwiftUI
import Timeline

/// A window with a rendered frame in it. Shows `StageWindow` once a recording exists; until then a
/// placeholder plus the "Open Recording…"/"Stop Recording" command wired in `SoredemoApp.body`.
/// Not document-bound: this is a scratch `WindowGroup`, so recording goes to a
/// `TemporaryFileMediaSink` rather than into a `.soredemo` package.
struct ContentView: View {
    let coordinator: RecordingCoordinator

    var body: some View {
        Group {
            if let mediaURL = coordinator.mediaURL {
                StageWindow(mediaURL: mediaURL)
                    // `StageWindow` carries no `.id(mediaURL)`, so `.onDisappear` fires only
                    // because `beginOpenRecording()` sets `mediaURL = nil` first, swapping this
                    // `Group`'s branch out and giving old and new `StageWindow` distinct view
                    // identities. Without it the scratch directory leaks; the launch sweep bounds it.
                    .onDisappear { coordinator.previewWasDismissed() }
            } else {
                ContentUnavailableView(
                    coordinator.isRecording ? "Recording…" : "No recording yet",
                    systemImage: coordinator.isRecording ? "record.circle" : "video.badge.plus",
                    description: Text(coordinator.statusText))
            }
        }
        .frame(minWidth: 480, minHeight: 320)
    }
}

#Preview {
    ContentView(coordinator: RecordingCoordinator())
}

// MARK: - Recording, straight into this window

/// Owns the one capture this window can show. `@Observable` so `ContentView` redraws as the
/// selection, recording and finished-file states change. One instance lives in `SoredemoApp`,
/// read by `ContentView` and driven by the "Open Recording…"/"Stop Recording" menu command.
@Observable
final class RecordingCoordinator {
    private(set) var mediaURL: URL?
    private(set) var isRecording = false
    private(set) var statusText =
        "Choose \u{201C}Open Recording\u{2026}\u{201D} from the File menu (\u{2318}R), record a few " +
        "seconds of anything, then choose \u{201C}Stop Recording\u{201D} to preview it here."

    /// Retained for the life of the pending selection: `SCContentSharingPicker.add(_:)` is not
    /// documented to retain its observer.
    private var picker: CaptureSourcePicker?
    private var session: CaptureSession?
    private var sink: TemporaryFileMediaSink?

    /// Which sink produced the current `mediaURL` — the file a live `AVPlayer` may have open.
    /// Compared by reference identity (`===` in `sourceSelected`), not `mediaURL` equality.
    /// Deleting its directory is `previewWasDismissed()`'s job, not `stopRecording()`'s, which
    /// would run before `mediaURL` moves; if that ever breaks, a directory leaks rather than
    /// being deleted under a live player.
    private var mediaSourceSink: TemporaryFileMediaSink?

    /// Called from `ContentView`'s `.onDisappear` when the `StageWindow` showing
    /// `mediaSourceSink`'s recording is torn down. Not `private`: `ContentView.body` is a
    /// different type in the same file, which `private` does not reach across.
    func previewWasDismissed() {
        if let directory = mediaSourceSink?.packageURL {
            try? FileManager.default.removeItem(at: directory)
        }
        mediaSourceSink = nil
    }

    /// Sweeps leftover scratch directories once, at construction — the earliest point this app
    /// runs, before any recording exists to protect.
    init() {
        TemporaryFileMediaSink.sweepLeftoverDirectories()
    }

    func toggleRecording() {
        if isRecording {
            Task { await stopRecording() }
        } else {
            beginOpenRecording()
        }
    }

    private func beginOpenRecording() {
        // Ask for Screen Recording, once, before the picker opens.
        // `SCContentSharingPicker`/`SCStream` never prompt on their own; without this a first-run
        // user is told "the user declined" by an API that never asked them.
        CapturePermissions.requestScreenRecordingAccess()

        mediaURL = nil
        statusText = "Choose what to record from the picker\u{2026}"
        let picker = CaptureSourcePicker(onSelect: { [self] source in
            Task { @MainActor in await sourceSelected(source) }
        })
        self.picker = picker
        picker.present()
    }

    private func sourceSelected(_ source: CaptureSource?) async {
        picker = nil
        guard let source else {
            statusText = "Recording cancelled. Choose \u{201C}Open Recording\u{2026}\u{201D} to try again."
            return
        }
        let scale = Self.scale(forDisplay: Self.sizingDisplayID(for: source))
        // `Self.displayIdentity(for:)`, not `displayUUID(for:)`: `AppSourceAllowListTests`'
        // ambient scan bans the substring "UUID(".
        let displayUUID = Self.displayIdentity(for: source)

        let newSink: TemporaryFileMediaSink
        do {
            newSink = try TemporaryFileMediaSink()
        } catch {
            statusText = "Could not create a scratch location for the recording: \(error)"
            return
        }
        // The outgoing sink is deleted here only when it never became what `mediaURL` points at —
        // an abandoned recording has nothing playing it. If it still equals `mediaSourceSink`,
        // `previewWasDismissed()` is still responsible for it, whichever order the two run in.
        if let outgoing = sink, outgoing !== mediaSourceSink, let directory = outgoing.packageURL {
            try? FileManager.default.removeItem(at: directory)
        }
        sink = newSink

        let newSession = CaptureSession(source: source, scale: scale, displayUUID: displayUUID,
                                        mediaSink: newSink, epoch: Minting.bootEpoch(),
                                        pointerShapeReader: SystemCursorShape.reader())
        session = newSession
        do {
            try await newSession.start()
            isRecording = true
            statusText = "Recording\u{2026} choose \u{201C}Stop Recording\u{201D} (\u{2318}R) when done."
        } catch {
            statusText = "Could not start recording: \(error)"
            session = nil
        }
    }

    private func stopRecording() async {
        guard let session else { return }
        isRecording = false
        statusText = "Finishing\u{2026}"
        do {
            let outcome = try await session.stop()
            let discardedCount: Int
            let firstMediaFilename: String?
            switch outcome {
            case .complete(let table):
                discardedCount = 0
                firstMediaFilename = table.segments.first?.mediaFilename
            case .incomplete(let table, let discarded):
                discardedCount = discarded.count
                firstMediaFilename = table.segments.first?.mediaFilename
            }
            if let firstMediaFilename, let url = sink?.url(for: firstMediaFilename) {
                // No deletion here: the `StageWindow` showing the previous sink is torn down
                // later, by SwiftUI reconciling this new `mediaURL`. `.onDisappear` observes it.
                mediaURL = url
                mediaSourceSink = sink
                statusText = discardedCount == 0 ? "" :
                    "\(discardedCount) segment(s) did not make it into the recording."
            } else {
                statusText = "The recording finished but produced no media."
            }
        } catch {
            statusText = "Could not stop recording: \(error)"
        }
        self.session = nil
    }

    // MARK: - scale / displayUUID

    /// The display whose mode decides `scale` for `CaptureSession.init`. A `.window` belongs to no
    /// single display, so the main display is used as an approximation: a window sitting on a
    /// differently-scaled secondary display gets the wrong `scale`.
    private static func sizingDisplayID(for source: CaptureSource) -> CGDirectDisplayID {
        switch source {
        case .display(let display): return display.displayID
        case .window: return CGMainDisplayID()
        }
    }

    /// `CGDisplayMode.pixelWidth / .width` — native pixels over points for the mode in use, which
    /// is `DisplayGeometry.scale`'s definition. Falls back to `2` when the display cannot be read.
    private static func scale(forDisplay displayID: CGDirectDisplayID) -> Double {
        guard let mode = CGDisplayCopyDisplayMode(displayID), mode.width > 0 else { return 2 }
        return Double(mode.pixelWidth) / Double(mode.width)
    }

    /// A display's persistent identity for `.display`. For `.window` the field instead carries a
    /// source identity minted fresh once per selection, per `CaptureSource.geometry(scale:displayUUID:)`.
    private static func displayIdentity(for source: CaptureSource) -> UUID {
        switch source {
        case .display(let display):
            return Minting.displayIdentity(of: display.displayID) ?? Minting.newIdentifier()
        case .window:
            return Minting.newIdentifier()
        }
    }
}

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
