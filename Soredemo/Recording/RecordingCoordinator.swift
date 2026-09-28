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
    /// True once the microphone has heard NOTHING for `MicrophoneSilenceWatch.patience` — no
    /// buffers, or buffers of digital silence. Not a person being quiet; see the watch.
    private(set) var microphoneHearsNothing = false
    private var silenceWatch = MicrophoneSilenceWatch()
    /// Whether the built-in speakers will be heard by the built-in microphone. Re-read when the
    /// notch opens and when the microphone changes; see `AudioRoute`.
    private(set) var speakersReachTheMicrophone = false
    /// Chapter marks written in the take running now, shown so a person sees the press land.
    private(set) var marksThisTake = 0
    /// Seconds the "mark landed" acknowledgement has left, counted down by `tick`.
    private(set) var markAcknowledgement: Double = 0
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
            status = .problem(String(localized: "The camera could not be shown: \(String(describing: error))"))
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

    /// What this Mac has measured about the rolling clip buffer: the smallest load, in pixels per
    /// second, at which it had to be dropped. Absent on a fresh install, which is
    /// `ClipBufferFit.unmeasured`. A measurement, never a preference — nothing shows it and
    /// nobody sets it; see `ClipBufferFit` for why it is learned rather than a constant.
    static let clipBufferFitKey = "clipBufferSmallestLoadThatDidNotFit"

    /// The load the current recording started at, kept so that what the watchdog decides about
    /// it can be written back against the same number at stop.
    private var clipBufferLoad: Int?
    /// The choices offered. Zero is "off" and is a legitimate answer — a person recording a
    /// window they have already arranged is not waiting three seconds for it.
    static let countdownChoices = [0, 3, 5, 10]

    /// Whether the desktop's icons are hidden for the duration of a recording.
    ///
    /// **Off by default, and it is the cost that decides that.** Restarting Finder closes the
    /// Finder windows somebody has open, which is a real interruption to make on their behalf
    /// without being asked. A person who wants a clean desktop in their demos asks once, in
    /// Settings, and gets it every time — the same shape as the countdown.
    var hidesDesktopIcons: Bool {
        didSet { UserDefaults.standard.set(hidesDesktopIcons, forKey: Self.hidesDesktopIconsKey) }
    }
    static let hidesDesktopIconsKey = "hidesDesktopIcons"

    /// Whether the Dock is kept out of the picture for the duration of a recording.
    ///
    /// **Off by default, but not for the reason its neighbour is.** Hiding the desktop icons
    /// restarts Finder and costs somebody their open windows, so it has to be asked for. This
    /// costs nothing at all — the Dock is excluded from the capture filter and the person's own
    /// Dock never moves — and it is still off, because a recording that silently omits part of
    /// the screen is not what somebody pressing Record expects to get. See `CaptureExclusions`
    /// for the three mechanisms that were measured and rejected before this one.
    var hidesDock: Bool {
        didSet { UserDefaults.standard.set(hidesDock, forKey: Self.hidesDockKey) }
    }
    static let hidesDockKey = "hidesDock"

    /// Whether the menu bar — and the twelve small things sitting in it — are kept out of the
    /// picture for the duration of a recording.
    ///
    /// **Off by default, and this is the one where that is arguable.** A menu bar says what time
    /// it is, how much battery is left, which network somebody is on, and through its extras
    /// which applications they run: for a recording that is going to be published, that is a row
    /// of small disclosures nobody meant to make. The case for hiding it by default is real.
    ///
    /// It is still off, for the same reason the other two are: a recording that silently omits
    /// part of the screen is not what pressing Record is understood to mean, and somebody
    /// demonstrating a menu is demonstrating the menu bar. Costs nothing when off — it is one
    /// property on the capture filter, not a query and not a change to the Mac.
    var hidesMenuBar: Bool {
        didSet { UserDefaults.standard.set(hidesMenuBar, forKey: Self.hidesMenuBarKey) }
    }
    static let hidesMenuBarKey = "hidesMenuBar"

    /// Whether the desktop widgets are kept out of the picture.
    ///
    /// **Off by default, like the other three, and for the same reason**: a
    /// recording that silently omits part of the screen is not what pressing
    /// Record is understood to mean. The case for ON is the strongest of the four
    /// — the widgets say what is in somebody's calendar this afternoon, where
    /// they are and what their battery is doing, which is a row of small
    /// disclosures nobody meant to publish — and it is still not enough to
    /// decide for them.
    var hidesDesktopWidgets: Bool {
        didSet {
            UserDefaults.standard.set(hidesDesktopWidgets, forKey: Self.hidesDesktopWidgetsKey)
        }
    }
    static let hidesDesktopWidgetsKey = "hidesDesktopWidgets"

    /// Whether dragging the playhead plays the moment under it.
    ///
    /// **On by default, unlike the three recording switches above.** Those change what a
    /// recording CONTAINS, so a default that surprised somebody would be in their file. This
    /// changes only what the person editing hears, costs nothing when they are not dragging, and
    /// is the difference between finding a sentence and hunting for one.
    var scrubAudio: Bool {
        didSet { UserDefaults.standard.set(scrubAudio, forKey: Self.scrubAudioKey) }
    }
    static let scrubAudioKey = "scrubAudio"

    /// Whether the machine's own output — what the speakers are playing — is recorded.
    ///
    /// **On by default, and it has to be asked rather than assumed.** A demo of
    /// anything that makes a sound is worse without it, so on is the right
    /// default. But it used to be unconditional, which left no way to record a
    /// call, or a screen that pings, without the other side of it in the file —
    /// and muting afterwards is not the same act, because by then it is recorded.
    ///
    /// This app's own sound is already excluded (`excludesCurrentProcessAudio`),
    /// so the switch is about the rest of the machine.
    var capturesSystemAudio: Bool {
        didSet { UserDefaults.standard.set(capturesSystemAudio, forKey: Self.capturesSystemAudioKey) }
    }
    static let capturesSystemAudioKey = "capturesSystemAudio"

    // **Every preference key is `internal`, not `private`, and the reason is compatibility
    // rather than testing convenience.** A persisted key is part of what the app promises across
    // versions: rename one and every existing user's preference silently reverts to its default
    // on the next launch, with nothing to see and nothing to report. Two of the four were
    // already internal and two were private, which was inconsistency rather than design —
    // nothing outside this file named any of them. They are named now by
    // `scripts/cross-boundary-digest-probe.swift` § 17, which asserts that setting each
    // preference writes the string below, so a rename is a red check instead of a quiet reset.
    //
    // `hidesDesktopIcons` was internal from the start and still went unpinned until the Dock
    // switch was added beside it — the probe named four keys and there were five. Both are
    // pinned now.

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
        // `object(forKey:)` rather than `integer(forKey:)`: the latter answers 0 for a key that
        // has never been set, and 0 means "off" here — so a first launch would silently ship
        // with no countdown, which is the opposite of the default this chose.
        countdownSeconds = UserDefaults.standard.object(forKey: Self.countdownKey) as? Int ?? 3
        // Absent means off, which `bool(forKey:)` already answers — no `object(forKey:)` dance
        // is needed for a preference whose default is the same as its zero value.
        hidesDesktopIcons = UserDefaults.standard.bool(forKey: Self.hidesDesktopIconsKey)
        hidesDock = UserDefaults.standard.bool(forKey: Self.hidesDockKey)
        hidesMenuBar = UserDefaults.standard.bool(forKey: Self.hidesMenuBarKey)
        hidesDesktopWidgets = UserDefaults.standard.bool(forKey: Self.hidesDesktopWidgetsKey)
        // **Defaults to ON, so `bool(forKey:)`'s zero is not the answer.** A key never written
        // answers `false`, which for a switch that should start on is the same silent defect
        // `countdownSeconds` documents.
        scrubAudio = UserDefaults.standard.object(forKey: Self.scrubAudioKey) as? Bool ?? true
        // `object(forKey:)` rather than `bool(forKey:)` for the same reason as every
        // switch above: `bool` reads a missing key as `false`, which would turn this
        // off for everybody who has ever run the app rather than defaulting it on.
        capturesSystemAudio = UserDefaults.standard
            .object(forKey: Self.capturesSystemAudioKey) as? Bool ?? true
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
            // The camera file, if the project has one. Named by convention beside the master,
            // as the observation log is — a package that carries one is self-describing.
            let camera = packageURL.appending(path: ProjectStore.mediaDirectory,
                                              directoryHint: .isDirectory)
                .appending(path: "camera-00.mov")
            cameraURL = FileManager.default.fileExists(atPath: camera.path) ? camera : nil
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

    /// A chapter can be marked in a screen take that is running and not paused. A phone take has
    /// no observation log to hold one.
    var canMarkChapter: Bool { isRecording && !isPaused && session != nil }
    /// Whether this take is one marks can be written into at all — a screen take, paused or not.
    var takeCanHoldMarks: Bool { isRecording && session != nil }

    /// Marks a chapter at this moment of the take. See `ChapterMark` and
    /// `docs/design/2026-09-28-notch-marks-and-audio-warnings.md`.
    func markChapter() {
        guard canMarkChapter, let session else { return }
        switch session.markChapter() {
        case .written:
            marksThisTake += 1
            markAcknowledgement = Self.markAcknowledgementSeconds
        case .noSegmentOpen:
            status = .report(String(localized: "No chapter was marked: the recording is between segments."))
        case .notWritten(let reason):
            status = .problem(String(localized: "The chapter mark could not be written: \(reason)"))
        }
    }

    static let markAcknowledgementSeconds = 1.5

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
                    // The clock did not tick while paused, and a pause is not silence.
                    silenceWatch.reset()
                    microphoneHearsNothing = false
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
        elapsed += interval
        markAcknowledgement = max(0, markAcknowledgement - interval)
        // Smoothed toward the instantaneous value: `latestRMS` is the RMS of one buffer, and a
        // meter drawn straight from it flickers at the buffer rate. Rising fast and falling slow
        // is what every level meter does, because a peak a person missed is worse than a decay
        // they can see.
        // `.off` reads as no meter rather than as a silent one: a full-height empty track is
        // what "not hearing you" looks like, and that is not what a person who turned the
        // microphone off should be shown.
        guard microphone != .off else {
            microphoneLevel = nil
            microphoneHearsNothing = false
            return
        }
        // **Before the level's guard, not after it.** A microphone that never delivered has no
        // reading at all, and that is the loudest case of hearing nothing.
        let accounting = session?.diagnostics.microphoneAccounting
        if let accounting {
            microphoneHearsNothing = silenceWatch.observe(delivered: accounting.delivered,
                                                          latestRMS: accounting.latestRMS,
                                                          over: interval)
        }
        let reading = accounting?.latestRMS
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
        let scale = Self.scale(forDisplay: Self.sizingDisplayID(for: source))
        // `Self.displayIdentity(for:)`, not `displayUUID(for:)`: `AppSourceAllowListTests`'
        // ambient scan bans the substring "UUID(".
        let displayUUID = Self.displayIdentity(for: source)

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
                                      frameRate: frameRate.rawValue)
        clipBufferLoad = load
        let learnedFit = ClipBufferFit(smallestLoadThatDidNotFit:
            UserDefaults.standard.object(forKey: Self.clipBufferFitKey) as? Int)

        let newSession = CaptureSession(source: source, scale: scale, displayUUID: displayUUID,
                                        mediaSink: newSink, epoch: Minting.bootEpoch(),
                                        pointerShapeReader: SystemCursorShape.reader(),
                                        pointerHotspotReader: SystemCursorShape.hotspotReader(),
                                        microphone: microphone,
                                        capturesSystemAudio: capturesSystemAudio,
                                        frameRate: frameRate,
                                        // Passed as the person's ANSWER, not as a resolved list:
                                        // the session looks the Dock up per segment, because a
                                        // window object taken now would be stale by the time a
                                        // second segment opens. See `CaptureExclusions`.
                                        exclusions: CaptureExclusions(
                                            hidesDock: hidesDock,
                                            hidesMenuBar: hidesMenuBar,
                                            hidesDesktopWidgets: hidesDesktopWidgets),
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
                status = .problem(String(localized: "The camera could not start: \(String(describing: error)). Recording the screen only."))
            }
        }

        // **Hidden before the countdown, not after it.** Finder takes a moment to come back
        // and redraw, and a desktop whose icons vanish during the first second of the take is
        // worse than one that never hid them. Counting down over an already-clean desktop also
        // lets the person SEE that it worked before anything is recorded.
        if hidesDesktopIcons { DesktopIcons.hide() }

        // **Counted before the session starts, not after.** A countdown that ran while the
        // capture was already recording would put itself in the first three seconds of the file.
        // **Cancellable, and the cancel has to undo what starting already did.** The desktop
        // icons are hidden before the count so a person can see that it worked; walking away
        // from the recording without putting them back would leave the machine changed by
        // something that never happened.
        guard await CountdownPresenter.shared.run(seconds: countdownSeconds,
                                                  subject: source.countdownSubject) else {
            if hidesDesktopIcons { DesktopIcons.restore() }
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
        do {
            try await newSession.start()
            isRecording = true
            isPaused = false
            elapsed = 0
            marksThisTake = 0
            markAcknowledgement = 0
            silenceWatch.reset()
            microphoneHearsNothing = false
            pendingMode = nil
            // Held only while the take runs — see `GlobalHotkey.markChapterKeyCode`. A refusal is
            // not reported: the notch's button does the same thing, and the stop key's own
            // refusal is the one a person must hear about.
            _ = GlobalHotkey.shared.register(keyCode: GlobalHotkey.markChapterKeyCode,
                                             modifiers: GlobalHotkey.markChapterModifiers) {
                [weak self] in self?.markChapter()
            }
            // **Shown from here, not from a view.** It used to be presented by `ContentView`'s
            // `.onChange`, which worked only while an editor window happened to be open — and
            // once the window stopped opening at launch, `ContentView` was never built, so a
            // recording started from the menu bar had no controls at all. The bar belongs to the
            // recording, and the recording is here.
            showRecordingControls()
            status = .report(String(localized: "Recording\u{2026} choose \u{201C}Stop Recording\u{201D} (\u{2318}R) when done."))
        } catch {
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
        GlobalHotkey.shared.unregister(keyCode: GlobalHotkey.markChapterKeyCode,
                                       modifiers: GlobalHotkey.markChapterModifiers)
        isRecording = false
        isPaused = false
        microphoneLevel = nil
        microphoneHearsNothing = false
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
