import AVFoundation
import SwiftUI

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
///
/// Each section is its own view and reads only what it draws — see
/// `docs/design/2026-10-24-splitting-the-menu-bar-panel.md`.
struct MenuBarRecorderPanel: View {
    let coordinator: RecordingCoordinator
    /// Which card the pointer is over, for the header's mark to look at. An object rather than a
    /// value so that only the header, which reads it, redraws as the pointer moves.
    @State private var glance = PanelGlance()

    var body: some View {
        VStack(alignment: .leading, spacing: Space.regular) {
            MenuBarHeader(coordinator: coordinator, glance: glance)
            if coordinator.isRecording {
                MenuBarRecordingControls(coordinator: coordinator)
            } else {
                MenuBarTargets(coordinator: coordinator, glance: glance)
                // **The take's rows, always shown.** There is no mode to hide them behind any more:
                // they set what Record records, and Screenshot, beside it, takes none of them. The
                // frame rate is set once and lives in Settings, beside the countdown's own entry.
                MenuBarMicrophoneRow(coordinator: coordinator)
                MenuBarCameraRow(camera: coordinator.camera)
                MenuBarCountdownRow(preferences: coordinator.preferences)
                MenuBarActions(coordinator: coordinator)
            }
            hotkeyWarning
            failureNote
            Divider()
            MenuBarFooter(coordinator: coordinator)
        }
        .padding(Space.roomy)
        .frame(width: 292)
        // **On the panel, not on a row.** These were modifiers of the microphone row, which is
        // built for a take and not for a screenshot — so a phone plugged in with Screenshot
        // selected was not refreshed. The panel is the one thing present whenever it is open.
        .task { coordinator.refreshMicrophones(); coordinator.camera.refresh(); coordinator.refreshMobileScreens() }
        // **Plugged in while the panel is open, and it is in the list.** The `.task` above only
        // runs when the panel appears, so a camera or an interface connected while a person was
        // looking at the device rows would not be there until they closed the panel and opened it
        // again — and the natural reading of a device missing from a list is that the app cannot
        // see it.
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in
            coordinator.refreshMicrophones(); coordinator.camera.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in
            coordinator.refreshMicrophones(); coordinator.camera.refresh()
        }
    }

    /// Whatever went wrong, said here.
    ///
    /// **`statusText` used to be written where only the editor could see it.** So a camera that
    /// refused to start — because another application already had it, which is exactly what a
    /// video call is — produced a recording with no camera in it and not one word about why.
    /// The recorder is started from this panel and this panel is where a person comes back to.
    ///
    /// Only problems, as the sentence's writer classed them — see `RecordingCoordinator.Status`
    /// for why the panel no longer decides by reading the words.
    @ViewBuilder private var failureNote: some View {
        if coordinator.status.isProblem, !coordinator.status.text.isEmpty {
            Label { Text(verbatim: coordinator.status.text) } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
                .font(.system(size: 10))
                .foregroundStyle(Signal.paused)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Shown only when the registration failed — usually another application holding the same
    /// combination. Silence there would leave a person pressing a key that does nothing.
    @ViewBuilder private var hotkeyWarning: some View {
        if GlobalHotkeyStatus.shared.failed {
            Label("\(GlobalHotkey.toggleRecordingSpelling) is taken by another app, so it will not stop a recording from outside Soredemo.",
                  systemImage: "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundStyle(Signal.paused)
        }
    }
}

/// The mark, the name, and while recording the elapsed time.
///
/// **Its own view because the time keeps changing.** Read in the panel's body, every change of
/// `coordinator.elapsed` re-ran the whole panel's body for the length of the recording.
private struct MenuBarHeader: View {
    let coordinator: RecordingCoordinator
    let glance: PanelGlance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Space.snug) {
            // **The template mark, not the coloured one**: a coloured mark would be the loudest
            // thing beside a label, drawing the eye to the app's own name. Drawn rather than
            // baked so its eye can look toward the card under the pointer — the mark saying what
            // the next press will capture. Under Reduce Motion the eye moves without travelling.
            DarumaView(pose: .looking(at: glance.target), style: .template)
                .frame(width: 18, height: 18)
                .foregroundStyle(.primary)
                .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.7),
                           value: glance.target)
            Text("Soredemo")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            if coordinator.isRecording {
                Text(verbatim: ElapsedTime.text(coordinator.elapsed))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
