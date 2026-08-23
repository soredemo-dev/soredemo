import AppKit
import Capture
import SwiftUI

/// What sits in the menu bar, and the panel behind it.
///
/// **The menu bar is the right home for a screen recorder, and the window was the wrong one.**
/// A recorder is used from inside whatever is being demonstrated: the moment a person opens the
/// app's own window to press Record, the thing they wanted to record is behind it. Every
/// comparable product resolves this the same way — a Rust recorder and an Electron recorder both build a tray item, and
/// a Rust recorder's is its primary surface with the window as a secondary one.
///
/// **The icon carries the state.** Idle it is an outline; recording it is a filled dot beside the
/// elapsed time, which is how a person who switched Spaces ten minutes ago finds out they are
/// still recording. a Rust recorder, CleanShot and Screen Studio all put the clock in the menu bar for that
/// reason; a recorder whose only indicator is a floating bar is a recorder people leave running.
struct MenuBarRecorderLabel: View {
    let coordinator: RecordingCoordinator

    var body: some View {
        if coordinator.isRecording {
            HStack(spacing: 4) {
                Image(systemName: coordinator.isPaused
                      ? "pause.circle.fill" : "record.circle.fill")
                Text(RecordingBarView.elapsedText(coordinator.elapsed))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
            }
        } else {
            Image(systemName: "record.circle")
        }
    }
}

/// The panel the menu bar item opens.
///
/// **A window-style `MenuBarExtra`, not a menu.** The choices here are a target, two audio
/// toggles and a countdown — controls, not commands — and a list of menu items with checkmarks
/// would be the same information laid out as a form from 2004. a Swift recorder builds this as a
/// floating toolbar with the same content; putting it under the menu bar item is the same idea
/// with one fewer window to place.
struct MenuBarRecorderPanel: View {
    let coordinator: RecordingCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Space.regular) {
            header
            if coordinator.isRecording {
                recordingState
            } else {
                targets
                microphoneRow
                Divider().opacity(0.3)
                startButton
            }
            Divider().opacity(0.3)
            footer
        }
        .padding(Space.roomy)
        .frame(width: 300)
        .glassSurface(radius: Glass.panelRadius)
        .padding(Space.snug)
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: Space.snug) {
            Image(systemName: "record.circle.fill")
                .foregroundStyle(Signal.record)
            Text("Soredemo").font(.system(size: 14, weight: .semibold))
            Spacer()
            if coordinator.isRecording {
                Text(RecordingBarView.elapsedText(coordinator.elapsed))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .foregroundStyle(.white)
    }

    /// The two ways to start. **Cards rather than a segmented control**, because they are not two
    /// settings of one thing — each opens the system picker narrowed to its own kind of target,
    /// and pressing one is the act of starting.
    @ViewBuilder private var targets: some View {
        HStack(spacing: Space.snug) {
            TargetCard(icon: "macwindow.on.rectangle", title: "Screen",
                       detail: "A whole display",
                       isBusy: coordinator.pendingMode == .displaysOnly) {
                coordinator.beginRecording(.displaysOnly)
            }
            TargetCard(icon: "macwindow", title: "Window",
                       detail: "One app window",
                       isBusy: coordinator.pendingMode == .windowsOnly) {
                coordinator.beginRecording(.windowsOnly)
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
                    .foregroundStyle(coordinator.microphone == .off
                                     ? .white.opacity(0.45) : .white.opacity(0.9))
                Text(coordinator.microphone.displayName)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, Space.regular)
            .padding(.vertical, Space.snug)
            .background {
                RoundedRectangle(cornerRadius: Glass.controlRadius, style: .continuous)
                    .fill(.white.opacity(0.05))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .task { coordinator.refreshMicrophones() }
    }

    @ViewBuilder private var startButton: some View {
        Button {
            coordinator.beginRecording(.displaysAndWindows)
        } label: {
            HStack(spacing: Space.snug) {
                Image(systemName: "record.circle.fill")
                Text("Choose what to record").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\u{2318}\u{21E7}R")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Space.regular)
            .padding(.vertical, Space.snug + 2)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: Glass.controlRadius, style: .continuous)
                .fill(Signal.record))
        }
        .buttonStyle(.plain)
    }

    /// While recording the panel stops offering choices and becomes a second set of controls —
    /// the floating bar is on the recorded screen, and a person who came up here came up here to
    /// press Stop.
    @ViewBuilder private var recordingState: some View {
        HStack(spacing: Space.snug) {
            Button(coordinator.isPaused ? "Resume" : "Pause") { coordinator.togglePause() }
                .buttonStyle(.bordered)
            Button("Stop") { coordinator.stop() }
                .buttonStyle(.borderedProminent)
                .tint(Signal.record)
            Spacer()
        }
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: Space.regular) {
            FooterButton(icon: "folder", label: "Open Project\u{2026}") {
                coordinator.openProject()
            }
            FooterButton(icon: "macwindow.badge.plus", label: "Show Window") {
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows where window.canBecomeMain {
                    window.makeKeyAndOrderFront(nil)
                }
            }
            Spacer()
            FooterButton(icon: "power", label: "Quit Soredemo") {
                NSApp.terminate(nil)
            }
        }
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
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(isBusy ? Signal.record : .white.opacity(0.9))
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.regular)
            .background {
                RoundedRectangle(cornerRadius: Glass.controlRadius, style: .continuous)
                    .fill(.white.opacity(isBusy ? Glass.pressedOpacity
                                         : (isHovering ? Glass.hoverOpacity : 0.05)))
                    .overlay {
                        RoundedRectangle(cornerRadius: Glass.controlRadius, style: .continuous)
                            .strokeBorder(isBusy ? Signal.record.opacity(0.7)
                                          : .white.opacity(Glass.edgeOpacity), lineWidth: 1)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct FooterButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(isHovering ? 1 : 0.65))
                .frame(width: 28, height: 24)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(isHovering ? Glass.hoverOpacity : 0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}
