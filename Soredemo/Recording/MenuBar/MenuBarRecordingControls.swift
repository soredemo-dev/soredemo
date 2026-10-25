import Capture
import SwiftUI

/// The panel's two acts, as Apple's own capture toolbar has them: the target is chosen above,
/// and these say what to do with it. **Record is the system's prominent button in the ink accent,
/// its mark in the label's own ink** — no red before anything records: the owner found the red dot
/// on an idle panel too loud (2026-10-25), and red then means "recording" and nothing else.
/// Screenshot is the system's bordered button, and a chosen device cannot be
/// photographed: disabled, with its reason, rather than hidden.
/// `docs/design/2026-10-25-the-panel-and-a-daruma-that-answers.md`, "Building option two".
struct MenuBarActions: View {
    let coordinator: RecordingCoordinator

    var body: some View {
        let deviceChosen = coordinator.selectedDevice != nil
        HStack(spacing: Space.snug) {
            Button { coordinator.start(.take) } label: {
                Label("Record", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .help("Record what is chosen (\(GlobalHotkey.toggleRecordingSpelling))")
            Button { coordinator.start(.picture) } label: {
                Label("Screenshot", systemImage: "camera.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(deviceChosen)
            // Two `Text`s, not a ternary of literals: that would type as `String` and skip the table.
            .help(deviceChosen ? Text("A connected device is recorded, not photographed")
                               : Text("Screenshot"))
        }
        .controlSize(.extraLarge)
        .tint(Theme.accent)
    }
}

/// While recording the panel stops offering choices: the floating bar is on the recorded
/// screen, and a person who came up here came up here to stop.
struct MenuBarRecordingControls: View {
    let coordinator: RecordingCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            HStack(spacing: Space.snug) {
                PanelLevel(guards: coordinator.guards)
                Spacer()
                Button { coordinator.togglePause() } label: {
                    coordinator.isPaused ? Text("Resume") : Text("Pause")
                }
                    .controlSize(.small)
                Button("Stop \(GlobalHotkey.toggleRecordingSpelling)") { coordinator.stop() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(Signal.record)
            }
            // **Said here because this is where a person looks for it.** The stop key works
            // while another app is in front — that is the whole point of it — so the place to
            // learn it is the panel they opened wondering how to stop.
            Text("\(GlobalHotkey.toggleRecordingSpelling) stops the recording from any application.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

/// The microphone level, in the panel. Same reading as the bar's, laid out for a row rather than
/// a strip — a person who opened the panel mid-recording is checking the same thing.
///
/// **Handed the guards, not the level**, so the level is read here: read by the controls'
/// body, every new reading re-ran the Pause and Stop buttons with it.
private struct PanelLevel: View {
    let guards: TakeGuards
    private var level: Double? { guards.microphoneLevel }

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
