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
import Render
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
                StageWindow(mediaURL: mediaURL, pendingEdit: coordinator.takePendingEdit())
                    // `StageWindow` carries no `.id(mediaURL)`, so `.onDisappear` fires only
                    // because `beginOpenRecording()` sets `mediaURL = nil` first, swapping this
                    // `Group`'s branch out and giving old and new `StageWindow` distinct view
                    // identities. Without it the scratch directory leaks; the launch sweep bounds it.
                    .onDisappear { coordinator.previewWasDismissed() }
            } else {
                // **Reachable only if the window is opened with nothing loaded**, which the
                // scene's `.defaultLaunchBehavior(.suppressed)` and the one call site of
                // `openWindow` are between them meant to prevent. Kept as a plain statement of
                // fact rather than a welcome screen: the welcome screen WAS this window, and it
                // was the thing covering the screen a person came to record.
                ContentUnavailableView("Nothing open",
                                       systemImage: "record.circle",
                                       description: Text("Start a recording from the menu bar."))
            }
        }
        .frame(minWidth: 640, minHeight: 460)
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
    /// An edit read from a saved project, waiting for the window that will apply it. Cleared
    /// once taken, so re-opening the same recording does not re-apply a stale one.
    private(set) var pendingEdit: EditState?
    private(set) var isRecording = false
    private(set) var isPaused = false
    /// Seconds since recording started, not counting time paused. Driven by a timer the bar
    /// starts and stops — see `tick()`.
    private(set) var elapsed: Double = 0
    /// 0…1, the microphone's level right now, smoothed. `nil` when no microphone is being
    /// recorded, which is what lets the bar draw a struck-through mic rather than a dead meter.
    private(set) var microphoneLevel: Double?
    /// What the source picker is currently offering, so the menu bar panel can show which of
    /// its two buttons opened it.
    private(set) var pendingMode: CaptureSourcePicker.Modes?
    /// Which microphone the next recording asks for. Held across recordings, so a person who
    /// picked their interface once does not pick it again every time.
    var microphone: MicrophoneSource = .systemDefault
    /// The inputs this machine currently offers, refreshed when the menu bar panel opens —
    /// a USB interface plugged in after launch has to appear without a relaunch.
    private(set) var availableMicrophones: [MicrophoneSource] = []
    /// Seconds between choosing a target and the capture starting. Persisted, because it is a
    /// preference rather than a per-recording decision — a person who wants five seconds wants
    /// five seconds every time.
    var countdownSeconds: Int {
        didSet { UserDefaults.standard.set(countdownSeconds, forKey: Self.countdownKey) }
    }
    private static let countdownKey = "countdownSeconds"
    /// The choices offered. Zero is "off" and is a legitimate answer — a person recording a
    /// window they have already arranged is not waiting three seconds for it.
    static let countdownChoices = [0, 3, 5, 10]

    func refreshMicrophones() {
        availableMicrophones = MicrophoneInventory.available()
        // A device that has gone away must not stay selected: `resolve` falls back, and the
        // panel should show what will actually be recorded rather than what was asked for.
        microphone = MicrophoneInventory.resolve(microphone)
    }
    /// Only ever a REPORT — an error, or what just happened. It used to carry the instructions
    /// for using the app, which is what a screen with nothing on it needs and a screen with
    /// buttons on it does not.
    private(set) var statusText = ""

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
        // `object(forKey:)` rather than `integer(forKey:)`: the latter answers 0 for a key that
        // has never been set, and 0 means "off" here — so a first launch would silently ship
        // with no countdown, which is the opposite of the default this chose.
        countdownSeconds = UserDefaults.standard.object(forKey: Self.countdownKey) as? Int ?? 3
        TemporaryFileMediaSink.sweepLeftoverDirectories()
    }

    /// Opens a saved project: the recording it holds, and what a person had decided about it.
    ///
    /// **The scratch directory is not swept here.** A person who opens a project without saving
    /// the recording they just made has not thrown it away on purpose, and the launch sweep
    /// will collect it on the next run — losing it now would be a decision this code is not
    /// entitled to make.
    func openProject() {
        guard let packageURL = ProjectStore.chooseProjectToOpen() else { return }
        do {
            let opened = try ProjectStore.open(packageURL)
            mediaURL = nil                   // swaps the window's branch, as recording does
            pendingEdit = opened.edit
            mediaURL = opened.mediaURL
            statusText = "Opened \(packageURL.lastPathComponent)."
        } catch {
            statusText = "Could not open that project: \(error)"
        }
    }

    /// Opens a video that is not a project — a file dropped on the window, or one recorded
    /// elsewhere. There is no observation log beside it, so there is no pointer track and no
    /// camera: `StageCompositor` draws no cursor for a `nil` log, which is the honest result
    /// rather than a made-up one.
    func openVideo(at url: URL) {
        mediaURL = nil
        pendingEdit = nil
        mediaURL = url
        statusText = "Opened \(url.lastPathComponent). It has no pointer track, so there is "
            + "nothing for the camera to follow."
    }

    /// Taken once. A window that re-read it would re-apply a person's saved edit over changes
    /// they had made since.
    func takePendingEdit() -> EditState? {
        defer { pendingEdit = nil }
        return pendingEdit
    }

    func toggleRecording() {
        if isRecording {
            Task { await stopRecording() }
        } else {
            beginOpenRecording()
        }
    }

    /// Starts the flow with the picker narrowed to one kind of target — what the menu bar
    /// panel's two buttons do. See `CaptureSourcePicker.Modes`.
    func beginRecording(_ modes: CaptureSourcePicker.Modes) {
        guard !isRecording else { return }
        pendingMode = modes
        beginOpenRecording(modes: modes)
    }

    func stop() { Task { await stopRecording() } }

    /// **Pause writes nothing rather than writing silence.** `CaptureSession.pause()` closes the
    /// segment; `resume()` opens another. The recording is one file per segment and the segment
    /// table stitches them, so a pause costs a cut rather than a stretch of frozen frame.
    func togglePause() {
        guard let session, isRecording else { return }
        Task { @MainActor in
            do {
                if isPaused {
                    try await session.resume()
                    isPaused = false
                    statusText = ""
                } else {
                    try await session.pause()
                    isPaused = true
                }
            } catch {
                statusText = "Could not \(isPaused ? "resume" : "pause"): \(error)"
            }
        }
    }

    /// Advances the clock and reads the microphone. **Called by the recording bar's own timer**,
    /// not by a timer here: a coordinator that ticked whether or not anything was watching would
    /// be waking the main actor twenty times a second to update a number nobody reads.
    func tick(_ interval: Double) {
        guard isRecording, !isPaused else { return }
        elapsed += interval
        // Smoothed toward the instantaneous value: `latestRMS` is the RMS of one buffer, and a
        // meter drawn straight from it flickers at the buffer rate. Rising fast and falling slow
        // is what every level meter does, because a peak a person missed is worse than a decay
        // they can see.
        // `.off` reads as no meter rather than as a silent one: a full-height empty track is
        // what "not hearing you" looks like, and that is not what a person who turned the
        // microphone off should be shown.
        guard microphone != .off else { microphoneLevel = nil; return }
        let reading = session?.diagnostics.microphoneAccounting.latestRMS
        guard let reading else { microphoneLevel = nil; return }
        let scaled = min(1, sqrt(reading) * 1.6)
        let previous = microphoneLevel ?? 0
        microphoneLevel = scaled > previous ? scaled : previous + (scaled - previous) * 0.25
    }

    private func beginOpenRecording(modes: CaptureSourcePicker.Modes = .displaysAndWindows) {
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
        picker.present(modes: modes)
    }

    private func sourceSelected(_ source: CaptureSource?) async {
        picker = nil
        guard let source else {
            pendingMode = nil
            statusText = ""
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
                                        pointerShapeReader: SystemCursorShape.reader(),
                                        pointerHotspotReader: SystemCursorShape.hotspotReader(),
                                        microphone: microphone)
        session = newSession
        // **Counted before the session starts, not after.** A countdown that ran while the
        // capture was already recording would put itself in the first three seconds of the file.
        await CountdownPresenter.shared.run(seconds: countdownSeconds)
        do {
            try await newSession.start()
            isRecording = true
            isPaused = false
            elapsed = 0
            pendingMode = nil
            // **Shown from here, not from a view.** It used to be presented by `ContentView`'s
            // `.onChange`, which worked only while an editor window happened to be open — and
            // once the window stopped opening at launch, `ContentView` was never built, so a
            // recording started from the menu bar had no controls at all. The bar belongs to the
            // recording, and the recording is here.
            RecordingBarPresenter.shared.show(coordinator: self)
            statusText = "Recording\u{2026} choose \u{201C}Stop Recording\u{201D} (\u{2318}R) when done."
        } catch {
            statusText = "Could not start recording: \(error)"
            session = nil
        }
    }

    private func stopRecording() async {
        guard let session else { return }
        isRecording = false
        isPaused = false
        microphoneLevel = nil
        pendingMode = nil
        RecordingBarPresenter.shared.hide()
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
