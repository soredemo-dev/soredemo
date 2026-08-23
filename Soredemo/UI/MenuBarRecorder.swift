import AppKit
import Capture
import CoreGraphics
import SwiftUI

/// The behaviours that have to outlive the panel.
///
/// **This is a view with no picture, and that is the point.** It used to be
/// `MenuBarRecorderLabel` — the `MenuBarExtra`'s label, which drew the mark AND carried the two
/// `openWindow` calls below, because a label is in the scene graph for as long as the app is.
/// When the item became an `NSStatusItem` the mark moved to `StatusItemController` and this file
/// kept a view nobody built: measured on the shipped app, finishing a recording opened nothing
/// at all and a first run never showed the permission page. Both had been dead since the day the
/// scene was removed.
///
/// `openWindow` is a SwiftUI environment action and no AppKit object holds one, so the view has
/// to exist somewhere. It is hosted at zero size inside the status item's button, which is the
/// one thing in this app that is alive from launch to quit.
struct MenuBarWindowBridge: View {
    let coordinator: RecordingCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            // **The editor opens when there is something in it, and nowhere else.** A recorder
            // that stops and shows you nothing has, as far as anyone watching can tell, lost the
            // recording.
            .onChange(of: coordinator.mediaURL) {
                guard coordinator.mediaURL != nil else { return }
                EditorWindowPresence.willOpen()
                openWindow(id: SoredemoApp.editorWindowID)
                NSApp.activate(ignoringOtherApps: true)
            }
            // **First run opens the permission page.** Not every run: a person who has granted
            // everything is greeted by nothing, which is the correct amount of greeting. The
            // check is on what is MISSING rather than on a "have we shown this" flag, so someone
            // who revokes a permission later gets the page again instead of a silent failure.
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
                frameRateRow
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
            settingsMenu
        }
    }

    /// Settings and Permissions, behind one glyph.
    ///
    /// **Because four links do not fit on one row.** The footer used to hold two — Open Project
    /// and Quit — and grew to four as Settings and then the permission page were built. Measured
    /// at the panel's own width: the four need 357pt of a 260pt row, so SwiftUI truncated them
    /// into a jam of half-words. These two are the pair a person opens once and forgets, so they
    /// are the pair that goes behind a gear.
    @ViewBuilder private var settingsMenu: some View {
        Menu {
            Button("Settings\u{2026}") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            Button("Permissions\u{2026}") {
                EditorWindowPresence.willOpen()
                openWindow(id: SoredemoApp.permissionsWindowID)
                NSApp.activate(ignoringOtherApps: true)
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 16)
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

    /// How often the capture may deliver a frame.
    ///
    /// **Only rates this display can produce.** `minimumFrameInterval` is a ceiling and the
    /// panel is the floor, so offering 120 on a 60 Hz display would be offering a control that
    /// changes no observable thing.
    @ViewBuilder private var frameRateRow: some View {
        Picker(selection: Binding(get: { coordinator.frameRate },
                                  set: { coordinator.frameRate = $0 })) {
            ForEach(CaptureFrameRate.available(upTo: Self.mainDisplayRefreshRate), id: \.self) {
                Text($0.displayName).tag($0)
            }
        } label: {
            HStack(spacing: Space.snug) {
                Image(systemName: "speedometer").font(.system(size: 12)).frame(width: 14)
                Text("Frame rate").font(.system(size: 12))
            }
        }
        .pickerStyle(.menu)
        .padding(.horizontal, Space.regular)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: Glass.controlRadius, style: .continuous)
            .fill(.quaternary.opacity(0.5)))
    }

    /// The main display's refresh rate.
    ///
    /// **Zero means unknown, not zero.** `CGDisplayMode.refreshRate` reports 0 for several
    /// built-in panels rather than their actual rate, and treating that as a ceiling would leave
    /// a MacBook offering 30 fps and nothing else. Unknown offers everything: the ceiling simply
    /// does not bind, and the panel remains the floor it always was.
    static var mainDisplayRefreshRate: Double {
        let reported = CGDisplayCopyDisplayMode(CGMainDisplayID())?.refreshRate ?? 0
        return reported > 0 ? reported : .greatestFiniteMagnitude
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
