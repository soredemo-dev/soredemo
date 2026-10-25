import AVFoundation
import CoreGraphics
import Foundation
// `Capture` since Phase 3A-4 — the session, the source, permissions and `Minting`.
import Capture
import Compositing
import Geometry
import Observation
import Project
import Render
@preconcurrency import ScreenCaptureKit
import SwiftUI
import Timeline

// MARK: - Recording, straight into this window

/// Owns the one capture this window can show. `@Observable` so `ContentView` redraws as the
/// selection, recording and finished-file states change. One instance lives in `SoredemoApp`,
/// read by `ContentView` and driven by the "Open Recording…"/"Stop Recording" menu command.
@Observable
final class RecordingCoordinator {
    private(set) var mediaURL: URL?
    /// The switches a person sets once — see `RecordingPreferences`. Read when a take starts.
    let preferences = RecordingPreferences()
    /// The camera the next take may carry — see `CameraController`. The coordinator answers
    /// whether a take is running and says its problems; the controller owns the choice and the
    /// self-view.
    let camera = CameraController()
    /// An edit read from a saved project, waiting for the window that will apply it. Cleared
    /// once taken, so re-opening the same recording does not re-apply a stale one.
    private(set) var pendingEdit: EditState?
    /// **The display is held awake by this and nothing else**, so every way a take starts or ends —
    /// a screen, a phone, a stop, a failure — takes or gives it back. See `TakeWakeLock`.
    private(set) var isRecording = false {
        didSet { isRecording ? guards.takeStarted() : guards.takeEnded() }
    }
    /// What watches the take while it runs — wake, sleep, disk, microphone. See `TakeGuards`.
    let guards = TakeGuards()
    /// Said when the take starts, if the estimate before it was low.
    private var lowDiskWarning: String?

    /// **Paused, not stopped, and not resumed on wake** — see `SleepPause`. A phone take has no
    /// pause, so it is left to the device.
    private func pauseBecauseTheMacIsSleeping() {
        guard isRecording, !isPaused, session != nil else { return }
        togglePause()
        status = .report(String(localized: "Paused because the Mac went to sleep. Resume or stop when you are back."))
    }
    private(set) var isPaused = false
    /// The menu bar daruma's second eye, painted when a take produces a file.
    let paintedEye = PaintedEye()
    /// Between the countdown ending and the capture running: `newSession.start()` is awaited.
    private(set) var isStartingCapture = false
    /// Seconds since recording started, not counting time paused. Driven by a timer the bar
    /// starts and stops — see `tick()`.
    private(set) var elapsed: Double = 0
    /// Whether the built-in speakers will be heard by the built-in microphone. Re-read when the
    /// notch opens and when the microphone changes; see `AudioRoute`.
    private(set) var speakersReachTheMicrophone = false
    /// What the source picker is currently offering, so the menu bar panel can show which of
    /// its two buttons opened it.
    private(set) var pendingMode: CaptureSourcePicker.Modes?
    /// Which microphone the next recording asks for. Held across recordings, so a person who
    /// picked their interface once does not pick it again every time.
    var microphone: MicrophoneSource = .systemDefault



    private var cameraRecorder: CameraRecorder?
    /// Where the camera's file landed for the recording being previewed, or `nil`.
    private(set) var cameraURL: URL?
    /// How much later than the screen the camera began, in nanoseconds. Negative when the camera
    /// started first. See `CameraComposition.combine(screen:cameraURL:cameraStartOffset:)`.
    private(set) var cameraStartOffsetNanos: Int64 = 0



    /// What the next Screen, Window or Area is chosen FOR: a take, or one picture.
    ///
    /// **A screenshot is a one-frame take** — the same pickers, the same filter, opened in the same
    /// editor as a short still movie, so the stage, crop, redaction and every annotation apply to
    /// it and *Export Frame* writes the picture. See
    /// `docs/design/2026-09-30-a-screenshot-is-a-one-frame-take.md`. Not persisted: a person who
    /// took one screenshot has not decided that the next press of Screen is a screenshot too.
    enum CapturePurpose: Hashable { case take, picture }
    var capturePurpose: CapturePurpose = .take

    /// How long a picture's still movie lasts: long enough that an annotation added at the
    /// playhead, which lasts `AnnotationsModel.defaultDuration`, is all inside it.
    static let pictureSeconds = 5.0

    /// The inputs this machine currently offers, refreshed when the menu bar panel opens —
    /// a USB interface plugged in after launch has to appear without a relaunch.
    private(set) var availableMicrophones: [MicrophoneSource] = []

    /// What this Mac has measured about the rolling clip buffer: the smallest load, in pixels per
    /// second, at which it had to be dropped. Absent on a fresh install, which is
    /// `ClipBufferFit.unmeasured`. A measurement, never a preference — nothing shows it and
    /// nobody sets it; see `ClipBufferFit` for why it is learned rather than a constant.
    static let clipBufferFitKey = "clipBufferSmallestLoadThatDidNotFit"

