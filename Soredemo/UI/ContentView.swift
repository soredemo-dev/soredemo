//
//  ContentView.swift
//  Soredemo
//
//  Created by Jesse Liang on 2026/8/1.
//

import AVFoundation
import CoreGraphics
import Foundation
import Observation
import Project
@preconcurrency import ScreenCaptureKit
import SwiftUI
import Timeline

/// Phase 2B Task 4's home for "a window with a rendered frame in it" — the first behaviour this
/// phase can show rather than only test. Shows `StageWindow` once a recording exists; until then, a
/// placeholder and the "Open Recording…"/"Stop Recording" command (wired in `SoredemoApp.body`,
/// which owns the one `RecordingCoordinator` this window reads) are the only way to get one.
///
/// **Not document-bound, and that is a correction to the task brief rather than an oversight.**
/// The brief's Step 5 asks for `StageWindow(mediaURL:)` "for the document's first segment" — but
/// this `ContentView` is `SoredemoApp`'s scratch `WindowGroup`, not `ProjectDocument
/// .makeWindowControllers()`'s document window (see `SoredemoApp.body`'s own doc comment: this
/// window exists only because `repo-skeleton`'s completion criterion needs a bare launch to reach
/// a window before any document is open). There is no document, and therefore no "first segment",
/// available here to read. The closest honest approximation that still makes a frame observable
/// without inventing a document-editing model Phase 2B does not ask for: record straight through
/// this window via the existing `CaptureSourcePicker`/`CaptureSession` pair, to a scratch location
/// (`TemporaryFileMediaSink`, below) rather than into a `.soredemo` package.
struct ContentView: View {
    let coordinator: RecordingCoordinator

