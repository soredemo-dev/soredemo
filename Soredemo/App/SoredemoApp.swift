//
//  SoredemoApp.swift
//  Soredemo
//
//  Created by Jesse Liang on 2026/8/1.
//

import AppKit
import Geometry
@preconcurrency import ScreenCaptureKit
import SwiftUI
// Capture types that moved into `Headless` in Phase 3A-3.
// `Capture` since Phase 3A-4 — permissions, the picker, and the CG bridge.
import Capture

@main
struct SoredemoApp: App {
    /// Kept alive for the process's lifetime: `SCContentSharingPicker.add(_:)` is
    /// not documented to retain its observer, so a local picker would be freed
    /// before it could call back.
    @MainActor
    private static var retainedPicker: CaptureSourcePicker?

    /// Held here because a SwiftUI command can only attach to a `Scene`, never a
    /// `View`, so the "Open Recording…" command cannot live in `ContentView`.
    ///
    /// Declared without a default and set in `init`: written as
    /// `= RecordingCoordinator()` it built TWO — the stored-property default runs
    /// before the `init` body, which then replaced it — and each one read the
    /// persisted defaults and scanned the machine's cameras and microphones.
    @State private var recordingCoordinator: RecordingCoordinator
    /// The one thing an app delegate is needed for: asking before the app quits over an edit
    /// nobody saved. See `UnsavedWorkGuard`.
    @NSApplicationDelegateAdaptor(SoredemoAppDelegate.self) private var appDelegate

    /// Hands the global shortcut something to toggle. `init` rather than a `.task`: the delegate
    /// registers the hot key in `applicationDidFinishLaunching`, and a `.task` on a scene that
    /// opens no window at launch would not have run by then.
    private func connectGlobalHotkey() {
        let coordinator = recordingCoordinator
        SoredemoAppDelegate.toggleRecording = { coordinator.toggleRecording() }
    }

