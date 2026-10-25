import Capture
import SwiftUI

/// The panel's one primary action.
struct MenuBarStartButton: View {
    let coordinator: RecordingCoordinator

    var body: some View {
        Button {
            coordinator.beginRecording(.displaysAndWindows)
        } label: {
            HStack(spacing: Space.snug) {
                Image(systemName: "record.circle.fill").font(.system(size: 13))
                Text("Start Recording").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(verbatim: GlobalHotkey.toggleRecordingSpelling)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Ink.onAccent.opacity(0.8))
            }
            // **`onAccent`, not white**: the accent is ink — sumi in the light theme, washi in the
            // dark — so the label is the paper it is not
            // (`PaletteTests.aLabelReadsOnTheAccentAndTheAccentOnThePanel`).
            .foregroundStyle(Theme.Ink.onAccent)
            .padding(.horizontal, Space.regular)
            .frame(height: 34)
            .frame(maxWidth: .infinity)
            // **The app's own colour, not red.** On macOS red means destructive, and a large red
            // button reading "Start Recording" looks like one — the record dot beside the label
            // already carries the meaning. Red stays where it belongs: the state while a
            // recording is running, and the control that ends it.
            .background(RoundedRectangle(cornerRadius: Glass.controlRadius, style: .continuous)
                .fill(Theme.accent))
        }
        .buttonStyle(.plain)
        .help("Choose what to record")
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
