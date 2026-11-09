import AppKit
import Capture
import SwiftUI

/// The preferences this app keeps between recordings.
///
/// **This had none**, which meant every choice a person made lived for exactly as long as the
/// window it was made in. A settings window can grow to a dozen panes;
/// this has three, because three is how many groups of settings actually exist here — a sidebar
/// of empty rooms is worse than a short list.
///
/// **Only what is genuinely a PREFERENCE.** A recording's look, its captions and its cuts belong
/// to that recording and are saved with it; what belongs here is what a person decides once and
/// expects to hold: which microphone, whether to count down, what an export defaults to.
struct SettingsWindow: View {
    @Environment(\.openWindow) private var openWindow
    @State private var section = Section.recording
    @State private var languageChanged = false
    @AppStorage(Appearance.defaultsKey) private var appearance = Appearance.system
    @AppStorage(AppIconChoice.defaultsKey) private var appIcon = AppIconChoice.vermilion
    @AppStorage(DarumaColour.defaultsKey) private var darumaColour = DarumaColour.vermilion
    @AppStorage(DarumaFaceStyle.defaultsKey) private var darumaFace = DarumaFaceStyle.window
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

    /// **A `TabView`, and it was a `NavigationSplitView` that showed nothing.**
    ///
    /// The split view was the wrong container twice over. Apple's own guidance is that a
    /// `Settings` scene groups its panes with a `TabView` — the scene then supplies the centred
    /// tab bar every Mac settings window has, which is why this now looks like one instead of
    /// like a document window that happens to hold preferences. And a `NavigationSplitView`
    /// inside a `Settings` scene renders empty: the scene sizes itself to its content's ideal
    /// size, the split view has no ideal size of its own, and the `.frame` here was applied
    /// outside it rather than to either column. What a person saw was an empty window.
    ///
    /// **A fixed height, and no `.frame` on the tabs themselves.** A settings window that
    /// resizes as you switch panes is the thing the centred tab bar exists to avoid; the height
    /// is the tallest pane's, so the shorter ones have room to spare rather than the taller one
    /// scrolling.
    var body: some View {
        TabView(selection: $section) {
            pane { recording }.tabItem { Label(LocalizedStringKey(Section.recording.title),
                                               systemImage: Section.recording.icon) }
                .tag(Section.recording)
            pane { export }.tabItem { Label(LocalizedStringKey(Section.export.title),
                                            systemImage: Section.export.icon) }
                .tag(Section.export)
            pane { privacy }.tabItem { Label(LocalizedStringKey(Section.privacy.title),
                                             systemImage: Section.privacy.icon) }
                .tag(Section.privacy)
        }
        .frame(width: 560, height: 460)
        .tint(Theme.accent)
    }

    /// One pane. `Form` + `.grouped` is what gives a settings pane its inset boxes and its
    /// label column; the `ScrollView` is what stops a pane taller than the window from being
    /// cut off rather than scrolled — `.grouped` does not scroll on its own inside a fixed
    /// frame.
    @ViewBuilder private func pane(@ViewBuilder _ content: () -> some View) -> some View {
        ScrollView { Form { content() }.formStyle(.grouped) }
    }

