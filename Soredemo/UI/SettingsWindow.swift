import AppKit
import Capture
import SwiftUI

/// The preferences this app keeps between recordings.
///
/// **Every reference recorder has one and this had none**, which meant every choice a person
/// made lived for exactly as long as the window it was made in. ScreenKite's has twelve panes;
/// this has three, because three is how many groups of settings actually exist here — a sidebar
/// of empty rooms is worse than a short list.
///
/// **Only what is genuinely a PREFERENCE.** A recording's look, its captions and its cuts belong
/// to that recording and are saved with it; what belongs here is what a person decides once and
/// expects to hold: which microphone, whether to count down, what an export defaults to.
struct SettingsWindow: View {
    @State private var section = Section.recording
    @State private var languageChanged = false
    let coordinator: RecordingCoordinator

    enum Section: String, CaseIterable, Hashable {
        case recording, export, privacy

        var title: String {
            switch self {
            case .recording: "Recording"
            case .export: "Export"
            case .privacy: "Privacy"
            }
        }

        var icon: String {
            switch self {
            case .recording: "record.circle"
            case .export: "square.and.arrow.up"
            case .privacy: "hand.raised"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, id: \.self, selection: $section) { item in
                Label(item.title, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            Form {
                switch section {
                case .recording: recording
                case .export: export
                case .privacy: privacy
                }
            }
            .formStyle(.grouped)
            .navigationTitle(section.title)
        }
        .frame(width: 640, height: 460)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }

    @ViewBuilder private var recording: some View {
        SwiftUI.Section("Language") {
            Picker("Interface", selection: Binding(
                get: { AppLanguage.stored ?? .system },
                set: { AppLanguage.choose($0); languageChanged = true })) {
                ForEach(AppLanguage.available, id: \.self) { language in
                    Text(language.displayName).tag(language)
                }
            }
            if languageChanged {
                // Said rather than pretended: `AppleLanguages` is read once when the process
                // starts, so a change cannot reach views that are already built.
                Label("Takes effect the next time Soredemo starts.", systemImage: "arrow.clockwise")
                    .font(Type.detail).foregroundStyle(Signal.paused)
            }
        }
        SwiftUI.Section("Before recording") {
            Picker("Countdown", selection: Binding(
                get: { coordinator.countdownSeconds },
                set: { coordinator.countdownSeconds = $0 })) {
                ForEach(RecordingCoordinator.countdownChoices, id: \.self) { value in
                    Text(value == 0 ? "Off" : "\(value) seconds").tag(value)
                }
            }
            Text("The pause before capture starts. It is also what hides a camera's first "
                 + "second, which is a dark frame settling.")
                .font(Type.detail).foregroundStyle(.secondary)
        }
        SwiftUI.Section("Sources") {
            Picker("Microphone", selection: Binding(
                get: { coordinator.microphone },
                set: { coordinator.microphone = $0 })) {
                Text("No microphone").tag(MicrophoneSource.off)
                Text("System default").tag(MicrophoneSource.systemDefault)
                ForEach(coordinator.availableMicrophones, id: \.self) { source in
                    Text(source.displayName).tag(source)
                }
            }
            Picker("Camera", selection: Binding(
                get: { coordinator.camera },
                set: { coordinator.camera = $0 })) {
                Text("No camera").tag(CameraSource.off)
                ForEach(coordinator.availableCameras, id: \.self) { source in
                    Text(source.displayName).tag(source)
                }
            }
            // **System audio has no toggle, and the reason is recorded rather than hidden.**
            LabeledContent("System audio", value: "Always recorded")
                .foregroundStyle(.secondary)
            Text("Turning system audio off would leave a writer input nothing ever feeds, which "
                 + "costs a second and a half of every recording to recover from. It goes in "
                 + "when the writer can be told up front that a track will not exist.")
                .font(Type.detail).foregroundStyle(.secondary)
        }
        .task {
            coordinator.refreshMicrophones()
            coordinator.refreshCameras()
        }
    }

    @ViewBuilder private var export: some View {
        SwiftUI.Section("Shortcut") {
            LabeledContent("Start and stop", value: MenuBarRecorderPanel.toggleShortcut)
            Text("Works while another application is in front, which is when a recording is "
                 + "stopped.")
                .font(Type.detail).foregroundStyle(.secondary)
        }
        SwiftUI.Section("Defaults") {
            // Export settings live on the recording being exported, not here: a GIF's frame rate
            // is a property of that export. What is here is the statement of where they are, so
            // a person looking for them in the obvious place is told the non-obvious answer.
            Text("An export's shape, size and GIF settings belong to the recording being "
                 + "exported and are in the editor's Project tab, saved with the project.")
                .font(Type.detail).foregroundStyle(.secondary)
        }
    }

    /// **What this app reads, and what it refuses to.**
    ///
    /// The ScreenKite thread has a user asking, in as many words, whether an unknown app
    /// recording every action and gesture is safe. It is a fair question and this project has an
    /// unusually good answer that was written only in the source: the APIs that read a
    /// keystroke's text cannot be NAMED anywhere in this app, enforced by a test, and every
    /// string field in the observation log has to carry a verdict about why it is allowed. A
    /// guarantee nobody can see is a guarantee nobody is reassured by.
    @ViewBuilder private var privacy: some View {
        SwiftUI.Section("What is recorded") {
            PrivacyPoint(icon: "keyboard",
                         title: "Never what you type",
                         detail: "The APIs that turn a key event into text are banned from this "
                         + "app's source by a test — not filtered at runtime, unnameable. Key "
                         + "codes and modifier flags are what a shortcut is matched on.")
            PrivacyPoint(icon: "cursorarrow.rays",
                         title: "Where you clicked, and what shape it was",
                         detail: "The element's position and role, so a zoom can frame the "
                         + "button rather than the pointer. Never its contents.")
            PrivacyPoint(icon: "macwindow",
                         title: "No window titles",
                         detail: "The window picker shows an application's name and size. A "
                         + "title carries whatever is open in it.")
            PrivacyPoint(icon: "wifi.slash",
                         title: "Nothing leaves this Mac",
                         detail: "Transcription runs on device. There is no account, no upload "
                         + "and no telemetry.")
        }
        SwiftUI.Section {
            LabeledContent("Recordings are written to",
                           value: "a scratch folder until you save them")
                .font(Type.detail)
        }
    }
}

private struct PrivacyPoint: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: Space.regular) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Theme.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(Type.detail).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}
