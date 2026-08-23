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
    @State private var recordingCoordinator = RecordingCoordinator()
    /// The editor window's identity, so `openWindow(id:)` can reach it from the menu bar item.
    static let editorWindowID = "editor" 
    /// The one thing an app delegate is needed for: asking before the app quits over an edit
    /// nobody saved. See `UnsavedWorkGuard`.
    @NSApplicationDelegateAdaptor(SoredemoAppDelegate.self) private var appDelegate
    /// `--dump-permissions` prints the permission dump and exits here, before
    /// `body` is evaluated and therefore before any window appears. Launch it
    /// with `open -a Soredemo.app --args --dump-permissions`, not the raw
    /// executable: TCC attributes a direct `fork`/`exec` to the responsible
    /// parent process, so the grants reported would not be this bundle's.
    init() {
        if CommandLine.arguments.dropFirst().contains("--dump-permissions") {
            print(CapturePermissions.dumpText(
                build: BuildProvenance.builtAt, commit: BuildProvenance.commit))
            exit(0)
        }
    }

    var body: some Scene {
        // **The menu bar item is the primary surface.** A recorder is used from inside whatever
        // is being demonstrated, and the moment a person opens this app's window to press
        // Record, the thing they wanted to record is behind it. See `MenuBarRecorderPanel`.
        MenuBarExtra {
            MenuBarRecorderPanel(coordinator: recordingCoordinator)
        } label: {
            MenuBarRecorderLabel(coordinator: recordingCoordinator)
        }
        // `.window`, not the default menu: the contents are controls, not commands.
        .menuBarExtraStyle(.window)

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
        Window("Soredemo", id: Self.editorWindowID) {
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
        .defaultLaunchBehavior(.suppressed)
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