    @ViewBuilder private var recording: some View {
        SwiftUI.Section("Appearance") {
            Picker("Theme", selection: $appearance) {
                ForEach(Appearance.allCases, id: \.self) { choice in
                    Text(LocalizedStringKey(choice.displayName)).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: appearance) { appearance.apply() }
            Picker("App icon", selection: $appIcon) {
                ForEach(AppIconChoice.allCases, id: \.self) { choice in
                    Text(LocalizedStringKey(choice.displayName)).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: appIcon) { appIcon.apply() }
            HStack(spacing: Space.regular) {
                ForEach(AppIconChoice.allCases, id: \.self) { choice in
                    Image(choice.previewName)
                        .resizable()
                        .frame(width: 56, height: 56)
                        .opacity(choice == appIcon ? 1 : 0.45)
                        .onTapGesture { appIcon = choice }
                        .accessibilityHidden(true)
                }
            }
            Text("The Dock shows it while Soredemo is open. Finder and Launchpad keep the vermilion daruma: macOS cannot change an app's own icon without breaking its signature.")
                .font(Type.detail).foregroundStyle(.secondary)
            // **The character's colour, the person's to choose** — or the theme's ink, which is
            // where it starts. The menu bar's mark is the system's ink whatever is chosen here.
            Picker("Character", selection: $darumaColour) {
                ForEach(DarumaColour.allCases, id: \.self) { choice in
                    Text(LocalizedStringKey(choice.displayName)).tag(choice)
                }
            }
            Picker("Face", selection: $darumaFace) {
                ForEach(DarumaFaceStyle.allCases, id: \.self) { choice in
                    Text(LocalizedStringKey(choice.displayName)).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            HStack(spacing: Space.regular) {
                ForEach(DarumaColour.allCases, id: \.self) { choice in
                    LivingDaruma(colour: choice, followsPointer: true, pokeable: true)
                        .frame(width: 36, height: 36)
                        .opacity(choice == darumaColour ? 1 : 0.45)
                        .onTapGesture { darumaColour = choice }
                        .accessibilityHidden(true)
                }
            }
        }
        SwiftUI.Section("Language") {
            Picker("Interface", selection: Binding(
                get: { AppLanguage.stored ?? .system },
                set: { AppLanguage.choose($0); languageChanged = true })) {
                ForEach(AppLanguage.available, id: \.self) { language in
                    Text(verbatim: language.displayName).tag(language)
                }
            }
            if languageChanged {
                // Said rather than pretended: `AppleLanguages` is read once when the process
                // starts, so a change cannot reach views that are already built.
                Label("Takes effect the next time Soredemo starts.", systemImage: "arrow.clockwise")
                    .font(Type.detail).foregroundStyle(Theme.Ink.caution)
            }
        }
        SwiftUI.Section("Controls") {
            Toggle("Controls in the notch", isOn: Binding(
                get: { NotchSurfacePresenter.isEnabled },
                set: { on in
                    UserDefaults.standard.set(on, forKey: NotchSurfacePresenter.enabledKey)
                    if on { NotchSurfacePresenter.shared.install(coordinator: coordinator) }
                    else { NotchSurfacePresenter.shared.remove() }
                }))
            Text("Point at the notch to start a recording, and see the one that is running there. Off, or on a Mac without a notch, the controls are a bar at the bottom of the screen.")
                .font(Type.detail).foregroundStyle(.secondary)
        }
        SwiftUI.Section("Before recording") {
            // **Here rather than in the panel**: set once and kept, unlike the microphone a person
            // checks before nearly every take. Only rates an attached display can produce
            // (`CaptureFrameRate.available`) — a higher one would change nothing observable.
            Picker("Frame rate", selection: Binding(
                get: { coordinator.preferences.frameRate },
                set: { coordinator.preferences.frameRate = $0 })) {
                ForEach(CaptureFrameRate.available(forDisplayRates: DisplayRefreshRates.current),
                        id: \.self) {
                    Text("\($0.rawValue) fps").tag($0)
                }
            }
            Picker("Countdown", selection: Binding(
                get: { coordinator.preferences.countdownSeconds },
                set: { coordinator.preferences.countdownSeconds = $0 })) {
                ForEach(RecordingPreferences.countdownChoices, id: \.self) { value in
                    (value == 0 ? Text("Off") : Text("\(value) seconds")).tag(value)
                }
            }
            Text("The pause before capture starts. It is also what hides a camera's first second, which is a dark frame settling.")
                .font(Type.detail).foregroundStyle(.secondary)

            Toggle("Hide desktop icons", isOn: Binding(
                get: { coordinator.preferences.hidesDesktopIcons },
                set: { coordinator.preferences.hidesDesktopIcons = $0 }))
            // **The cost is on screen, not in a header nobody reads.** This is the only setting
            // in the app that restarts another application, and somebody who has Finder windows
            // open is owed that fact before they turn it on rather than after.
            Text("Your files stay where they are — only the drawing stops. Turning this on restarts Finder, which closes any Finder windows you have open. The icons come back when the recording ends, and also if Soredemo is quit or crashes while one is running.")
                .font(Type.detail).foregroundStyle(.secondary)

            Toggle("Hide the Dock", isOn: Binding(
                get: { coordinator.preferences.hidesDock },
                set: { coordinator.preferences.hidesDock = $0 }))
            // **The contrast with the switch above it is the point.** They sit together and
            // sound alike, and one of them restarts an application while the other changes
            // nothing on the machine at all. Somebody comparing the two is owed that difference
            // here rather than after they have tried both.
            Text("Kept out of the picture, not moved. Your Dock stays where it is and still works while you record — it is simply not in the video. Nothing on your Mac is changed, so there is nothing to put back. Recordings of a single window never include the Dock anyway.")
                .font(Type.detail).foregroundStyle(.secondary)

            Toggle("Hide the menu bar", isOn: Binding(
                get: { coordinator.preferences.hidesMenuBar },
                set: { coordinator.preferences.hidesMenuBar = $0 }))
            // **What it takes with it is the reason to turn it on**, and it is not obvious from
            // the name. Somebody reading "hide the menu bar" thinks about tidiness; the clock,
            // the battery and the row of app icons are the part that ends up in a published
            // video saying more than they meant.
            Text("The clock, battery, network and every icon beside them go too. Like the Dock, nothing on your Mac changes — the menu bar is still there and still works, it just is not in the recording.")
                .font(Type.detail).foregroundStyle(.secondary)

            Toggle("Hide the desktop widgets", isOn: Binding(
                get: { coordinator.preferences.hidesDesktopWidgets },
                set: { coordinator.preferences.hidesDesktopWidgets = $0 }))
            // **What they say about somebody is the reason**, and the switch's name does not
            // say it. A widget is read as decoration until it is pointed out that the calendar
            // one lists this afternoon's meetings by name.
            Text("The weather, the calendar and the battery ring on your desktop. They can say more than they look like they do — where you are, what is in your calendar this afternoon. Like the Dock, nothing on your Mac changes and Notification Center still opens normally while you record.")
                .font(Type.detail).foregroundStyle(.secondary)

            Toggle("Hide notifications", isOn: Binding(
                get: { coordinator.preferences.hidesNotifications },
                set: { coordinator.preferences.hidesNotifications = $0 }))
            // **That you still see them is the point to make**, because "hide notifications" reads
            // as Do Not Disturb, and it is not: nothing is silenced.
            Text("Banners that arrive while you record stay out of the video — who sent a message and its first line. You still see and hear them; only the recording leaves them out. Notification Center is left out too.")
                .font(Type.detail).foregroundStyle(.secondary)
        }
        SwiftUI.Section("While editing") {
            Toggle("Play audio while dragging the playhead", isOn: Binding(
                get: { coordinator.preferences.scrubAudio },
                set: { coordinator.preferences.scrubAudio = $0 }))
            // **Off is a real answer**, which is why this is a switch rather than a constant:
            // somebody editing beside a sleeping child, or with the recording already playing
            // through a speaker, wants the drag silent.
            Text("Dragging the playhead plays the moment under it, so a sentence can be found by ear instead of by scrubbing and watching.")
                .font(Type.detail).foregroundStyle(.secondary)
        }
        SwiftUI.Section("Sources") {
            Picker("Microphone", selection: Binding(
                get: { coordinator.microphone },
                set: { coordinator.microphone = $0 })) {
                Text("No microphone").tag(MicrophoneSource.off)
                Text("System default").tag(MicrophoneSource.systemDefault)
                ForEach(coordinator.availableMicrophones, id: \.self) { source in
                    Text(LocalizedStringKey(source.displayName)).tag(source)
                }
            }
            // **Through `chooseCamera`, not straight onto the property.** This picker used to
            // assign `coordinator.camera.source` directly, which skipped the one thing that function
            // exists for: asking this Mac for the camera. A camera chosen here on a fresh
            // install was set without a TCC prompt ever being raised, and an unauthorised
            // `AVCaptureDeviceInput` does not throw — it delivers black — so the self-view and
            // the recorded camera track were both a black rectangle with nothing said.
            //
            // The selection does not move until permission comes back, which is the honest
            // reading of it: refused, the camera was not chosen.
            Picker("Camera", selection: Binding(
                get: { coordinator.camera.source },
                set: { coordinator.camera.choose($0) })) {
                Text("No camera").tag(CameraSource.off)
                ForEach(coordinator.camera.available, id: \.self) { source in
                    Text(LocalizedStringKey(source.displayName)).tag(source)
                }
            }
            // **System audio has no toggle, and the reason is recorded rather than hidden.**
            LabeledContent("System audio", value: "Always recorded")
                .foregroundStyle(.secondary)
            Text("Turning system audio off would leave a writer input nothing ever feeds, which costs a second and a half of every recording to recover from. It goes in when the writer can be told up front that a track will not exist.")
                .font(Type.detail).foregroundStyle(.secondary)
        }
        // **Locked for the length of a take, like the menu bar panel's whole source list.**
        // The panel swaps these rows for the recording controls once a take begins; this window
        // is a separate scene and kept showing them, so it was the one surface that could still
        // write `camera` while `isRecording` was true — which is exactly the case
        // `showOrHideSelfView` used to answer by returning before the hide, leaving the panel
        // reading "No camera" over a self-view that was still on screen with the indicator lit.
        // The microphone goes with it: the session already holds the one it was started with,
        // so a change here during a take could only describe a recording that is not happening.
        .disabled(coordinator.isRecording)
        .task {
            coordinator.refreshMicrophones()
            coordinator.camera.refresh()
        }
    }

    @ViewBuilder private var export: some View {
        SwiftUI.Section("Shortcut") {
            LabeledContent("Start and stop", value: GlobalHotkey.toggleRecordingSpelling)
            Text("Works while another application is in front, which is when a recording is stopped.")
                .font(Type.detail).foregroundStyle(.secondary)
        }
        SwiftUI.Section("Defaults") {
            // Export settings live on the recording being exported, not here: a GIF's frame rate
            // is a property of that export. What is here is the statement of where they are, so
            // a person looking for them in the obvious place is told the non-obvious answer —
            // and how long each lasts: `EditState` saves the shape (`outputShapeName`) and nothing
            // else of an export's, so the rest go when `EditorViewModel` does.
            Text("An export's shape, format, size and GIF settings belong to the recording being exported, under Export… in the editor. The shape is saved with the project; the rest last while that recording is open.")
                .font(Type.detail).foregroundStyle(.secondary)
        }
    }

    /// **What this app reads, and what it refuses to.**
    ///
    /// Somebody will ask, in as many words, whether an unknown app
    /// recording every action and gesture is safe. It is a fair question and this project has an
    /// unusually good answer that was written only in the source: the APIs that read a
    /// keystroke's text cannot be NAMED anywhere in this app, enforced by a test, and every
    /// string field in the observation log has to carry a verdict about why it is allowed. A
    /// guarantee nobody can see is a guarantee nobody is reassured by.
    @ViewBuilder private var privacy: some View {
        SwiftUI.Section("What is recorded") {
            PrivacyPoint(icon: "keyboard",
                         title: "Never what you type",
                         detail: "The APIs that turn a key event into text are banned from this app's source by a test — not filtered at runtime, unnameable. Key codes and modifier flags are what a shortcut is matched on.")
            PrivacyPoint(icon: "cursorarrow.rays",
                         title: "Where you clicked, and what shape it was",
                         detail: "The element's position and role, so a zoom can frame the button rather than the pointer. Never its contents.")
            PrivacyPoint(icon: "macwindow",
                         title: "No window titles",
                         detail: "The window picker shows an application's name and size. A title carries whatever is open in it.")
            PrivacyPoint(icon: "wifi.slash",
                         title: "Nothing is sent unless you ask",
                         detail: "Transcription runs on device. There is no account, no upload and no telemetry. The one request Soredemo itself can make is asking GitHub whether there is a newer version, and only when you choose to. The Agent tab sends what you type, with the recording steps it reads, through your own Claude Code or Codex to its provider under your account — only when you press Send.")
        }
        SwiftUI.Section("Updates") {
            Toggle("Check for updates when Soredemo starts", isOn: Binding(
                get: { UpdateChecker.checksAtLaunch },
                set: { UserDefaults.standard.set($0, forKey: UpdateChecker.checksAtLaunchKey) }))
            Text("Asks GitHub for the latest release — one request, with nothing about you or your recordings in it. Off, it asks only when you choose Check for Updates from the Soredemo menu.")
                .font(Type.detail).foregroundStyle(.secondary)
        }
        SwiftUI.Section {
            LabeledContent("Recordings are written to",
                           value: "a scratch folder until you save them")
                .font(Type.detail)
        }
        // **Permissions live here now, and this is where they belonged.** They were a fourth
        // item in the menu-bar footer, which fits two per row — the third made every title in
        // the row truncate to "Op…", "O…", "Set…". A permission IS a setting, and the pane it
        // belongs in is the one about what this app can see.
        //
        // Nothing is lost by moving it: the permissions page opens by itself whenever something
        // it needs is missing, checked on what is ABSENT rather than on a "have we shown this"
        // flag — so somebody who revokes one later gets the page again. This is the way in for
        // way in for looking when nothing is wrong.
        SwiftUI.Section("Permissions") {
            LabeledContent("Screen recording, microphone and camera") {
                Button("Review\u{2026}") {
                    EditorWindowPresence.willOpen()
                    openWindow(id: WindowID.permissions)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            Text("This page opens on its own whenever something Soredemo needs has not been granted, or is taken away later.")
                .font(Type.detail).foregroundStyle(.secondary)
        }
    }
}

private struct PrivacyPoint: View {
    let icon: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: Space.regular) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Theme.Ink.accent)
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