    var body: some View {
        Group {
            if let mediaURL = coordinator.mediaURL {
                StageWindow(mediaURL: mediaURL)
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

/// Owns the one capture this window can show. `@Observable` so `ContentView` redraws as a
/// selection is made, a recording starts, and a finished file becomes a `mediaURL`
/// `StageWindow` can open — the same three-state shape `StageWindow.load()` already uses for
/// `player`/`failure`.
///
/// A single instance lives in `SoredemoApp` and is handed to both `ContentView` (to read) and the
/// "Open Recording…"/"Stop Recording" menu command (to drive) — see that file. It is not a
/// singleton reached through a static, unlike `StageCompositor.renderer` or `SoredemoApp
/// .retainedPicker`: nothing here is called back from an AVFoundation/ScreenCaptureKit queue that
/// cannot see an instance, so ordinary reference-passing is enough.
@Observable
final class RecordingCoordinator {
    private(set) var mediaURL: URL?
    private(set) var isRecording = false
    private(set) var statusText =
        "Choose \u{201C}Open Recording\u{2026}\u{201D} from the File menu (\u{2318}R), record a few " +
        "seconds of anything, then choose \u{201C}Stop Recording\u{201D} to preview it here."

    /// Retained for the life of the pending selection — `SCContentSharingPicker.add(_:)` is not
    /// documented to retain its observer, the same reasoning `SoredemoApp.retainedPicker`'s own
    /// doc comment gives.
    private var picker: CaptureSourcePicker?
    private var session: CaptureSession?
    private var sink: TemporaryFileMediaSink?

    func toggleRecording() {
        if isRecording {
            Task { await stopRecording() }
        } else {
            beginOpenRecording()
        }
    }

    private func beginOpenRecording() {
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
        // `Self.displayIdentity(for:)`, not `displayUUID(for:)` — `AppSourceAllowListTests`'
        // ambient scan bans the substring "UUID(" (per `Minting.displayIdentity`'s own doc
        // comment, which explains why that function has the name it has and not the more
        // obvious one); `displayUUID(for: source)` would have matched it, a false positive of
        // exactly the kind that doc comment describes as "the visible false positive its own
        // header describes as survivable" — found here by running `swift test`, not anticipated.
        let displayUUID = Self.displayIdentity(for: source)

        let newSink: TemporaryFileMediaSink
        do {
            newSink = try TemporaryFileMediaSink()
        } catch {
            statusText = "Could not create a scratch location for the recording: \(error)"
            return
        }
        sink = newSink

        let newSession = CaptureSession(source: source, scale: scale, displayUUID: displayUUID,
                                        mediaSink: newSink, epoch: Minting.bootEpoch())
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
                mediaURL = url
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

    // MARK: - scale / displayUUID, derived the way `spikes/2026-08-02-capture-master` and
    // `InputObserver.currentArrangement()` already do (see each function's own comment)

    /// The display whose mode decides `scale` for `CaptureSession.init`. For `.display`, the
    /// display actually being recorded. For `.window`, there is no single display a window
    /// belongs to (`CaptureSource`'s own header: a window's frame is extrinsic) — the main
    /// display is used as an approximation, the same one `CaptureSourcePicker`'s own derivation
    /// (`CaptureSource.init(pickerFilter:availableDisplays:)`) falls back on when nothing better
    /// is available. This is a known simplification, not a measured answer: a window captured
    /// while sitting on a differently-scaled secondary display would get the wrong `scale` here.
    private static func sizingDisplayID(for source: CaptureSource) -> CGDirectDisplayID {
        switch source {
        case .display(let display): return display.displayID
        case .window: return CGMainDisplayID()
        }
    }

    /// `CGDisplayMode.pixelWidth / .width`, the same ratio `InputObserver.currentArrangement()`
    /// uses and the same reason: it is native pixels over points for the mode actually in use,
    /// which is `DisplayGeometry.scale`'s own definition. Falls back to `2` — the same placeholder
    /// `spikes/2026-08-02-capture-master` uses — only when the display cannot be read at all.
    private static func scale(forDisplay displayID: CGDirectDisplayID) -> Double {
        guard let mode = CGDisplayCopyDisplayMode(displayID), mode.width > 0 else { return 2 }
        return Double(mode.pixelWidth) / Double(mode.width)
    }

    /// A display's persistent identity for `.display`, per `CaptureSource.geometry(scale
    /// :displayUUID:)`'s own doc comment. For `.window`, that same comment says this field is
    /// "reused" to carry "a source identity minted once per selection" — so a fresh identifier,
    /// not a literal display's UUID.
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
/// `.soredemo` package, and remembers where each named file landed.
///
/// **Why this exists instead of routing through `ProjectDocument.addMedia(_:named:)`.** That is
/// the shipping route `CaptureSession`'s own header describes as the only correct one for a
/// document-backed recording — but `ContentView` (see its doc comment) is not document-backed,
/// so there is no `ProjectDocument` here to write into. `StageWindow` reads a plain `URL` through
/// `AVURLAsset`, which has no opinion about where the file lives, so a scratch directory is enough
/// to make a frame observable without inventing a document for the sole purpose of holding it.
///
/// **Not cleaned up by this type, and not under `media/`.** `AGENTS.md`'s "never write to $HOME
/// and never commit media" governs the PROBE (`scripts/cross-boundary-digest-probe.swift`), which
/// this is not — it is the shipping app's own scratch storage, under `NSTemporaryDirectory()`,
/// which the OS reclaims on its own schedule. Deleting the file out from under a still-playing
/// `AVPlayer` the moment the coordinator finishes would be the wrong failure to introduce here.
final class TemporaryFileMediaSink: MediaSink, @unchecked Sendable {
    private let directory: URL
    private var urlsByName: [String: URL] = [:]

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "soredemo-preview-\(Minting.newIdentifier().uuidString)",
                      directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @MainActor
    func acceptMedia(_ data: Data, named name: String) throws {
        let url = directory.appending(path: name)
        try data.write(to: url)
        urlsByName[name] = url
    }

    @MainActor
    func url(for name: String) -> URL? { urlsByName[name] }
}
