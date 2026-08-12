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
import Headless

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
    /// `--dump-permissions` prints the permission dump and exits here, before
    /// `body` is evaluated and therefore before any window appears. Launch it
    /// with `open -a Soredemo.app --args --dump-permissions`, not the raw
    /// executable: TCC attributes a direct `fork`/`exec` to the responsible
    /// parent process, so the grants reported would not be this bundle's.
    init() {
        if CommandLine.arguments.dropFirst().contains("--dump-permissions") {
            print(CapturePermissions.dumpText())
            exit(0)
        }
    }

    var body: some Scene {
        // The scratch window that makes a bare launch observable; document
        // windows come from `ProjectDocument.makeWindowControllers()`, which
        // produces nothing until a document is opened.
        WindowGroup {
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
        .commands {
            // `ProjectDocument` is an `NSDocument`, not a `FileDocument`, so
            // `DocumentGroup` cannot host it. `NSDocumentController` is stood up
            // on first use from `CFBundleDocumentTypes` in `Soredemo-Info.plist`.
            CommandGroup(after: .newItem) {
                Button("Open Project…") {
                    NSDocumentController.shared.openDocument(nil)
                }
                .keyboardShortcut("o")
                Divider()
                // Human step: record a few seconds and stop; ContentView then
                // shows StageWindow once recordingCoordinator.mediaURL is set.
                Button(recordingCoordinator.isRecording ? "Stop Recording" : "Open Recording…") {
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
        print(CapturePermissions.subjectBlockLines().joined(separator: "\n"))
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
                case .window(let window, let bufferSize):
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