    /// **Run in `init`, before the delegate's `applicationDidFinishLaunching`.** The hot key is
    /// registered there and needs something to toggle; a `.task` on a scene would not have run
    /// yet, and with every window suppressed there may be no window scene body evaluated at all.
    init() {
        if CommandLine.arguments.dropFirst().contains("--dump-permissions") {
            print(CapturePermissions.dumpText(
                build: BuildProvenance.builtAt, commit: BuildProvenance.commit))
            exit(0)
        }
        let coordinator = RecordingCoordinator()
        _recordingCoordinator = State(initialValue: coordinator)
        MainActor.assumeIsolated {
            SoredemoAppDelegate.toggleRecording = { coordinator.toggleRecording() }
        }
    }
    /// `--dump-permissions` prints the permission dump and exits here, before
    /// `body` is evaluated and therefore before any window appears. Launch it
    /// with `open -a Soredemo.app --args --dump-permissions`, not the raw
    /// executable: TCC attributes a direct `fork`/`exec` to the responsible
    /// parent process, so the grants reported would not be this bundle's.
    var body: some Scene {
        // The menu bar item, and it is the whole app: a recorder is used from inside
        // what is being demonstrated, and the moment a person opens a window to press
        // Record, the thing they wanted to record is behind it.
        //
        // `MenuBarExtra` after an `NSStatusItem` was tried and taken back out. Owning
        // the item bought `autosaveName` and a seeded position — real answers to an
        // item macOS hides on a full menu bar — and cost the system's own window
        // chrome behind the panel and a label that stays in the scene graph. Both
        // were rebuilt by hand and neither came back right.
        MenuBarExtra {
            MenuBarRecorderPanel(coordinator: recordingCoordinator)
                // The same accent the editor uses; see the note on the editor scene. The panel
                // is where somebody spends the seconds before a recording, and a red toggle in
                // a blue interface is the first thing they see.
                .tint(Theme.accent)
        } label: {
            MenuBarRecorderLabel(coordinator: recordingCoordinator)
        }
        // `.window`, not the default menu: the contents are controls, not commands.
        .menuBarExtraStyle(.window)

        // **Preferences**, in the place macOS puts them. `Settings` rather than a `Window`, so
        // it gets ⌘, and the standard title without either being written out here.
        Settings {
            SettingsWindow(coordinator: recordingCoordinator)
        }
        // **Suppressed like the other two, because it was the only one that was not.** Measured
        // on the shipped app: once Settings had been opened even once, every launch afterwards
        // came up showing it — SwiftUI presents the one scene that has not opted out, and this
        // was it. A recorder whose whole design is "no window at launch" was greeting people
        // with a preferences pane and no obvious way back to the menu bar.
        //
        // ⌘, and the panel's gear still open it; `.suppressed` governs LAUNCH and nothing else.
        .defaultLaunchBehavior(.suppressed)
        // And nothing comes back from the last session either: every window here is opened FROM
        // the menu bar item and means nothing without the state that opened it.
        .restorationBehavior(.disabled)

        // **Permissions, opened on first run and from the menu bar afterwards.** Suppressed at
        // launch like the editor: a person who has already granted everything should not be
        // greeted by a window telling them so.
        Window("Permissions", id: WindowID.permissions) {
            PermissionsWindow()
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .windowResizability(.contentSize)

        // The editor, and it does not exist until there is something to edit.
        // `.defaultLaunchBehavior(.suppressed)` is what stops SwiftUI opening it at
        // launch: a recorder that greets you with an empty editor window is a
        // recorder whose first act is to cover the screen you wanted to record.
        // `MenuBarRecorderLabel` opens it when a recording finishes or a project is
        // opened, which are the only two times it has anything in it.
        //
        // `WindowGroup`, not `Window`, and the green button forced it: SwiftUI
        // classifies a `Window` scene as auxiliary, which cannot go full screen.
        // Measured — see `docs/design/full-screen-and-window-behaviour.md`.
        //
        // ONE recording is open at a time even so. A second window would be a second
        // set of models over the same process-global `StageCompositor` statics, and
        // the two would disagree. `WindowGroup` permits a second window rather than
        // requiring one; `EditorWindowPresence.openEditor` refuses to make one and
        // brings the existing window forward instead.
        WindowGroup("Soredemo", id: WindowID.editor) {
            ContentView(coordinator: recordingCoordinator)
                // **The app's own accent, applied once at the scene.** Without this every
                // control follows the accent colour set in System Settings, so an app whose
                // whole palette is built around one blue draws its buttons, toggles, sliders
                // and selection in whatever the person happens to have chosen — red, on the
                // machine where this was noticed. Two windows set it locally and nothing set
                // it here, which is why it looked deliberate everywhere except the editor.
                .tint(Theme.accent)
                // `SCContentSharingPicker.present()` hands off to Control
                // Center's UI and needs a running run loop to call back into,
                // so unlike `--dump-permissions` these flags cannot be handled
                // in `init()`; `.task` fires once the window is up.
                .task {
                    let arguments = CommandLine.arguments.dropFirst()
                    if arguments.contains("--present-picker") {
                        Self.presentPickerForVerification(restricted: true)
                    } else if arguments.contains("--present-picker-unrestricted") {
                        Self.presentPickerForVerification(restricted: false)
                    }
                }
        }
        // No `.defaultSize`, and that is not an omission — it sets
        // `.fullScreenNone`, which is the flag that disables full screen, and
        // SwiftUI re-asserts it after every update. `.contentMinSize` is measured
        // innocent. See `docs/design/full-screen-and-window-behaviour.md`.
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands {
            // `ProjectDocument` is an `NSDocument`, not a `FileDocument`, so
            // `DocumentGroup` cannot host it. `NSDocumentController` is stood up
            // on first use from `CFBundleDocumentTypes` in `Soredemo-Info.plist`.
            CommandGroup(after: .newItem) {
                // **`ProjectStore`, not `NSDocumentController`.** The document controller was
                // stood up for `ProjectDocument`, an `NSDocument` that nothing writes: a saved
                // project is a package the recorder's own directory becomes, and opening one
                // means putting its recording and its edits into the window that is already
                // here. Routing that through a document architecture would create a second
                // window with a second set of models and no recording in it.
                Button("Open Project…") {
                    recordingCoordinator.openProject()
                }
                .keyboardShortcut("o")
                // **A separate item, not a broader file filter on the one above.** A project and
                // a video are different things to open: one restores decisions somebody made,
                // the other starts from nothing. One panel that accepted both would have to
                // guess which had been handed to it, and the guess would be by file extension.
                Button("Open Video…") {
                    recordingCoordinator.openVideoFromPanel()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                // Human step: record a few seconds and stop; ContentView then
                // shows StageWindow once recordingCoordinator.mediaURL is set.
                Button(recordingCoordinator.isRecording ? "Stop Recording" : "Record…") {
                    recordingCoordinator.toggleRecording()
                }
                .keyboardShortcut("r")
            }
        }
    }

    /// The human verification step: `open -a Soredemo.app --args --present-picker`
    /// (or `--present-picker-unrestricted`) — `open`, not the raw executable, so
    /// the picker sees this bundle's own TCC identity. `restricted` narrows
    /// `allowedPickerModes` to `.singleWindow`/`.singleDisplay`; otherwise the
    /// SDK default is left alone. Prints the subject block, the picker mode, the
    /// raw filter and the derived `CaptureSource`, then exits after one
    /// selection, cancellation, or picker-start failure.
    @MainActor
    private static func presentPickerForVerification(restricted: Bool) {
        print(CapturePermissions.subjectBlockLines(
            build: BuildProvenance.builtAt, commit: BuildProvenance.commit)
            .joined(separator: "\n"))
        print("picker mode       : " + (restricted
            ? "restricted (.singleWindow, .singleDisplay)"
            : "unrestricted (SDK default — excludes nothing)"))
        print("──")
        let picker = CaptureSourcePicker(
            onSelect: { source in
                switch source {
                case .display(let display):
                    let sizeInPoints = PointRect(x: 0, y: 0,
                                                  width: Double(display.width), height: Double(display.height))
                    print("derived CaptureSource: .display(displayID: \(display.displayID), " +
                          "size: \(sizeInPoints))")
                case .window(let capture):
                    let window = capture.window
                    let bufferSize = (width: capture.bufferWidth, height: capture.bufferHeight)
                    let sizeInPixels = PixelRect(x: 0, y: 0,
                                                  width: Double(bufferSize.width), height: Double(bufferSize.height))
                    // The window's title is deliberately not printed:
                    // `ObservationLog`'s content rule bans another
                    // application's window titles, and stdout can be
                    // redirected to a file. `windowID` is identity, not content.
                    print("derived CaptureSource: .window(windowID: \(window.windowID), " +
                          "bufferSize: \(sizeInPixels))")
                case .region(let capture):
                    // Unreachable from the system picker, which offers displays and windows.
                    // Handled rather than defaulted, so a case added later faces this line.
                    let sizeInPoints = capture.sourceRect
                    print("derived CaptureSource: .region(on displayID: " +
                          "\(capture.display.displayID), rect: \(sizeInPoints))")
                case nil:
                    print("derived CaptureSource: nil — filter.style was not .display/.window, " +
                          "or no display was available to size a window buffer against")
                }
                exit(0)
            },
            debugFilterObserver: { filter in
                let contentInPoints = CGGeometryBridge.pointRect(from: filter.contentRect)
                print("picker filter: style=\(filter.style.rawValue) contentRect=\(contentInPoints) " +
                      "pointPixelScale=\(filter.pointPixelScale) (dimensionless — points-to-pixels ratio)")
            })
        retainedPicker = picker
        picker.present(restrictModes: restricted)
    }
}