    /// The load the current recording started at, kept so that what the watchdog decides about
    /// it can be written back against the same number at stop.
    private var clipBufferLoad: Int?


    func refreshMicrophones() {
        availableMicrophones = MicrophoneInventory.available()
        // A device that has gone away must not stay selected: `resolve` falls back, and the
        // panel should show what will actually be recorded rather than what was asked for.
        microphone = MicrophoneInventory.resolve(microphone)
    }
    /// Only ever a REPORT — an error, or what just happened. It used to carry the instructions
    /// for using the app, which is what a screen with nothing on it needs and a screen with
    /// buttons on it does not.
    private(set) var status = Status.quiet
    var statusText: String { status.text }

    /// A sentence, and whether it says something went wrong — decided where it is written.
    ///
    /// **The panel used to decide by reading it:** a note was shown when the sentence contained
    /// "could not". Every sentence is `String(localized:)`, so in any other language nothing
    /// matched and no failure was ever shown there — and even in English six of the seven
    /// damaged-file sentences ("will not open", "has no picture in it") did not. Found by
    /// reading, 2026-09-26, while making the panel's labels translatable.
    struct Status: Equatable {
        let text: String
        let isProblem: Bool

        static let quiet = Status(text: "", isProblem: false)
        static func report(_ text: String) -> Status { Status(text: text, isProblem: false) }
        static func problem(_ text: String) -> Status { Status(text: text, isProblem: true) }
    }

    /// Retained for the life of the pending selection: `SCContentSharingPicker.add(_:)` is not
    /// documented to retain its observer.
    private var picker: CaptureSourcePicker?
    private var session: CaptureSession?
    private var sink: TemporaryFileMediaSink?
    /// The recorder writing a connected phone or tablet's screen, while one is being recorded.
    /// **Separate from `cameraRecorder`** — a phone is the subject, not a face in the corner,
    /// and one field holding either would make "is there a camera in this recording?" ambiguous.
    private var mobileRecorder: CameraRecorder?
    /// Connected phones and tablets, refreshed when the menu opens.
    private(set) var availableMobileScreens: [MobileScreen.Source] = []
    /// Phones and tablets that are plugged in but not offering their screens — locked, or not
    /// yet trusting this Mac. Named, because "unlock iPad and tap Trust" is a sentence somebody
    /// can act on and "no devices" is not.
    private(set) var mobileScreensWaiting: [String] = []

    /// Which sink produced the current `mediaURL` — the file a live `AVPlayer` may have open.
    /// Compared by reference identity (`===` in `sourceSelected`), not `mediaURL` equality.
    /// Deleting its directory is `previewWasDismissed()`'s job, not `stopRecording()`'s, which
    /// would run before `mediaURL` moves; if that ever breaks, a directory leaks rather than
    /// being deleted under a live player.
    private var mediaSourceSink: TemporaryFileMediaSink?

    /// Called from `ContentView`'s `.onDisappear` when the `StageWindow` showing
    /// `mediaSourceSink`'s recording is torn down. Not `private`: `ContentView.body` is a
    /// different type in the same file, which `private` does not reach across.
    /// The editor window has closed and the person agreed to it. **The recording is let go** —
    /// which takes the editor's view, and with it the player, off the screen and out of memory,
    /// and deletes a scratch recording's directory through `previewWasDismissed`. A saved one
    /// has already been copied into its package.
    func editorClosed() {
        mediaURL = nil
        UnsavedWorkGuard.shared.clear()
    }

    func previewWasDismissed() {
        if let directory = mediaSourceSink?.packageURL {
            try? FileManager.default.removeItem(at: directory)
        }
        mediaSourceSink = nil
    }

    /// Sweeps leftover scratch directories once, at construction — the earliest point this app
    /// runs, before any recording exists to protect.
    init() {
        camera.isTakeRunning = { [weak self] in self?.isRecording ?? false }
        camera.onProblem = { [weak self] in self?.status = .problem($0) }
        guards.onSleep = { [weak self] in self?.pauseBecauseTheMacIsSleeping() }
        // **Stopped while it can still be saved** — see `DiskWatch`. Said after the stop, so the
        // finishing messages do not cover it.
        guards.onDiskNearlyFull = { [weak self] in
            Task { @MainActor in
                await self?.stopRecording()
                self?.status = .problem(String(localized: "Stopped and saved: the disk was nearly full."))
            }
        }
        TemporaryFileMediaSink.sweepLeftoverDirectories()
    }

    /// Opens a saved project: the recording it holds, and what a person had decided about it.
    ///
    /// **The scratch directory is not swept here.** A person who opens a project without saving
    /// the recording they just made has not thrown it away on purpose, and the launch sweep
    /// will collect it on the next run — losing it now would be a decision this code is not
    /// entitled to make.
    func openProject() {
        guard mayReplaceWhatIsOpen() else { return }
        guard let packageURL = ProjectStore.chooseProjectToOpen() else { return }
        openProject(at: packageURL)
    }

