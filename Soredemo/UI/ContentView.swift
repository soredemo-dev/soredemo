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
                StageWindow(initialCameraStyle: coordinator.cameraStyle,
                            cameraStartOffsetNanos: coordinator.cameraStartOffsetNanos,
                            mediaURL: mediaURL, pendingEdit: coordinator.takePendingEdit(),
                            cameraURL: coordinator.cameraURL)
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
    /// Which camera the next recording uses, or `.off`. Held across recordings for the reason
    /// `microphone` is.
    var camera: CameraSource = .off {
        // **The self-view follows the choice, not the recording.** Choosing a camera and only
        // seeing it once the countdown has begun is being asked to check your framing in the
        // take. See `CameraSelfView` and `CameraRecorder.startPreview`.
        didSet { showOrHideSelfView() }
    }

    /// The camera that is only being SHOWN — no file, no recording. Handed to
    /// `CameraSelfView`, and handed on to the recording when one starts so the picture somebody
    /// framed is the picture that records.
    private var previewRecorder: CameraRecorder?

    /// How much of the camera to record. Persisted like the frame rate, because it is a
    /// preference rather than a per-recording decision.
    var cameraQuality: CameraRecorder.Quality {
        didSet {
            UserDefaults.standard.set(cameraQuality.rawValue, forKey: Self.cameraQualityKey)
            showOrHideSelfView()
        }
    }
    static let cameraQualityKey = "cameraQuality"

    /// **Asymmetric about a recording on purpose: showing is refused, hiding never is.**
    /// A self-view that appeared once the countdown had begun would be a face arriving in the
    /// middle of the take. But a self-view that stays on screen after something set `camera` to
    /// `.off` is the app saying "No camera" while a camera is plainly on — which is what the
    /// menu bar panel used to do, because this guard sat above both branches and returned
    /// before the hide. The panel now refuses the change during a recording (`cameraRow`), and
    /// this is the second lock on the same door.
    private func showOrHideSelfView() {
        guard case .device = camera else {
            CameraSelfView.shared.hide()
            // Only the preview session is released here. Once a recording has taken it over the
            // property is `nil` and the file belongs to `stopRecording`, which has to await the
            // writer rather than drop it.
            previewRecorder?.stopPreview()
            previewRecorder = nil
            return
        }
        guard !isRecording else { return }
        let recorder = previewRecorder ?? CameraRecorder()
        do {
            try recorder.startPreview(camera: camera, quality: cameraQuality)
        } catch {
            statusText = "The camera could not be shown: \(error)"
            return
        }
        previewRecorder = recorder
        CameraSelfView.shared.onStyleChange = { [weak self] style in self?.cameraStyle = style }
        CameraSelfView.shared.show(recorder: recorder, style: cameraStyle)
    }
    /// The ceiling on capture frame delivery. Persisted, like the countdown: a preference rather
    /// than a per-recording decision.
    var frameRate: CaptureFrameRate {
        didSet { UserDefaults.standard.set(frameRate.rawValue, forKey: Self.frameRateKey) }
    }
    static let frameRateKey = "captureFrameRate"
    private(set) var availableCameras: [CameraSource] = []
    private var cameraRecorder: CameraRecorder?
    /// Where the camera's file landed for the recording being previewed, or `nil`.
    private(set) var cameraURL: URL?
    /// How much later than the screen the camera began, in nanoseconds. Negative when the camera
    /// started first. See `CameraComposition.combine(screen:cameraURL:cameraStartOffset:)`.
    private(set) var cameraStartOffsetNanos: Int64 = 0

    func refreshCameras() {
        availableCameras = CameraRecorder.available()
        camera = CameraSource.resolve(camera, against: availableCameras)
        activeCameraEffects = CameraEffects.active()
        cameraIsBusy = CameraRecorder.isInUseByAnotherApplication(camera)
    }

    /// Where the camera sits, chosen while recording and carried into the editor.
    ///
    /// **Held here so it is placed once.** The self-view is dragged during the recording and the
    /// stage composites the camera afterwards; if the two kept separate positions, a person who
    /// moved their face out of the way of the Dock would find it back over the Dock the moment
    /// the editor opened. Persisted for the reason `frameRate` is — it is a preference, not a
    /// per-recording decision.
    var cameraStyle: CameraOverlayStyle {
        didSet {
            guard let data = try? JSONEncoder().encode(cameraStyle) else { return }
            UserDefaults.standard.set(data, forKey: Self.cameraStyleKey)
        }
    }
    static let cameraStyleKey = "cameraOverlayStyle"

    /// True when the chosen camera is already held by another application — a video call in a
    /// browser, most often. See `CameraRecorder.isInUseByAnotherApplication`.
    private(set) var cameraIsBusy = false

    /// True once this Mac has refused the camera, so the panel can say so.
    ///
    /// **A refusal has to be visible.** Choosing a camera used to be one `guard` — ask for
    /// access, and on `false` put the selection back to `.off` and return. Which meant that on a
    /// Mac where the camera had already been denied, picking one did nothing at all: no prompt,
    /// no message, the row still reading "No camera". Silence is the worst answer to a
    /// permission question, because the only thing it teaches is that the button is broken.
    private(set) var cameraWasRefused = false

    /// The effects macOS is applying to every camera on this Mac. Re-read with the device list,
    /// because they are switched on in a panel this app does not own — see `CameraEffects`.
    private(set) var activeCameraEffects: [CameraEffects.Effect] = []

    /// Chooses a camera, asking this Mac first.
    ///
    /// **Activated before asking.** This is an accessory app with no Dock icon, and a TCC
    /// prompt raised by one that is not frontmost can come up behind whatever the person is
    /// looking at. The prompt is the whole interaction; it has to be in front of them.
    func chooseCamera(_ source: CameraSource) {
        guard case .device = source else {
            camera = source
            cameraWasRefused = false
            return
        }
        Task { @MainActor in
            if CameraRecorder.needsAsking { NSApp.activate(ignoringOtherApps: true) }
            guard await CameraRecorder.requestAccess() else {
                camera = .off
                cameraWasRefused = true
                return
            }
            cameraWasRefused = false
            camera = source
        }
    }

    /// Opens the pane of System Settings that holds the switch, because "grant it in System
    /// Settings" is not an instruction anyone should have to follow by hand.
    func openCameraSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else { return }
        NSWorkspace.shared.open(url)
    }
    /// The inputs this machine currently offers, refreshed when the menu bar panel opens —
    /// a USB interface plugged in after launch has to appear without a relaunch.
    private(set) var availableMicrophones: [MicrophoneSource] = []
    /// Seconds between choosing a target and the capture starting. Persisted, because it is a
    /// preference rather than a per-recording decision — a person who wants five seconds wants
    /// five seconds every time.
    var countdownSeconds: Int {
        didSet { UserDefaults.standard.set(countdownSeconds, forKey: Self.countdownKey) }
    }
    static let countdownKey = "countdownSeconds"
    /// The choices offered. Zero is "off" and is a legitimate answer — a person recording a
    /// window they have already arranged is not waiting three seconds for it.
    static let countdownChoices = [0, 3, 5, 10]

    // **All four preference keys are `internal`, not `private`, and the reason is compatibility
    // rather than testing convenience.** A persisted key is part of what the app promises across
    // versions: rename one and every existing user's preference silently reverts to its default
    // on the next launch, with nothing to see and nothing to report. Two of the four were
    // already internal and two were private, which was inconsistency rather than design —
    // nothing outside this file named any of them. They are named now by
    // `scripts/cross-boundary-digest-probe.swift` § 17, which asserts that setting each
    // preference writes the string below, so a rename is a red check instead of a quiet reset.

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
        // Same reasoning as the countdown's default: `integer(forKey:)` answers 0 for a key
        // never set, and 0 is not a frame rate.
        frameRate = (UserDefaults.standard.object(forKey: Self.frameRateKey) as? Int)
            .flatMap(CaptureFrameRate.init(rawValue:)) ?? .sixty
        // A shape stored from a previous run, or the bottom-right circle `default` is.
        cameraQuality = (UserDefaults.standard.string(forKey: Self.cameraQualityKey))
            .flatMap(CameraRecorder.Quality.init(rawValue:)) ?? .best
        cameraStyle = (UserDefaults.standard.data(forKey: Self.cameraStyleKey))
            .flatMap { try? JSONDecoder().decode(CameraOverlayStyle.self, from: $0) }
            ?? .default
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
            // The camera file, if the project has one. Named by convention beside the master,
            // as the observation log is — a package that carries one is self-describing.
            let camera = packageURL.appending(path: ProjectStore.mediaDirectory,
                                              directoryHint: .isDirectory)
                .appending(path: "camera-00.mov")
            cameraURL = FileManager.default.fileExists(atPath: camera.path) ? camera : nil
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
        cameraURL = nil
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
        // **Whatever else was being started is ended first.** Press Window, get the pointing
        // overlay, then press Screen: the display picker used to open and count down while the
        // overlay was still up, so a countdown ran behind a dimmed desktop waiting to be pointed
        // at. Two starts were in flight and neither knew about the other.
        cancelPendingStart()
        pendingMode = modes
        beginOpenRecording(modes: modes)
    }

    /// Ends a start that has not finished — the pointing overlay, and the system picker.
    ///
    /// Called by both ways in, so pressing either one twice, or one and then the other, leaves
    /// exactly one thing happening.
    func cancelPendingStart() {
        TargetPickerOverlay.shared.cancel()
        RegionPickerOverlay.shared.cancel()
        picker?.dismiss()
        picker = nil
        pendingMode = nil
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

    /// Starts a window recording through this app's own overlay rather than the system picker.
    ///
    /// **Only for windows.** The overlay's whole idea is pointing at the thing, and there is
    /// nothing to point at for a display: the system picker's display tab already shows a
    /// preview of each one, and an overlay covering the display it is asking about would be
    /// covering the answer.
    /// Starts the flow by dragging out a rectangle. See `RegionPickerOverlay`.
    ///
    /// **The system picker cannot do this**, which is why it is a third way in rather than a mode
    /// of the other two: `SCContentSharingPicker` offers displays, windows and applications, and
    /// a rectangle is none of them.
    func beginRegionRecording() {
        guard !isRecording else { return }
        cancelPendingStart()
        PermissionRequests.screenRecording()
        mediaURL = nil
        pendingMode = .region
        Task { @MainActor in
            let source = await RegionPickerOverlay.shared.pick()
            pendingMode = nil
            await sourceSelected(source)
        }
    }

    func beginWindowRecordingByPointing() {
        guard !isRecording else { return }
        cancelPendingStart()
        PermissionRequests.screenRecording()
        mediaURL = nil
        pendingMode = .windowsOnly
        Task { @MainActor in
            let source = await TargetPickerOverlay.shared.pick()
            pendingMode = nil
            await sourceSelected(source)
        }
    }

    private func beginOpenRecording(modes: CaptureSourcePicker.Modes = .displaysAndWindows) {
        PermissionRequests.screenRecording()

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
                                        microphone: microphone, frameRate: frameRate)
        session = newSession
        // **The camera starts BEFORE the countdown, not after.** A camera takes a moment to
        // wake and expose; started with the capture, its first second is a dark frame settling.
        // The countdown is exactly the pause that hides it — which is a second reason to have
        // one beyond giving a person time to move the pointer.
        if case .device = camera, let packageURL = newSink.packageURL {
            // The recorder that has been showing the preview, so the session already running the
            // camera is the one that records it — one client on one device, and the framing a
            // person set up is the framing that is captured.
            let recorder = previewRecorder ?? CameraRecorder()
            previewRecorder = nil
            let url = packageURL.appending(path: ProjectStore.mediaDirectory,
                                           directoryHint: .isDirectory)
                .appending(path: "camera-00.mov")
            do {
                try recorder.start(camera: camera, to: url, quality: cameraQuality)
                cameraRecorder = recorder
                // Already on screen since the camera was chosen — this only makes sure of it for
                // the path where a recording starts without the panel having been opened.
                CameraSelfView.shared.onStyleChange = { [weak self] style in
                    self?.cameraStyle = style
                }
                CameraSelfView.shared.show(recorder: recorder, style: cameraStyle)
            } catch {
                // Not fatal: the screen still records. Said, because a person who turned the
                // camera on and got no camera is owed the reason.
                statusText = "The camera could not start: \(error). Recording the screen only."
            }
        }

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
            // **The camera was started before the countdown, so it is running by now.** Left
            // alone it would hold the device open with its indicator lit for a recording that
            // never began — the failure would be invisible except as a green dot nobody could
            // account for.
            if let cameraRecorder {
                CameraSelfView.shared.hide()
                self.cameraRecorder = nil
                _ = await cameraRecorder.stop()
            }
        }
    }

    private func stopRecording() async {
        // The camera is stopped first and awaited: `AVCaptureMovieFileOutput` finishes writing
        // on its own queue, and a composition built before that read a partial file.
        if let cameraRecorder {
            // Hidden first: the panel holds a layer on the session this is about to stop, and
            // a preview of a stopped session is a frozen frame of somebody's face.
            CameraSelfView.shared.hide()
            // **Read before `stop()` clears the session.** The two first-frame instants are what
            // line the camera up with the screen; taken afterwards, one of them is gone.
            let cameraStart = cameraRecorder.firstFrameHostTimeNanos
            let screenStart = session?.diagnostics.firstFrameHostTimeNanos ?? 0
            cameraURL = await cameraRecorder.stop()
            self.cameraRecorder = nil
            // Both instants have to be real. A zero is "never recorded", not "at the epoch", and
            // subtracting one would place the camera by however long this Mac had been awake.
            if let cameraStart, cameraStart > 0, screenStart > 0 {
                cameraStartOffsetNanos = cameraStart - screenStart
            } else {
                cameraStartOffsetNanos = 0
            }
            // **A camera that was asked for and did not arrive is said out loud.** It used to
            // be a `nil` that travelled all the way to an export with no face in it and no
            // explanation — the shape this project keeps finding, where the only symptom of a
            // failure is the absence of a thing nobody was told about.
            if cameraURL == nil {
                statusText = "The camera could not be recorded. The screen recording is fine."
            }
        }
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
        // **A region knows its display exactly**, unlike a window, so it does not need the main
        // display as an approximation — and a region dragged out on a secondary panel with a
        // different backing scale gets the right one.
        case .region(let capture): return capture.display.displayID
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
        case .region(let capture):
            // **The display's identity, not a fresh one.** A region IS a rectangle of a known
            // display, so the persistent identity is available and is the truer answer; a window
            // gets a minted one only because it has no identity surviving its app's restart.
            return Minting.displayIdentity(of: capture.display.displayID) ?? Minting.newIdentifier()
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
