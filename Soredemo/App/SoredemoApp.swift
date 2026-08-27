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
    /// **Declared without a default, and set in `init`.** Written as
    /// `= RecordingCoordinator()` it built TWO: the stored-property default runs before the
    /// `init` body, which then replaced it with a second. Measured by logging from the
    /// coordinator — every line appeared twice, one per instance — and each one read the
    /// persisted defaults and scanned the machine's cameras and microphones for a copy of the
    /// app nothing was pointing at.
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
        // **The menu bar item, and it is the whole app.** A recorder is used from inside what
        // is being demonstrated, and the moment a person opens this app's window to press
        // Record, the thing they wanted to record is behind it. See `MenuBarRecorderPanel`.
        //
        // **`MenuBarExtra`, after an `NSStatusItem` was tried and taken back out.** Owning the
        // item bought `autosaveName` and a seeded position — real answers to an item macOS hides
        // on a full menu bar — and cost the two things that make this feel like a menu bar app:
        // the system's own window chrome behind the panel, and a label that is in the scene
        // graph for as long as the app is. Both were rebuilt by hand and neither came back
        // right. The scene is the design; the position problem goes somewhere it does not cost
        // the design to solve.
        MenuBarExtra {
            MenuBarRecorderPanel(coordinator: recordingCoordinator)
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

        // **The editor, and it does not exist until there is something to edit.**
        // `.defaultLaunchBehavior(.suppressed)` is what stops SwiftUI opening it at launch: a
        // recorder that greets you with an empty editor window is a recorder whose first act is
        // to cover the screen you wanted to record. `MenuBarRecorderLabel` opens it when a
        // recording finishes or a project is opened, which are the only two times it has
        // anything in it.
        //
        // `Window`, not `WindowGroup`: one recording is open at a time, so a second window would
        // be a second set of models over the same `StageCompositor` statics — which are
        // process-global because AVFoundation owns compositor instances, and would therefore
        // disagree between the two windows.
        // **A default size, because a `Window` scene's default is the content's own.** An
        // editor is a preview, a timeline and an inspector at once and none of those three is
        // what SwiftUI sizes to; the result was a window whose timeline had no length. This is
        // the size before `sizeGenerouslyOnFirstOpen` gets a screen to measure — a floor for
        // the first frame rather than the answer, which is why it is not a share of anything.
        // **`WindowGroup`, not `Window`, and it is the green button that forced it.**
        //
        // Measured 2026-08-27 by logging the editor window's own `collectionBehavior` from
        // inside a running build, at attach and three seconds later:
        //
        //     Window       131330 = auxiliary | fullScreenAuxiliary | moveToActiveSpace
        //     WindowGroup   65666 = primary   | fullScreenPrimary   | moveToActiveSpace
        //
        // SwiftUI classifies a `Window` scene as AUXILIARY, and an auxiliary window gets
        // `fullScreenAuxiliary` — "may join another app's full-screen space" — rather than
        // `fullScreenPrimary`. The green button reads the latter, so it offered tiling and
        // nothing else. `WindowConfigurator` inserted `fullScreenPrimary` and SwiftUI stripped
        // it again within three seconds, which is why every earlier attempt looked like it had
        // worked and had not.
        //
        // Both Swift reference projects land on a primary window for their editor:
        // `../opensource/…/a Swift recorder` uses `WindowGroup`, and
        // `../opensource/…/a native editor` manages its own `NSWindowController`. Neither
        // uses a `Window` scene.
        //
        // **The single-window rule the old comment gave is kept, by hand.** It said: one
        // recording is open at a time, so a second window would be a second set of models over
        // the same `StageCompositor` statics — which are process-global because AVFoundation
        // owns compositor instances, and would disagree between two windows. That is still
        // true. `WindowGroup` permits a second window rather than requiring one, and
        // `EditorWindowPresence.openEditor` refuses to make one: it brings the existing window
        // forward instead. a native editor's `HomeWindowController.shared` is the same arrangement
        // with AppKit's own vocabulary.
        WindowGroup("Soredemo", id: WindowID.editor) {
            ContentView(coordinator: recordingCoordinator)
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
        // **No `.defaultSize`, and that is not an omission — it disables full screen.**
        //
        // Measured 2026-08-26 in an isolated SwiftUI `Window` scene, reading the window's own
        // `collectionBehavior` back at 0.2 s, 1 s and 3 s:
        //
        //     with    .defaultSize  →  66050 = primary | fullScreenNone | moveToActiveSpace
        //     without .defaultSize  →  65666 = primary | fullScreenPrimary | moveToActiveSpace
        //
        // `.fullScreenNone` is the flag that says a window cannot go full screen, and it is
        // what makes the green button show a "+" with a tiling menu and no Full Screen row.
        // SwiftUI sets it for a scene with a default size and re-asserts it after every update,
        // so `WindowConfigurator`'s `insert(.fullScreenPrimary)` never survived — the two are
        // mutually exclusive and `fullScreenNone` wins. Removing it first does not help either;
        // SwiftUI puts it back.
        //
        // This modifier was added on the same day, to stop the editor opening at its content's
        // size. It was the wrong tool for that: `sizeGenerouslyOnFirstOpen` already gives the
        // editor most of the screen on first open, and unlike a default size it does not tell
        // AppKit the window is fixed.
        //
        // `.contentMinSize` stays and is measured innocent — the run with it and without a
        // default size is the one that reports `fullScreenPrimary=true`. The floor comes from
        // the content, the ceiling from nothing, so the editor resizes freely.
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
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = ImportedRecording.readableTypes
                    panel.allowsMultipleSelection = false
                    panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url {
                        recordingCoordinator.openVideo(at: url)
                    }
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
