import AppKit
import Capture
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
        .onChange(of: coordinator.mediaURL) {
            guard coordinator.mediaURL != nil else { return }
            EditorWindowPresence.willOpen()
            openWindow(id: SoredemoApp.editorWindowID)
            NSApp.activate(ignoringOtherApps: true)
        }
        // **First run opens the permission page.** Not every run: a person who has granted
        // everything is greeted by nothing, which is the correct amount of greeting. The check
        // is on what is MISSING rather than on a "have we shown this" flag, so someone who
        // revokes a permission later gets the page again instead of a silent failure.
        .task {
            guard !CapturePermissions.blockingFailures().isEmpty else { return }
            EditorWindowPresence.willOpen()
            openWindow(id: SoredemoApp.permissionsWindowID)
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
                countdownRow
                startButton
            }
            hotkeyWarning
            Divider()
            footer
        }
        .padding(Space.roomy)
        .frame(width: 292)
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: Space.snug) {
            Image("Logomark")
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
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
        } label: {
            HStack(spacing: Space.snug) {
                Image(systemName: coordinator.microphone == .off ? "mic.slash" : "mic.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(coordinator.microphone == .off ? .secondary : .primary)
                    .frame(width: 14)
                Text(coordinator.microphone.displayName)
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
                    Button(source.displayName) {
                        Task {
                            guard await CameraRecorder.requestAccess() else {
                                coordinator.camera = .off
                                return
                            }
                            coordinator.camera = source
                        }
                    }
                }
            } label: {
                HStack(spacing: Space.snug) {
                    Image(systemName: coordinator.camera == .off ? "video.slash" : "video.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(coordinator.camera == .off ? .secondary : .primary)
                        .frame(width: 14)
                    Text(coordinator.camera.displayName)
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
        }
    }

    /// How long to wait before the capture starts.
    @ViewBuilder private var countdownRow: some View {
        HStack(spacing: Space.snug) {
            Image(systemName: coordinator.countdownSeconds == 0 ? "timer.square" : "timer")
                .font(.system(size: 12))
                .foregroundStyle(coordinator.countdownSeconds == 0 ? .secondary : .primary)
                .frame(width: 14)
            Text("Countdown").font(.system(size: 12))
            Spacer(minLength: Space.tight)
            Picker("", selection: Binding(get: { coordinator.countdownSeconds },
                                          set: { coordinator.countdownSeconds = $0 })) {
                ForEach(RecordingCoordinator.countdownChoices, id: \.self) { value in
                    Text(value == 0 ? "Off" : "\(value)s").tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 76)
        }
        .padding(.horizontal, Space.regular)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: Glass.controlRadius, style: .continuous)
            .fill(.quaternary.opacity(0.5)))
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

    @ViewBuilder private var footer: some View {
        HStack(spacing: Space.regular) {
            PanelLink(title: "Open Project\u{2026}", shortcut: "\u{2318}O") {
                coordinator.openProject()
            }
            PanelLink(title: "Permissions\u{2026}", shortcut: "") {
                EditorWindowPresence.willOpen()
                openWindow(id: SoredemoApp.permissionsWindowID)
                NSApp.activate(ignoringOtherApps: true)
            }
            Spacer()
            PanelLink(title: "Quit", shortcut: "\u{2318}Q") { NSApp.terminate(nil) }
        }
        .font(.system(size: 12))
    }
}

/// One of the two target choices.
private struct TargetCard: View {
    let icon: String
    let title: String
    let detail: String
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

/// A footer action: a label and its shortcut, with no button chrome — the row is a list of
/// places to go, and three bordered buttons would compete with the red one above them.
private struct PanelLink: View {
    let title: String
    let shortcut: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.tight + 2) {
                Text(title)
                Text(shortcut).foregroundStyle(.tertiary)
            }
            .foregroundStyle(isHovering ? .primary : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