    /// Opens a package whose location is already known — the menu item's own work, with the
    /// panel's answer supplied. See `--open-project` in `SoredemoApp`.
    func openProject(at packageURL: URL) {
        do {
            let opened = try ProjectStore.open(packageURL)
            mediaURL = nil                   // swaps the window's branch, as recording does
            cameraURL = opened.cameraURL
            pendingEdit = opened.edit
            mediaURL = opened.mediaURL
            status = .report(String(localized: "Opened \(packageURL.lastPathComponent)."))
        } catch {
            status = .problem(String(localized: "Could not open that project: \(String(describing: error))"))
        }
    }

    /// Opens a video that is not a project — a file dropped on the window, or one recorded
    /// elsewhere. There is no observation log beside it, so there is no pointer track and no
    /// camera: `StageCompositor` draws no cursor for a `nil` log, which is the honest result
    /// rather than a made-up one.
    /// Asks for a video and opens it. **The panel lives here rather than at each call site**
    /// — the menu-bar footer and the File menu both need it, and two panels configured
    /// separately drift into accepting different things.
    func openVideoFromPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ImportedRecording.readableTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openVideo(at: url)
    }

    func openVideo(at url: URL) {
        guard mayReplaceWhatIsOpen() else { return }
        Task { await openVideoStaged(at: url) }
    }

    /// Whether a new recording may take the place of the one that is open.
    ///
    /// **One editor, so opening something is replacing something — and it asks first.**
    /// `EditorWindowPresence` refuses a second editor window on purpose: two would be two sets
    /// of models over one set of process-global compositor statics. That decision makes every
    /// "open" into a "replace", and a replace that discarded somebody's edits without a word
    /// would be the worst possible reading of a drag they may have meant for the Finder.
    ///
    /// **This was missing, and not only for drops.** `UnsavedWorkGuard.mayDiscard` existed and
    /// quitting was its only caller — so opening a project over unsaved edits threw them away
    /// silently, and had done since the guard was written. The dialogue offers Save first and
    /// Cancel second, because a person who dragged the wrong file presses Return next.
    private func mayReplaceWhatIsOpen() -> Bool {
        guard mediaURL != nil else { return true }
        return UnsavedWorkGuard.shared.mayDiscard(asking: "Save this recording before opening another?")
    }

    /// **Staged into a scratch package rather than opened where it lies.**
    ///
    /// This function existed and nothing could reach it — no drop target, no menu item — and it
    /// opened the file in place. In place is wrong for every path that treats a recording's
    /// grandparent as its package: `ObservationWriter.expectedLogURL` looks beside it, and noise
    /// removal writes its cleaned audio there. Opening `~/Desktop/demo.mp4` made the package `~`
    /// and would have put a cleaned audio track in somebody's home folder.
    ///
    /// The original is never moved. `ImportedRecording` links it when the volume allows and
    /// copies it otherwise.
    private func openVideoStaged(at url: URL) async {
        do {
            let staged = try await ImportedRecording.stage(url)
            mediaURL = nil
            pendingEdit = nil
            cameraURL = nil
            cameraStartOffsetNanos = 0
            // Held so the scratch package outlives this call — the same ownership a recording's
            // own sink has, and without it the directory is swept out from under the editor.
            mediaSourceSink = staged.sink
            sink = staged.sink
            mediaURL = staged.mediaURL
            // **One literal, over the 100-column line, on purpose.** A key is the literal the
            // compiler builds; two strings joined with `+` build two keys and look neither of
            // them up. Wrapping this sentence is what put it in English in all ten languages.
            status = .report(String(localized:
                "Opened \(url.lastPathComponent). Zooms will be found from what changes on screen \u{2014} there is no pointer track in an imported video."))
        } catch {
            status = .problem(String(localized: "Could not open that video: \(String(describing: error))"))
        }
    }

    /// One picture of `source`, opened in the editor as a still movie. No countdown and no camera:
    /// a picture is of what is on screen now.
    private func takePicture(of source: CaptureSource) async {
        pendingMode = nil
        guard mayReplaceWhatIsOpen() else {
            status = .quiet
            return
        }
        do {
            let image = try await Screenshot.capture(
                source, scale: Self.scale(forDisplay: Self.sizingDisplayID(for: source)),
                displayUUID: Self.displayIdentity(for: source),
                // The switches a take would use, so a screenshot leaves out exactly what a
                // recording of the same thing would.
                exclusions: preferences.exclusions)
            // A directory of its own that the system reclaims, rather than a named temporary file
            // two screenshots in one second could both claim.
            let folder = try FileManager.default.url(for: .itemReplacementDirectory,
                                                     in: .userDomainMask,
                                                     appropriateFor: FileManager.default.temporaryDirectory,
                                                     create: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let movie = folder.appending(path: String(localized: "Screenshot") + ".mov")
            try await StillMovie.write(image, seconds: Self.pictureSeconds, to: movie)
            await openVideoStaged(at: movie)
            guard mediaURL != nil else { return }
            status = .report(String(localized: "Screenshot taken. Add a background or annotations, then choose Export Frame\u{2026}"))
        } catch {
            status = .problem(String(localized: "The screenshot could not be taken: \(String(describing: error))"))
        }
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

    /// A content scale as a percentage, for the resize message. **Rounded to whole percent**:
    /// the difference between 98% and 98.4% is not something anybody can act on.
    private static func percent(_ scale: Double) -> String {
        "\(Int((scale * 100).rounded()))%"
    }

    /// Whether the last few seconds could be saved right now. See `CaptureSession.ClipBuffer`.
    var clipReadiness: CaptureSession.ClipReadiness {
        session?.clipReadiness ?? .thisSystemHasNoClipBuffer
    }

    /// Writes the last `seconds` beside the recording and says what happened.
    ///
    /// **Into the scratch package, not a save panel.** Somebody pressing this has just watched
    /// something go wrong; a file dialog in that moment is a dialog they dismiss. It lands
    /// beside the recording, and the status line says where.
    func saveClip(lastSeconds seconds: Double) {
        guard let session, let sink else { return }
        Task {
            // **`Minting`, not `Date()`.** Ambient values enter this app at one audited place
            // and travel as plain values — rule 3, and it is zero-permit in the app target.
            let stamp = String(Minting.epochAnchor().wallClockUnixNanos / 1_000_000_000)
            let destination = sink.packageURL?
                .appending(path: "clip-\(stamp).mov", directoryHint: .notDirectory)
            guard let destination else {
                status = .problem(String(localized: "There is nowhere to put the clip yet."))
                return
            }
            switch await session.saveClip(lastSeconds: seconds, to: destination) {
            case .wrote(let url):
                status = .report(String(localized: "Saved the last \(Int(seconds)) seconds to \(url.lastPathComponent)."))
            case .refused(let reason):
                status = .problem(String(localized: "The clip could not be saved: \(reason)"))
            }
        }
    }

    /// **Pause writes nothing rather than writing silence.** `CaptureSession.pause()` closes the
    /// segment; `resume()` opens another. The recording is one file per segment and the segment
    /// table stitches them, so a pause costs a cut rather than a stretch of frozen frame.
    /// The take's controls: in the notch when the notch surface is up, the floating bar otherwise.
    /// See `2026-09-27-the-recorder-lives-in-the-notch.md`.
    private func showRecordingControls() {
        // The clock first, and here rather than in either surface: it belongs to the take.
        clock.start { [weak self] interval in self?.tick(interval) }
        if NotchSurfacePresenter.shared.hostsTheTake {
            NotchSurfacePresenter.shared.recordingBegan()
        } else {
            RecordingBarPresenter.shared.show(coordinator: self)
        }
    }

    private func hideRecordingControls() {
        clock.stop()
        RecordingBarPresenter.shared.hide()
        NotchSurfacePresenter.shared.recordingEnded()
    }

    /// Re-reads whether the speakers will reach the microphone. Cheap — three Core Audio reads.
    func refreshAudioRoute() {
        speakersReachTheMicrophone = AudioRoute.speakersReachTheMicrophone(for: microphone)
    }

    func togglePause() {
        guard let session, isRecording else { return }
        Task { @MainActor in
            do {
                if isPaused {
                    try await session.resume()
                    isPaused = false
                    // A pause closed the segment and its copy is made: the disk count starts again.
                    guards.segmentResumed()
                    status = .quiet
                } else {
                    try await session.pause()
                    isPaused = true
                }
            } catch {
                status = .problem(isPaused
                    ? String(localized: "Could not resume: \(String(describing: error))")
                    : String(localized: "Could not pause: \(String(describing: error))"))
            }
        }
    }

    /// The take's clock — see `RecordingClock` for why it lives here and not in a surface. 20 Hz:
    /// fast enough that the level meter moves rather than steps, slow enough not to cost a frame
    /// on a machine already encoding video — the rate the bar's timer ran at.
    private let clock = RecordingClock(interval: 0.05)

    /// Advances the time and reads the microphone. **Called only by `clock`**, and only while a
    /// take is running, so the main actor is not woken for a number nobody reads.
    func tick(_ interval: Double) {
        guard isRecording, !isPaused else { return }
        // **What has been written, when there is a writer to ask.** Adding up ticks lost every
        // tick a busy main actor dropped — one counted where twenty were due (audit R9). A phone
        // take has no session to ask, and keeps the tick sum.
        if let recorded = session?.recordedDuration {
            elapsed = Double(recorded.rawValue) / 1_000_000_000
        } else {
            elapsed += interval
        }
        let accounting = session?.diagnostics.microphoneAccounting
        guards.tick(interval: interval, microphoneOff: microphone == .off,
                    microphone: accounting.map { (delivered: $0.delivered, latestRMS: $0.latestRMS) })
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
        status = .report(String(localized: "Choose what to record from the picker\u{2026}"))
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
            status = .quiet
            return
        }
        // **The one branch.** Every picker meets here, so a screenshot needs no picker of its own.
        if capturePurpose == .picture {
            await takePicture(of: source)
            return
        }
        let scale = Self.scale(forDisplay: Self.sizingDisplayID(for: source))
        // `Self.displayIdentity(for:)`, not `displayUUID(for:)`: `AppSourceAllowListTests`'
        // ambient scan bans the substring "UUID(".
        let displayUUID = Self.displayIdentity(for: source)

        // **Before anything starts**: a take that cannot be saved is worse than one that did not
        // begin. An estimate — the take itself is measured by `DiskWatch`.
        let size = source.geometry(scale: scale, displayUUID: displayUUID)
        switch DiskHeadroom.verdict(available: DiskHeadroom.availableBytes(),
                                    bytesPerSecond: DiskHeadroom.bytesPerSecond(
                                        pixelWidth: size.pixelWidth, pixelHeight: size.pixelHeight,
                                        frameRate: preferences.frameRate.rawValue)) {
        case .tooLittle:
            pendingMode = nil
            status = .problem(String(localized: "There is not enough free disk space for a minute of recording at this size. Free some space and try again."))
            return
        case .low(let minutes):
            lowDiskWarning = String(localized: "About \(minutes) minutes of disk space left at this size.")
        case .plenty:
            lowDiskWarning = nil
        }

        let newSink: TemporaryFileMediaSink
        do {
            newSink = try TemporaryFileMediaSink()
        } catch {
            status = .problem(String(localized: "Could not create a scratch location for the recording: \(String(describing: error))"))
            return
        }
        // The outgoing sink is deleted here only when it never became what `mediaURL` points at —
        // an abandoned recording has nothing playing it. If it still equals `mediaSourceSink`,
        // `previewWasDismissed()` is still responsible for it, whichever order the two run in.
        if let outgoing = sink, outgoing !== mediaSourceSink, let directory = outgoing.packageURL {
            try? FileManager.default.removeItem(at: directory)
        }
        sink = newSink

        // **Decided before the session exists, from what this Mac has already measured.** The
        // clip buffer's second encode halves the frame rate when it does not fit, and attaching
        // it only to find that out puts a stutter in the recording. The same geometry call the
        // session makes, so the two cannot disagree about the size.
        let geometry = source.geometry(scale: scale, displayUUID: displayUUID)
        let load = ClipBufferFit.load(width: geometry.pixelWidth, height: geometry.pixelHeight,
                                      frameRate: preferences.frameRate.rawValue)
        clipBufferLoad = load
        let learnedFit = ClipBufferFit(smallestLoadThatDidNotFit:
            UserDefaults.standard.object(forKey: Self.clipBufferFitKey) as? Int)

        let newSession = CaptureSession(source: source, scale: scale, displayUUID: displayUUID,
                                        mediaSink: newSink, epoch: Minting.bootEpoch(),
                                        pointerShapeReader: SystemCursorShape.reader(),
                                        pointerHotspotReader: SystemCursorShape.hotspotReader(),
                                        microphone: microphone,
                                        capturesSystemAudio: preferences.capturesSystemAudio,
                                        frameRate: preferences.frameRate,
                                        // Passed as the person's ANSWER, not as a resolved list:
                                        // the session looks the Dock up per segment, because a
                                        // window object taken now would be stale by the time a
                                        // second segment opens. See `CaptureExclusions`.
                                        exclusions: preferences.exclusions,
                                        attachesClipBuffer: learnedFit.attaches(atLoad: load))
        session = newSession
        // **This app's own windows, told to the capture before it starts.** The accessibility
        // observer must never hit-test a point over one of them; see `OwnWindowReporter`. Told
        // again whenever a window appears, moves or goes away — `observeOwnWindows()` — because
        // the bar a person drags mid-recording is precisely the window this is about.
        newSession.setOwnWindows(OwnWindowReporter.current())
        observeOwnWindows(for: newSession)
        // **The camera starts BEFORE the countdown, not after.** A camera takes a moment to
        // wake and expose; started with the capture, its first second is a dark frame settling.
        // The countdown is exactly the pause that hides it — which is a second reason to have
        // one beyond giving a person time to move the pointer.
        if camera.wantsRecording, let packageURL = newSink.packageURL {
            // **The preview session is handed over, not replaced** — the camera already showing
            // the person's face is the one that records it. See
            // `CameraController.startRecording(to:)`.
            let url = packageURL.appending(path: ProjectStore.mediaDirectory,
                                           directoryHint: .isDirectory)
                .appending(path: ProjectStore.cameraFilename)
            do {
                cameraRecorder = try camera.startRecording(to: url)
            } catch {
                // Not fatal: the screen still records. Said, because a person who turned the
                // camera on and got no camera is owed the reason.
                status = .problem(String(localized: "The camera could not start: \(String(describing: error)). Recording the screen only."))
            }
        }

        // **Hidden before the countdown, not after it.** Finder takes a moment to come back
        // and redraw, and a desktop whose icons vanish during the first second of the take is
        // worse than one that never hid them. Counting down over an already-clean desktop also
        // lets the person SEE that it worked before anything is recorded.
        if preferences.hidesDesktopIcons { DesktopIcons.hide() }

        // **Counted before the session starts, not after.** A countdown that ran while the
        // capture was already recording would put itself in the first three seconds of the file.
        // **Cancellable, and the cancel has to undo what starting already did.** The desktop
        // icons are hidden before the count so a person can see that it worked; walking away
        // from the recording without putting them back would leave the machine changed by
        // something that never happened.
        guard await CountdownPresenter.shared.run(seconds: preferences.countdownSeconds,
                                                  subject: source.countdownSubject) else {
            if preferences.hidesDesktopIcons { DesktopIcons.restore() }
            // The camera RECORDER is stopped and its file dropped with the scratch package; the
            // self-view is left alone, because it follows the camera somebody CHOSE and not a
            // recording that did not happen.
            if let recorder = cameraRecorder {
                _ = await recorder.stop()
                cameraRecorder = nil
            }
            if let directory = newSink.packageURL {
                try? FileManager.default.removeItem(at: directory)
            }
            sink = nil
            session = nil
            pendingMode = nil
            status = .report(String(localized: "Recording cancelled."))
            return
        }
        isStartingCapture = true
        do {
            try await newSession.start()
            isStartingCapture = false
            isRecording = true
            isPaused = false
            elapsed = 0
            pendingMode = nil
            // **Shown from here, not from a view.** It used to be presented by `ContentView`'s
            // `.onChange`, which worked only while an editor window happened to be open — and
            // once the window stopped opening at launch, `ContentView` was never built, so a
            // recording started from the menu bar had no controls at all. The bar belongs to the
            // recording, and the recording is here.
            showRecordingControls()
            // The disk warning outranks the reminder of how to stop: it is the one that can cost the take.
            status = .report(lowDiskWarning ?? String(localized: "Recording\u{2026} choose \u{201C}Stop Recording\u{201D} (\u{2318}R) when done."))
        } catch {
            isStartingCapture = false
            status = .problem(String(localized: "Could not start recording: \(String(describing: error))"))
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

    /// Re-reads which phones and tablets are plugged in.
    ///
    /// **Called when the menu opens rather than watched.** Device arrival has no notification
    /// this app can use without a `CMIO` listener, and a phone is plugged in seconds before
    /// somebody records it — the menu opening is exactly that moment.
    func refreshMobileScreens() {
        availableMobileScreens = MobileScreen.available()
        // **The empty list has a knowable cause, and saying nothing about it is the worst
        // answer.** Measured with an iPad plugged in and locked: the device is on the USB bus
        // and exposes PTP, Apple's multiplexor and network-over-USB — but not its screen. So the
        // capture list is correctly empty and a person is looking at a cable in their hand,
        // wondering what they did wrong.
        mobileScreensWaiting = availableMobileScreens.isEmpty
            ? MobileScreen.attachedButUnavailable() : []
    }

    /// Records a connected phone or tablet's screen.
    ///
    /// **A separate, shorter path than `beginRecording`, and it is shorter because there is less
    /// to record.** A Mac recording carries an observation log — the cursor, the clicks, the
    /// accessibility chain — which is what the automatic framing is derived from. A phone has
    /// none of that: no pointer, no AX tree, no clicks visible to this Mac. So there is no
    /// `CaptureSession`, no `ObservationWriter`, and no observation log; there is a device, a
    /// file, and the editor.
    ///
    /// Everything downstream still works — the look, the background, cutting, speed, captions,
    /// export — because all of those read the recording rather than the log. Automatic zoom does
    /// not, and cannot, and that is said in the interface rather than left to be noticed.
    func beginMobileRecording(_ source: MobileScreen.Source) {
        guard !isRecording else { return }
        let newSink: TemporaryFileMediaSink
        do {
            newSink = try TemporaryFileMediaSink()
        } catch {
            status = .problem(String(localized: "Could not create a scratch location for the recording: \(String(describing: error))"))
            return
        }
        guard let package = newSink.packageURL else {
            status = .problem(String(localized: "Could not create a scratch location for the recording."))
            return
        }
        // The same name and place a Mac recording's master takes, so the editor, the project
        // store and `ObservationWriter.expectedLogURL` all see the shape they expect — the log
        // simply is not there, which every reader of it already treats as "no observations".
        let destination = package.appending(path: "media", directoryHint: .isDirectory)
            .appending(path: "master-00.mov")

        let recorder = CameraRecorder()
        do {
            try recorder.start(camera: source.asCaptureDevice, to: destination)
        } catch {
            status = .problem(String(localized: "Could not record \(source.name): \(String(describing: error))"))
            return
        }
        sink = newSink
        mobileRecorder = recorder
        isRecording = true
        isPaused = false
        elapsed = 0
        pendingMode = nil
        showRecordingControls()
        status = .report(String(localized: "Recording \(source.name)\u{2026} choose \u{201C}Stop Recording\u{201D} (\u{2318}R) when done."))
    }

    /// Finishes a phone recording and opens it. Returns `false` when there was not one.
    ///
    /// **Checked before `stopRecording`'s own work**, because that path reads `session`, which a
    /// phone recording never had.
    private func stopMobileRecording() async -> Bool {
        guard let recorder = mobileRecorder else { return false }
        mobileRecorder = nil
        isRecording = false
        isPaused = false
        pendingMode = nil
        hideRecordingControls()
        status = .report(String(localized: "Finishing\u{2026}"))
        DesktopIcons.restore()

        let written = await recorder.stop()
        guard let written else {
            status = .problem(String(localized: "The recording could not be written."))
            return true
        }
        mediaSourceSink = sink
        mediaURL = written
        paintedEye.paint()
        // **No camera offset and no camera.** A phone recording has one video track; setting a
        // stale offset from a previous take would place a camera that is not there.
        cameraURL = nil
        cameraStartOffsetNanos = 0
        status = .report(String(localized: "Recorded \(written.lastPathComponent)."))
        return true
    }

    /// Writes back what this recording proved about the clip buffer — and nothing, when it
    /// proved nothing.
    ///
    /// **Only a JUDGED outcome is learned from.** A recording that stopped before the watchdog's
    /// window closed, or one that never carried the buffer, says nothing about whether this Mac
    /// can afford it, and treating it as a keep would clear a threshold that was measured.
    private func learnClipBufferFit(from diagnostics: CaptureSession.Diagnostics) {
        guard let load = clipBufferLoad else { return }
        clipBufferLoad = nil
        let wasDropped = diagnostics.clipBufferDropped != nil
        guard wasDropped || diagnostics.clipBufferKept else { return }
        let before = ClipBufferFit(smallestLoadThatDidNotFit:
            UserDefaults.standard.object(forKey: Self.clipBufferFitKey) as? Int)
        let after = before.learning(load: load, wasDropped: wasDropped)
        if let limit = after.smallestLoadThatDidNotFit {
            UserDefaults.standard.set(limit, forKey: Self.clipBufferFitKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.clipBufferFitKey)
        }
    }

    private func stopRecording() async {
        // A phone recording has no `CaptureSession` and no camera; it finishes on its own path
        // and this one would read a `session` that never existed.
        if await stopMobileRecording() { return }
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
                status = .problem(String(localized: "The camera could not be recorded. The screen recording is fine."))
            }
        }
        // **Restored unconditionally, not `if hidesDesktopIcons`.** The preference can be turned
        // off DURING a recording that hid them, and reading it here would then strand the icons.
        // `restore()` decides for itself, from the debt it recorded when it hid them.
        DesktopIcons.restore()

        guard let session else { return }
        isRecording = false
        isPaused = false
        pendingMode = nil
        hideRecordingControls()
        status = .report(String(localized: "Finishing\u{2026}"))
        do {
            let outcome = try await session.stop()
            learnClipBufferFit(from: session.diagnostics)
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
                paintedEye.paint()
                status = discardedCount == 0 ? .quiet : .problem(String(localized:
                    "\(discardedCount) segment(s) did not make it into the recording."))

                // **The file is checked before anybody is told the recording worked.**
                //
                // The worst failure this app can have is not a crash. It is somebody who talks
                // for eleven minutes, presses stop, and finds out in the editor — or on the day
                // they meant to publish — that the file is four seconds long or will not open.
                // A crash costs a restart; that costs the eleven minutes, and they cannot be
                // recorded again, and nothing here checked.
                //
                // **Said in the status line rather than in a dialog**, because there is nothing
                // to decide: the recording is already over and the only useful thing is knowing
                // now instead of later. A healthy recording says nothing at all — a message on
                // every take is a message people stop reading, including the one that matters.
                let elapsedSoFar = Nanoseconds(Int64((elapsed * 1_000_000_000).rounded()))
                let health = await RecordingCheck.health(of: url, session: elapsedSoFar)
                if case .damaged(let damage) = health {
                    status = .problem(Self.wording(for: damage, file: url.lastPathComponent))
                } else if let range = session.diagnostics.resamplingRange {
                    // **A window resized mid-recording, said rather than left to be noticed.**
                    // The frame size is fixed when a segment opens, so a resize is carried by
                    // scaling the content into the frame it already has: smaller leaves it
                    // padded, larger is a downscale and a softer picture. The session has
                    // counted this since it was written and nothing ever read the counters,
                    // so the only way to find out was to look at the result and wonder.
                    status = .problem(String(localized:
                        "The window changed size while recording, so part of it was scaled to fit the frame (\(Self.percent(range.low))–\(Self.percent(range.high))). The recording is usable; a window kept at one size stays sharp."))
                }
            } else {
                status = .problem(String(localized: "The recording finished but produced no media."))
            }
        } catch {
            status = .problem(String(localized: "Could not stop recording: \(String(describing: error))"))
        }
        stopObservingOwnWindows()
        self.session = nil
    }

    /// What to tell somebody whose recording did not survive.
    ///
    /// **Each damage has its own sentence, because each has a different next step.** "Something
    /// went wrong" leaves a person with a file they cannot judge; being told the container will
    /// not open tells them the recording died mid-write, which is a different problem from being
    /// told it is a fraction of the length they recorded.
    ///
    /// Every one of them names the file. It is the only way somebody with several takes works
    /// out which one this is about.
    static func wording(for damage: RecordingHealth.Damage, file: String) -> String {
        switch damage {
        case .theFileIsNotThere:
            String(localized: "\(file) is not there. The recording did not reach the disk.")
        case .theFileIsEmpty:
            String(localized:
                "\(file) has no data in it. The recording stopped before anything was written.")
        case .theSizeCannotBeRead:
            String(localized:
                "\(file) is there and its size could not be read. It says nothing about what was captured.")
        case .theContainerWillNotOpen:
            String(localized:
                "\(file) will not open. The recording was interrupted before it could be closed.")
        case .thereIsNoVideoTrack:
            String(localized: "\(file) has no picture in it. No frames reached the recorder.")
        case .theVideoWillNotDecode:
            String(localized: "\(file) opens but its picture cannot be read.")
        case .itIsShorterThanTheSession:
            String(localized:
                "\(file) is much shorter than the time you recorded for. Check it before you rely on it.")
        }
    }

    // MARK: - this app's own windows

    /// Watchers that keep the capture's idea of our windows current. Held so they can be taken
    /// down with the recording; a notification that outlived it would publish into a session
    /// that is gone.
    private var ownWindowWatchers: [any NSObjectProtocol] = []

    /// Re-publishes our window list on every event that could change it.
    ///
    /// **`didMove` is the one that matters and the one a frame would miss.** The reported crash
    /// is somebody dragging the recording bar, so the window whose position must stay current is
    /// moving continuously while the observer is running. Publishing IDs rather than frames means
    /// each notification costs a list of integers, not a geometry read.
    private func observeOwnWindows(for session: CaptureSession) {
        stopObservingOwnWindows()
        let centre = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didMoveNotification, NSWindow.didResizeNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification,
        ]
        ownWindowWatchers = names.map { name in
            centre.addObserver(forName: name, object: nil, queue: .main) { [weak session] _ in
                // `MainActor.assumeIsolated` is not used here: `.main` is an `OperationQueue`,
                // whose main-thread guarantee is not a main-ACTOR one. A `Task` hop is the same
                // one-turn deferral `CaptionField` settled on, and costs nothing at this rate.
                Task { @MainActor in session?.setOwnWindows(OwnWindowReporter.current()) }
            }
        }
    }

    private func stopObservingOwnWindows() {
        for watcher in ownWindowWatchers { NotificationCenter.default.removeObserver(watcher) }
        ownWindowWatchers = []
    }

    // MARK: - scale / displayUUID

    /// The display whose mode decides `scale` for `CaptureSession.init`.
    ///
    /// **`.window` answered `CGMainDisplayID()` until 2026-09-16**, on the written grounds that a
    /// window belongs to no single display — a premise this codebase had outgrown, since
    /// `WindowCapture` carries the display containing the window's centre and `WindowTargets`
    /// already sizes the buffer with that display's scale. It does not move the drawn cursor
    /// (the scale cancels inside `CaptureViewport`; the first account of this was wrong); it put
    /// an untrue scale in the recorded `DisplayGeometry`.
    /// `docs/design/a-window-on-the-other-display.md` has the measurement, the correction, and
    /// the case still open — a window dragged between differently-scaled displays mid-recording.
    static func sizingDisplayID(for source: CaptureSource) -> CGDirectDisplayID {
        switch source {
        case .display(let display): return display.displayID
        case .window(let capture): return capture.display.displayID
        // **A region knows its display exactly**, and so, it turns out, does a window — a region
        // dragged out on a secondary panel with a different backing scale gets the right one,
        // and now so does a window sitting on it.
        case .region(let capture): return capture.display.displayID
        }
    }

    /// `CGDisplayMode.pixelWidth / .width` — native pixels over points for the mode in use, which
    /// is `DisplayGeometry.scale`'s definition. Falls back to `2` when the display cannot be read.
    static func scale(forDisplay displayID: CGDirectDisplayID) -> Double {
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
