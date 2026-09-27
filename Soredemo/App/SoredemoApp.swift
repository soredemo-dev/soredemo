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
            SoredemoAppDelegate.installNotchSurface = {
                NotchSurfacePresenter.shared.install(coordinator: coordinator)
            }
        }
    }
    /// `--dump-permissions` prints the permission dump and exits here, before
    /// `body` is evaluated and therefore before any window appears. Launch it
    /// with `open -a Soredemo.app --args --dump-permissions`, not the raw
    /// executable: TCC attributes a direct `fork`/`exec` to the responsible
    /// parent process, so the grants reported would not be this bundle's.
    @Environment(\.openWindow) private var openWindow

    /// Acts on the flags that need the app to be up.
    ///
    /// **`--open-project <path>`, beside the picker flags and for the same reason.**
    /// `openProject()` goes through an `NSOpenPanel`, so without this the entire editor —
    /// every window behaviour, every full-screen transition, every toolbar — is unreachable
    /// from anything but a person with a mouse. Two defects in three days were exactly there,
    /// and both were reported by one rather than found by anything.
    ///
    /// **The window is opened first.** The menu item this stands in for is only reachable when
    /// an editor is already up; at launch there is none, and a project loaded into a window
    /// that does not exist is a flag that silently does nothing — which is what the first
    /// version did, and what the first UI test caught.
    ///
    /// A verification flag, not a test hook: a person can use it too.
    @MainActor private func handleLaunchArguments() {
        let arguments = Array(CommandLine.arguments.dropFirst())

        // **`--show-countdown <seconds>`, beside the other verification flags and for their
        // reason.** The countdown is otherwise reachable only by starting a real recording, so
        // looking at it means capturing the screen, hiding the desktop and writing a file — and
        // nobody does that to check a ring. Exits with 3 when ⎋ cancelled it, so a script can
        // tell the two endings apart. A person can use it too: it is how you see what the three
        // seconds will look like before you rely on them.
        // **`--list-windows`, a verification flag for the path a reported crash lands on.**
        // `Fatal error: Not enough bits to represent the passed value` was logged twice,
        // immediately after `SCShareableContent` returned, with no crash report to read because a
        // Swift trap under the debugger stops there rather than writing one. This drives
        // `WindowTargets.onScreen()` — what "Window · point at it" calls — from a binary the
        // screen-recording grant already covers, so the trap can be caught with a backtrace
        // instead of guessed at.
        if arguments.contains("--list-windows") {
            Task { @MainActor in
                let targets = await WindowTargets.onScreen()
                for target in targets {
                    print("\(target.id)\t\(target.applicationName)\t\(target.frame)")
                }
                print("windows: \(targets.count)")
                exit(0)
            }
            return
        }

        if let index = arguments.firstIndex(of: "--show-countdown"),
           index + 1 < arguments.count, let seconds = Int(arguments[index + 1]) {
            Task { @MainActor in
                let finished = await CountdownPresenter.shared.run(
                    seconds: seconds, subject: String(localized: "Whole display"))
                print(finished ? "countdown finished" : "countdown cancelled")
                exit(finished ? 0 : 3)
            }
            return
        }

        // **`--show-recording-bar <seconds>`: the bar on its own, with no recording.**
        //
        // The same shape `--show-countdown` has, and for the same reason. The bar could not be
        // dragged for as long as it has existed and nothing caught it, because the only way to
        // see it was to start a recording and the only way to test it was by hand. It prints
        // the window's frame when it appears and again when the time is up, so a drag — by a
        // hand or by synthesised events — is a number rather than an impression.
        if let index = arguments.firstIndex(of: "--show-recording-bar"),
           index + 1 < arguments.count, let seconds = Double(arguments[index + 1]) {
            Task { @MainActor in
                RecordingBarPresenter.shared.show(
                    coordinator: recordingCoordinator,
                    // `--bar-collapsed`: the state where the bar is one control and nothing
                    // else, which is where "it cannot be dragged once collapsed" hid — the
                    // control took the mouse and the drag surface behind it never saw one.
                    startCollapsed: arguments.contains("--bar-collapsed"))
                let before = RecordingBarPresenter.shared.barFrame
                print("bar \(before.map { "\($0)" } ?? "none")")
                try? await Task.sleep(for: .seconds(seconds))
                let after = RecordingBarPresenter.shared.barFrame
                print("bar \(after.map { "\($0)" } ?? "none")")
                let hits = RecordingBarPresenter.shared.hitCounts
                print("hit tests: \(hits.pill) on the bar, \(hits.halo) in the shadow halo")
                print("drag changes seen: \(RecordingBarPresenter.shared.dragMoves)")
                print(before == after ? "the bar did not move" : "the bar moved")
                exit(before == after ? 3 : 0)
            }
            return
        }

        guard let index = arguments.firstIndex(of: "--open-project"),
              index + 1 < arguments.count else { return }
        let packageURL = URL(fileURLWithPath: arguments[index + 1])
        EditorWindowPresence.openEditor { openWindow(id: $0) }
        recordingCoordinator.openProject(at: packageURL)

        // **`--report-window-state <path>`: what the window actually became, from AppKit.**
        //
        // The first version of this check drove the app with XCUITest and read the window's
        // frame out of the accessibility tree. That is unreliable by construction here: a
        // window that enters full screen moves to its OWN Space, and the element stops being
        // queryable while it does — the same test passed, then reported "never readable", then
        // failed inside its own failure message. An oracle that is sometimes right is not one.
        //
        // `styleMask.contains(.fullScreen)` is AppKit's own answer to the same question, read
        // directly instead of inferred from geometry. The app is not marking its own homework:
        // it is not asked whether it MEANT to be full screen, it is asked what the window
        // system says it is.
        guard let reportIndex = arguments.firstIndex(of: "--report-window-state"),
              reportIndex + 1 < arguments.count else { return }
        let destination = URL(fileURLWithPath: arguments[reportIndex + 1])
        Task { @MainActor in
            // **Longer than `FullScreenEntry`'s own budget, and that is the constraint.** The
            // transition is animated and cannot be awaited, so this waits — but a wait SHORTER
            // than the app's retry budget reads a window that is still trying and reports it as
            // a refusal. Measured 2026-09-16: with the budget at six seconds and this at five,
            // one run in three reported `fullScreen=false` against a window whose frame was
            // still the un-configured default. Four seconds of headroom past the budget.
            let budget = Double(FullScreenEntry.attempts) * FullScreenEntry.interval
            try? await Task.sleep(for: .seconds(budget + 4))
            let window = NSApp.windows.first {
                $0.identifier?.rawValue.contains(WindowID.editor) == true && $0.isVisible
            }
            let screen = window?.screen ?? NSScreen.main
            let report = """
                fullScreen=\(window?.styleMask.contains(.fullScreen) == true)
                frame=\(window.map { "\($0.frame)" } ?? "none")
                screen=\(screen.map { "\($0.frame)" } ?? "none")
                safeAreaTop=\(screen?.safeAreaInsets.top ?? -1)
                fullScreenAsks=\(FullScreenEntry.lastAttempt.asks)
                fullScreenStopped=\(FullScreenEntry.lastAttempt.stopped.rawValue)

                """
            try? report.write(to: destination, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

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
            // **The launch flags are handled HERE, and that was a defect the first UI test
            // found on its first run.** `--open-project` was attached to the editor scene's
            // `.task`, and that scene is `.defaultLaunchBehavior(.suppressed)`: at launch the
            // window does not exist, so the task never ran and the flag did nothing. The menu
            // bar label is the one view this app always has — an accessory app is its status
            // item — so it is the only place a launch-time task can be attached.
            MenuBarRecorderLabel(coordinator: recordingCoordinator)
                .task { handleLaunchArguments() }
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
                    let arguments = Array(CommandLine.arguments.dropFirst())
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
            CommandGroup(after: .appInfo) {
                // Asked, never automatic from here: see `UpdateChecker`.
                Button("Check for Updates…") { Task { await UpdateChecker.check(userInitiated: true) } }
            }
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
                Button {
                    recordingCoordinator.toggleRecording()
                } label: {
                    recordingCoordinator.isRecording ? Text("Stop Recording") : Text("Record…")
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
