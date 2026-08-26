import AVFoundation
import AppKit
import Capture
import CoreGraphics
import SwiftUI

/// What sits in the menu bar.
///
/// **This is the app.** A recorder is used from inside whatever is being demonstrated: the
/// moment a person opens a window to press Record, the thing they wanted to record is behind it.
/// So there is no window at launch and no Dock icon — the editor is opened by a recording
/// finishing, which is the only moment there is anything to edit.
///
/// **The icon carries the state, and nothing else does — it used to carry the clock too.**
/// A menu bar with the notch and a dozen extras in it has no room to spare, and an item that
/// grows when recording starts is an item macOS hides at the moment it matters most: measured on
/// a full menu bar, adding the timer text made this disappear entirely the instant a recording
/// began. So the width is constant. The elapsed time lives on the floating bar, which is on the
/// recorded screen the whole time anyway, and in the panel.
///
/// Idle it is the logomark as a template image, so the system tints it for a light or dark menu
/// bar. Recording it is a filled record symbol, and paused a filled pause — different SHAPES
/// rather than different colours, because a template image has no colour of its own.
struct MenuBarRecorderLabel: View {
    let coordinator: RecordingCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if coordinator.isRecording {
                Image(systemName: coordinator.isPaused
                      ? "pause.circle.fill" : "record.circle.fill")
            } else {
                // **No `.frame` here, and that is the fix.** Twice I sized this with a frame
                // and twice it changed nothing a person could see: SwiftUI scales a menu bar
                // image to the bar's height whatever frame it is given, so the only thing that
                // controls how big the mark LOOKS is the proportion of its canvas the ink
                // occupies. `scripts/make-menubar-logomark.swift` bakes that in — the ink is
                // 62% of a square canvas and the rest is transparent.
                //
                // Measured, which is how the frame theory died: an SF Symbol in the menu bar has
                // about 14pt of ink, and this mark inside a 13pt frame had 12pt — already
                // shorter, and still reading as larger, because a solid brushstroke carries far
                // more visual weight than line art at the same height.
                Image("LogomarkTemplate")
                    .renderingMode(.template)
            }
        }
        // **The label is where this lives because the label is always in the scene graph.** The
        // panel's body only runs while the popover is open, so an editor opened from there would
        // wait for a person to click the menu bar item after their recording finished.
        //
        // This is also what an `NSStatusItem` could not give back. Owning the item bought
        // position control and cost this: measured on the shipped app, nothing built the label,
        // so finishing a recording opened nothing and a first run never showed the permission
        // page. Both had been dead since the scene was removed.
        .onChange(of: coordinator.mediaURL) {
            guard coordinator.mediaURL != nil else { return }
            EditorWindowPresence.openEditor { openWindow(id: $0) }
        }
        // **First run opens the permission page.** Not every run: a person who has granted
        // everything is greeted by nothing, which is the correct amount of greeting. The check
        // is on what is MISSING rather than on a "have we shown this" flag, so someone who
        // revokes a permission later gets the page again instead of a silent failure.
        .task {
            guard !CapturePermissions.blockingFailures().isEmpty else { return }
            EditorWindowPresence.willOpen()
            openWindow(id: WindowID.permissions)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// The panel behind the menu bar item.
///
/// **The system's own popover chrome, not a card inside it.** An earlier version drew a rounded
/// glass surface with its own border and shadow inside the popover, which the system had already
/// drawn a rounded translucent surface for — two sets of corners, an inset that read as a
/// mistake. Every native menu bar popover on this machine, Now Playing included, lets the window
/// be the surface and fills it edge to edge.
///
/// **Semantic colours, so it follows the system.** The floating recording bar is pinned to dark
/// because it sits over a person's screen; this sits in the menu bar, where a dark panel in a
/// light system is the thing that looks wrong.
struct MenuBarRecorderPanel: View {
    let coordinator: RecordingCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Space.regular) {
            header
            if coordinator.isRecording {
                recordingControls
            } else {
                targets
                microphoneRow
                cameraRow
                frameRateRow
                countdownRow
                startButton
            }
            hotkeyWarning
            failureNote
            Divider()
            footer
        }
        .padding(Space.roomy)
        .frame(width: 292)
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: Space.snug) {
            // **The template mark, not the coloured one.** `Logomark` is the brand's purple,
            // which is right on a launch screen and wrong beside a label: in the header it read
            // as the one coloured thing in a panel of white text, drawing the eye to the app's
            // own name — the least useful thing on the panel. Template rendering hands it the
            // same ink the title is set in, and follows a light system the way the title does.
            Image("LogomarkTemplate")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .foregroundStyle(.primary)
            Text("Soredemo")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            if coordinator.isRecording {
                Text(RecordingBarView.elapsedText(coordinator.elapsed))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The two ways to start. **Cards rather than a segmented control**, because they are not two
    /// settings of one thing — each opens the system picker narrowed to its own kind of target,
    /// and pressing one is the act of starting.
    @ViewBuilder private var targets: some View {
        HStack(spacing: Space.snug) {
            TargetCard(icon: "display", title: "Screen", detail: "A whole display",
                       isBusy: coordinator.pendingMode == .displaysOnly) {
                coordinator.beginRecording(.displaysOnly)
            }
            TargetCard(icon: "macwindow", title: "Window", detail: "Point at it",
                       isBusy: coordinator.pendingMode == .windowsOnly) {
                coordinator.beginWindowRecordingByPointing()
            }
            // **The third thing a recorder has to be able to point at.** A display capture of a
            // demo living in a small panel spends most of its pixels on desktop, and a window
            // capture cannot do it at all when the subject is part of a window rather than all
            // of it. a Rust recorder, an Electron recorder and an Electron recorder all offer this.
            TargetCard(icon: "rectangle.dashed", title: "Area", detail: "Drag it out",
                       isBusy: coordinator.pendingMode == .region) {
                coordinator.beginRegionRecording()
            }
        }
    }

    /// Which microphone, including none.
    ///
    /// **System audio is not offered beside it, and the asymmetry is deliberate.** a Swift recorder's
    /// toolbar has both toggles. Ours records system audio always, because turning it off leaves
    /// an `AVAssetWriter` input that nothing ever feeds — the exact condition that produced the
    /// export deadlock this project spent two commits on. `closeAudioTracksNothingIsFeeding`
    /// recovers from it after ninety frames, so a toggle would work and would cost a second and
    /// a half of every recording to a control almost nobody wants. It goes in when the writer
    /// can be told up front that a track will not exist.
    @ViewBuilder private var microphoneRow: some View {
        Menu {
            Button("No microphone") { coordinator.microphone = .off }
            Divider()
            Button("System default") { coordinator.microphone = .systemDefault }
            ForEach(coordinator.availableMicrophones, id: \.self) { source in
                Button(source.displayName) { coordinator.microphone = source }
            }
            Divider()
            // **Voice Isolation is the noise removal, done by the system, on the input.** It is
            // a mode macOS applies before any app sees a sample, so it is in the recording
            // rather than something an export has to undo. No app can set it — see
            // `CameraEffects` — so this opens the panel that can.
            Button("Microphone Modes\u{2026}") { CameraEffects.showMicrophoneModes() }
        } label: {
            HStack(spacing: Space.snug) {
                Image(systemName: coordinator.microphone == .off ? "mic.slash" : "mic.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(coordinator.microphone == .off ? .secondary : .primary)
                    .frame(width: 14)
                // **Looked up here, because the name crosses a module boundary as a `String`.**
                // `MicrophoneSource.displayName` is in the package, which has no strings table
                // and should not have one — a capture module that knew about the app's UI
                // language would be the wrong shape. "System default" and "No microphone" are
                // keys in this app's table; a real device's name is not, and falls through to
                // itself, which is right — the system already localised it.
                Text(LocalizedStringKey(coordinator.microphone.displayName))
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: Space.tight)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Space.regular)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: Glass.controlRadius, style: .continuous)
                .fill(.quaternary.opacity(0.5)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .task { coordinator.refreshMicrophones(); coordinator.refreshCameras() }
        // **Plugged in while the panel is open, and it is in the list.** The `.task` above only
        // runs when the panel appears, so a camera or an interface connected while a person was
        // looking at these two rows would not be there until they closed the panel and opened it
        // again — and the natural reading of a device missing from a list is that the app cannot
        // see it. a Swift recorder's toolbar watches the same two notifications for the same reason.
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in
            coordinator.refreshMicrophones(); coordinator.refreshCameras()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in
            coordinator.refreshMicrophones(); coordinator.refreshCameras()
        }
    }

    /// Which camera, including none.
    ///
    /// **Hidden entirely when this machine has no camera or has refused access** — an option
    /// that can only fail is worse than no option, and the permission is asked for when a camera
    /// is chosen rather than at launch, because a recorder that asks for the camera on first run
    /// before anyone has asked for one is a recorder people distrust.
    @ViewBuilder private var cameraRow: some View {
        if !coordinator.availableCameras.isEmpty {
            Menu {
                Button("No camera") { coordinator.camera = .off }
                Divider()
                ForEach(coordinator.availableCameras, id: \.self) { source in
                    Button(source.displayName) { coordinator.chooseCamera(source) }
                }
                Divider()
                // **The quality is the camera's, read from the device.** It was capped at 1080p
                // by a decision this app had no business making — a camera grows when the stage
                // zooms, it can be made large, and a ProRes 4444 export of a large overlay wants
                // every pixel the source has.
                Menu("Camera Quality") {
                    ForEach(CameraRecorder.qualities(for: coordinator.camera), id: \.self) { q in
                        Button {
                            coordinator.cameraQuality = q
                        } label: {
                            Text(LocalizedStringKey(q.displayName))
                        }
                    }
                }
                Divider()
                Button("Video Effects\u{2026}") { CameraEffects.showVideoEffects() }
            } label: {
                HStack(spacing: Space.snug) {
                    Image(systemName: coordinator.camera == .off ? "video.slash" : "video.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(coordinator.camera == .off ? .secondary : .primary)
                        .frame(width: 14)
                    Text(LocalizedStringKey(coordinator.camera.displayName))
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer(minLength: Space.tight)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, Space.regular)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: Glass.controlRadius, style: .continuous)
                    .fill(.quaternary.opacity(0.5)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)

            // **What the system is applying, said where the camera is chosen.** Portrait and
            // Studio Light are switched on in Control Center and stay on for every app, so a
            // person who turned one on for a call months ago has it in this recording too. The
            // row that picks the camera is where that belongs; the effects panel itself is one
            // press away in the menu above.
            // **What the chosen camera will actually record at.** Every camera used to be
            // recorded at 480p whatever it could do, so an external one was throwing away most
            // of itself and nothing said so. Shown rather than made a control: the camera is
            // drawn a few hundred pixels across in the finished video, so the ceiling is 1080p
            // and 4K would be disk and encode time for detail the export discards.
            if case .device = coordinator.camera,
               let size = CameraRecorder.recordingSize(of: coordinator.camera,
                                                       quality: coordinator.cameraQuality) {
                Text(size)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if !coordinator.activeCameraEffects.isEmpty {
                Button { CameraEffects.showVideoEffects() } label: {
                    HStack(spacing: Space.tight) {
                        Image(systemName: "sparkles").font(.system(size: 9))
                        Text(coordinator.activeCameraEffects
                            .map { NSLocalizedString($0.rawValue, comment: "") }
                            .joined(separator: " \u{00B7} "))
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            // **Said before the recording, not after it.** A camera another application already
            // holds is what a video call in a browser looks like from here, and the failure
            // used to arrive as a missing camera track in a finished recording.
            if coordinator.cameraIsBusy {
                Label("Another app is using this camera. The screen will still record.",
                      systemImage: "video.badge.ellipsis")
                    .font(.system(size: 10))
                    .foregroundStyle(Signal.paused)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if coordinator.cameraWasRefused {
                Button { coordinator.openCameraSettings() } label: {
                    Label("This Mac has not allowed Soredemo the camera. Open Settings\u{2026}",
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(Signal.paused)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// How often the capture may deliver a frame.
    ///
    /// **Only rates this display can produce.** `minimumFrameInterval` is a ceiling and the
    /// panel is the floor, so offering 120 on a 60 Hz display would be offering a control that
    /// changes no observable thing.
    /// **How wide the popup on a settings row is.** One number for both rows, because the two
    /// were built differently and did not line up: the countdown's was a `labelsHidden` picker
    /// pinned to 76 points, and the frame rate's was a `Picker(label:)` whose popup sized itself
    /// to its widest entry. Two shapes for one kind of row is how they came to be different
    /// lengths, and matching the numbers would have left the shapes free to drift again.
    ///
    /// Wide enough for the longest value either row offers — `120 fps` — so neither truncates.
    private static let settingRowPickerWidth: Double = 92

    /// One settings row: an icon, a label, and a popup on the right. Both rows go through this,
    /// so the padding, the height, the corner radius and the popup width cannot disagree.
    @ViewBuilder private func settingRow<Value: Hashable>(
        icon: String, iconIsMuted: Bool = false, title: LocalizedStringKey,
        selection: Binding<Value>, @ViewBuilder options: () -> some View
    ) -> some View {
        HStack(spacing: Space.snug) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(iconIsMuted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .frame(width: 14)
            Text(title).font(.system(size: 12))
            Spacer(minLength: Space.tight)
            Picker("", selection: selection) { options() }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: Self.settingRowPickerWidth)
        }
        .padding(.horizontal, Space.regular)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: Glass.controlRadius, style: .continuous)
            .fill(.quaternary.opacity(0.5)))
    }

    @ViewBuilder private var frameRateRow: some View {
        settingRow(icon: "speedometer", title: "Frame rate",
                   selection: Binding(get: { coordinator.frameRate },
                                      set: { coordinator.frameRate = $0 })) {
            ForEach(CaptureFrameRate.available(forDisplayRates: Self.displayRefreshRates),
                    id: \.self) {
                Text($0.displayName).tag($0)
            }
        }
    }

    /// What every attached display can refresh at.
    ///
    /// **Every display, not the main one, and the rates themselves rather than a ceiling.** This
    /// asked `CGMainDisplayID()` for one number, so somebody with a 60 Hz built-in as their main
    /// display and a 144 Hz panel beside it was offered 30 and 60 — for a recording of the
    /// 144 Hz panel. And a ceiling could only ever pick from a fixed ladder, so that 144 Hz panel
    /// was offered 120 and a sixth of its frames were discarded to match a number in an enum.
    ///
    /// The choice is made before the target is picked, so the panel cannot know which display it
    /// will be; every display's rate is the honest set. Choosing 144 and then recording the
    /// 60 Hz one costs nothing — `minimumFrameInterval` is a ceiling and the panel is the floor,
    /// so the recording is 60 either way.
    ///
    /// **A display reporting 0 is dropped, not treated as still.** `CGDisplayMode.refreshRate`
    /// answers 0 for several built-in panels rather than their actual rate, and an empty list is
    /// what `available(forDisplayRates:)` reads as "this system said nothing".
    static var displayRefreshRates: [Double] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        // `unsafe`: a C function filling a buffer this call owns. Safe — `ids` is sized by the
        // count the first call reported and outlives the second, and the values are only read
        // when the call reports success.
        guard unsafe CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.compactMap { CGDisplayCopyDisplayMode($0)?.refreshRate }.filter { $0 > 0 }
    }

    /// How long to wait before the capture starts.
    @ViewBuilder private var countdownRow: some View {
        settingRow(icon: coordinator.countdownSeconds == 0 ? "timer.square" : "timer",
                   // Muted when it is off, so the row says so before the value is read.
                   iconIsMuted: coordinator.countdownSeconds == 0,
                   title: "Countdown",
                   selection: Binding(get: { coordinator.countdownSeconds },
                                      set: { coordinator.countdownSeconds = $0 })) {
            ForEach(RecordingCoordinator.countdownChoices, id: \.self) { value in
                Text(value == 0 ? "Off" : "\(value)s").tag(value)
            }
        }
    }

    @ViewBuilder private var startButton: some View {
        Button {
            coordinator.beginRecording(.displaysAndWindows)
        } label: {
            HStack(spacing: Space.snug) {
                Image(systemName: "record.circle.fill").font(.system(size: 13))
                Text("Start Recording").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(Self.toggleShortcut)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Space.regular)
            .frame(height: 34)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: Glass.controlRadius, style: .continuous)
                .fill(Signal.record))
        }
        .buttonStyle(.plain)
        .help("Choose what to record")
    }

    /// While recording the panel stops offering choices: the floating bar is on the recorded
    /// screen, and a person who came up here came up here to stop.
    @ViewBuilder private var recordingControls: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            HStack(spacing: Space.snug) {
                PanelLevel(level: coordinator.microphoneLevel)
                Spacer()
                Button(coordinator.isPaused ? "Resume" : "Pause") { coordinator.togglePause() }
                    .controlSize(.small)
                Button("Stop \(Self.toggleShortcut)") { coordinator.stop() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(Signal.record)
            }
            // **Said here because this is where a person looks for it.** The stop key works
            // while another app is in front — that is the whole point of it — so the place to
            // learn it is the panel they opened wondering how to stop.
            Text("\(Self.toggleShortcut) stops the recording from any application.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    /// Whatever went wrong, said here.
    ///
    /// **`statusText` used to be written where only the editor could see it.** So a camera that
    /// refused to start — because another application already had it, which is exactly what a
    /// video call is — produced a recording with no camera in it and not one word about why.
    /// The recorder is started from this panel and this panel is where a person comes back to.
    ///
    /// Only failures: the running commentary was removed from `statusText` long ago, and what is
    /// left is a report.
    @ViewBuilder private var failureNote: some View {
        if !coordinator.statusText.isEmpty, coordinator.statusText.contains("could not")
            || coordinator.statusText.contains("Could not") {
            Label(coordinator.statusText, systemImage: "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundStyle(Signal.paused)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The global shortcut, spelled the way a menu would.
    static let toggleShortcut = "\u{2318}\u{21E7}R"

    /// Shown only when the registration failed — usually another application holding the same
    /// combination. Silence there would leave a person pressing a key that does nothing.
    @ViewBuilder private var hotkeyWarning: some View {
        if GlobalHotkeyStatus.shared.failed {
            Label("\(Self.toggleShortcut) is taken by another app, so it will not stop a "
                  + "recording from outside Soredemo.",
                  systemImage: "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundStyle(Signal.paused)
        }
    }

    /// **Four links on two rows, and the gear that used to hold two of them is gone.**
    ///
    /// The measurement that put Settings and Permissions behind a gear stands — the four need
    /// 357pt of a 260pt row and SwiftUI truncated them into a jam of half-words — but it was a
    /// measurement about ONE row, and the conclusion drawn from it was the wrong one of the two
    /// available. A `Menu` inside a panel opens a system popup that AppKit positions itself: it
    /// hangs outside the panel it belongs to, overlaps the controls beneath it, and near the
    /// right edge of a display it is placed where there is room rather than where the gear is.
    /// A second row costs 18 points of a panel that had them and puts every destination in the
    /// panel, where a person can see all four without opening anything.
    /// The four places this panel can send you.
    ///
    /// **Icons, and no ellipses.** The ellipsis is the macOS convention for "this asks you
    /// something before it happens", and in a menu it is the only signal available. This is not
    /// a menu: it is a custom panel whose every other row already leads with an icon, and four
    /// rows of small grey text with three trailing dots among them read as noise rather than as
    /// a distinction. The icon says what each one is faster than the punctuation said what it
    /// would do.
    ///
    /// **Quit is bottom-right, which is the corner nothing is next to.** It used to sit beside
    /// Open Project, at the top of the group, one slip away from the row a person actually came
    /// for. Reading order puts the thing you most rarely want last.
    @ViewBuilder private var footer: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            HStack(spacing: Space.regular) {
                PanelLink(icon: "folder", title: "Open Project", shortcut: "\u{2318}O") {
                    coordinator.openProject()
                }
                Spacer()
                SettingsPanelLink()
            }
            HStack(spacing: Space.regular) {
                PanelLink(icon: "hand.raised", title: "Permissions", shortcut: "") {
                    EditorWindowPresence.willOpen()
                    openWindow(id: WindowID.permissions)
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                PanelLink(icon: "power", title: "Quit", shortcut: "\u{2318}Q") {
                    NSApp.terminate(nil)
                }
            }
        }
        .font(.system(size: 12))
    }
}

/// One of the two target choices.
private struct TargetCard: View {
    let icon: String
    // **`LocalizedStringKey`, not `String`, and that is the whole translation bug.** Every one
    // of these words was already in `zh-Hant.lproj/Localizable.strings` — "Screen" = "螢幕" has
    // been there since the file was written. SwiftUI only looks a string up when it arrives as
    // a `LocalizedStringKey`; a `String` passed through a parameter is drawn verbatim. So the
    // panel showed 開始錄製 and 倒數, which are literals in this file, beside Screen and Window,
    // which are not — and it read as a half-finished translation rather than a type mistake.
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    /// True while the system picker this card opened is up, so the card reads as the thing that
    /// is happening rather than staying inert behind a picker a person may not connect to it.
    let isBusy: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Space.tight) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(isBusy ? Signal.record : .primary)
                    .frame(height: 20)
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.regular)
            .background {
                RoundedRectangle(cornerRadius: Glass.controlRadius, style: .continuous)
                    .fill(.quaternary.opacity(isHovering || isBusy ? 0.9 : 0.5))
            }
            .overlay {
                RoundedRectangle(cornerRadius: Glass.controlRadius, style: .continuous)
                    .strokeBorder(Signal.record.opacity(isBusy ? 0.9 : 0), lineWidth: 1.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// The microphone level, in the panel. Same reading as the bar's, laid out for a row rather than
/// a strip — a person who opened the panel mid-recording is checking the same thing.
private struct PanelLevel: View {
    let level: Double?

    var body: some View {
        HStack(spacing: Space.snug) {
            Image(systemName: level == nil ? "mic.slash" : "mic.fill")
                .font(.system(size: 12))
                .foregroundStyle(level == nil ? .secondary : .primary)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(Signal.level)
                        .frame(width: proxy.size.width * (level ?? 0))
                }
            }
            .frame(width: 54, height: 4)
        }
        .animation(.linear(duration: 0.05), value: level)
    }
}

/// What every footer row looks like. Split out of `PanelLink` so the Settings row can wear the
/// same face while being a different KIND of control — see `SettingsPanelLink`.
private struct PanelLinkLabel: View {
    let icon: String
    /// `LocalizedStringKey` for `TargetCard`'s reason — this is why Open Project and Quit
    /// stayed English while everything written as a literal in this file was translated.
    let title: LocalizedStringKey
    let shortcut: String
    let isHovering: Bool

    var body: some View {
        HStack(spacing: Space.tight + 2) {
            // The same 14-point column the settings rows above use, so the four footer icons
            // and the two row icons form one vertical line rather than four.
            Image(systemName: icon).font(.system(size: 11)).frame(width: 14)
            Text(title)
            // **Only when there is one.** An empty `Text` still takes the stack's spacing, which
            // left Permissions sitting a few points off the alignment its neighbours kept.
            if !shortcut.isEmpty { Text(shortcut).foregroundStyle(.tertiary) }
        }
        .foregroundStyle(isHovering ? .primary : .secondary)
        .contentShape(Rectangle())
    }
}

/// A footer action: a label and its shortcut, with no button chrome — the row is a list of
/// places to go, and three bordered buttons would compete with the red one above them.
private struct PanelLink: View {
    let icon: String
    let title: LocalizedStringKey
    let shortcut: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            PanelLinkLabel(icon: icon, title: title, shortcut: shortcut, isHovering: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// The Settings row, which is a `SettingsLink` rather than a `PanelLink` with an action.
///
/// **`NSApp.sendAction(Selector("showSettingsWindow:"))` is what this was, and it is broken.**
/// That private selector has been the way to open a `Settings` scene since it existed; since
/// macOS 14 it logs `Please use SettingsLink for opening the Settings scene` at runtime —
/// observed on this app — and is documented as no longer working. `SettingsLink` is the
/// sanctioned replacement and is what `../opensource/…/a Swift recorder` uses for the same job.
///
/// **The app is activated alongside it, and that is not decoration.** `SettingsLink` assumes
/// the app is already active with a window-management context; a `MenuBarExtra` app has neither
/// — it runs as an accessory, has no Dock icon, and is not "active" in the sense AppKit means.
/// The `simultaneousGesture` runs on press, before the link's own action, so the assumption
/// holds by the time it fires. The Permissions row beside this one has always activated for the
/// same reason, written out because it opens its window itself.
///
/// **Not verified at runtime by the author of this change**, and worth saying: the menu bar
/// panel is not reachable by accessibility — measured 2026-08-25, which is why an earlier bug
/// in this file had to be found by reading — so there is no way to drive this row from a test
/// or a probe. What is established is that the old call was logging a warning that says it does
/// not work, and that this is the API Apple names in that warning.
private struct SettingsPanelLink: View {
    @State private var isHovering = false

    var body: some View {
        SettingsLink {
            PanelLinkLabel(icon: "gearshape", title: "Settings", shortcut: "\u{2318},",
                           isHovering: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .simultaneousGesture(TapGesture().onEnded {
            NSApp.activate(ignoringOtherApps: true)
        })
    }
}
