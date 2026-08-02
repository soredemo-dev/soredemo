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

@main
struct SoredemoApp: App {
    /// Kept alive for the process's lifetime — `SCContentSharingPicker.add(_:)`
    /// is not documented to retain its observer, and a locally-scoped
    /// `CaptureSourcePicker` would be freed the instant `presentPickerForVerification()`
    /// returns, before the picker could ever call back.
    @MainActor
    private static var retainedPicker: CaptureSourcePicker?
    /// Task 6's repeatable permission check, and the only place it can live.
    ///
    /// `scripts/cross-boundary-digest-probe.swift` cannot answer this: it is
    /// `swiftc`-compiled to a bare executable with no bundle identity, and
    /// TCC attributes a permission request to the *responsible process* —
    /// walked up the parent chain to whatever launched the probe — not to
    /// the probe itself. Measured: run the probe from a shell, and it
    /// reports the shell's grants.
    ///
    /// `init()` runs before `body` is ever evaluated, and therefore before
    /// AppKit's run loop puts a window on screen — the smallest early-exit
    /// point `App` offers. `--dump-permissions` prints and calls `exit(0)`
    /// here rather than doing anything in `body`, so a dump run never shows
    /// so much as a flash of a window.
    ///
    /// **Invocation matters, and being inside `Soredemo.app` is not
    /// sufficient by itself — measured, not assumed.** Executing
    /// `Soredemo.app/Contents/MacOS/Soredemo --dump-permissions` directly
    /// from a shell (`fork`/`exec`, bypassing LaunchServices) reported all
    /// four permissions `.granted` on this machine, on a bundle that has
    /// never appeared in any of the four System Settings panes — the same
    /// symptom the bare probe had, with a correct `bundle identifier` in the
    /// subject block, because `Bundle.main.bundleIdentifier` reads the
    /// process's own `Info.plist`, not who TCC's responsibility subsystem
    /// attributes it to; those are two different questions and only the
    /// second one decides what the four values below mean. Launched instead
    /// through LaunchServices —
    ///
    ///     open -W -n -a Soredemo.app --stdout <path> --args --dump-permissions
    ///
    /// — the same build, same bundle identifier, same pid-shaped process,
    /// reported the permissions this bundle identity has actually been
    /// asked about (verified against a `never appears in any pane` baseline
    /// reported independently). **Use `open`, not the raw executable path,
    /// for this dump specifically** — the opposite of what an earlier
    /// version of this comment said, corrected after running both and
    /// comparing, not from documentation. The subject block still matters:
    /// it is what makes the `open` vs. direct-exec difference *visible* in
    /// the dump's own output (same bundle identifier and `inside a .app:
    /// yes` either way; only the four values move), rather than something
    /// that has to be independently known to distrust a direct-exec run.
    init() {
        if CommandLine.arguments.dropFirst().contains("--dump-permissions") {
            print(CapturePermissions.dumpText())
            exit(0)
        }
    }

    var body: some Scene {
        // Kept deliberately: `repo-skeleton`'s completion criterion is an app
        // that **launches to a window**, and document windows come from
        // `ProjectDocument.makeWindowControllers()`, which produces nothing
        // until a document is opened. This is the scratch window that makes a
        // bare launch observable; `app-shell` replaces it.
        WindowGroup {
            ContentView()
                // `--present-picker` / `--present-picker-unrestricted`: Task 7's
                // human verification step. `SCContentSharingPicker.present()`
                // hands off to Control Center's own UI, which needs a running
                // app with an active run loop to call back into — unlike
                // `--dump-permissions`, this cannot exit from `init()` before
                // `body` ever runs. `.task` fires once the window (and the run
                // loop pumping it) is actually up.
                //
                // Two flags, not one, so the *same binary* can be presented
                // once with `allowedPickerModes` restricted and once with it
                // left at the SDK's own default — see
                // `presentPickerForVerification(restricted:)` for why "the
                // Applications option did not appear" is otherwise ambiguous
                // between three different causes.
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
            // `ProjectDocument` is an `NSDocument`, not a SwiftUI
            // `FileDocument`, so `DocumentGroup` cannot host it (design doc F3,
            // F4). Opening therefore goes through `NSDocumentController`, which
            // AppKit stands up on first use from `CFBundleDocumentTypes` in
            // `Soredemo-Info.plist` — the same declaration that registers the
            // `.soredemo` package type with LaunchServices.
            CommandGroup(after: .newItem) {
                Button("Open Project…") {
                    NSDocumentController.shared.openDocument(nil)
                }
                .keyboardShortcut("o")
            }
        }
    }

    /// Task 7's human verification step, run with:
    ///
    ///     open -W -n -a Soredemo.app --stdout <path> --args --present-picker
    ///     open -W -n -a Soredemo.app --stdout <path> --args --present-picker-unrestricted
    ///
    /// **`open`, not the raw executable path** — Task 6's finding applies
    /// unchanged: a direct `fork`/`exec` does not carry this bundle's own
    /// TCC identity, and the picker needs Screen Recording granted to
    /// `video.soredemo.Soredemo` specifically, not to whatever launched it.
    ///
    /// `restricted` controls whether `CaptureSourcePicker.present(restrictModes:)`
    /// leaves `allowedPickerModes` at the SDK's own default (`0`, excludes
    /// nothing) or narrows it to `.singleWindow`/`.singleDisplay`. Presenting
    /// the *same binary* both ways is what separates three causes that read
    /// identically as "I did not see an Applications option": the
    /// restriction working, nobody looking carefully, or this OS version
    /// never offering that mode regardless of the restriction — the last of
    /// which would make the check vacuous forever (`AGENTS.md`: an
    /// unobserved red is not a check). Printed in the identity block, so a
    /// transcript cannot be misattributed to the wrong run.
    ///
    /// Prints, in order: the same subject block `--dump-permissions` prints
    /// (`CapturePermissions.subjectBlockLines()` — which build, which
    /// process, extended in Task 7's fix round 3 rather than duplicated),
    /// then which picker mode this run used, then the raw filter (`style`,
    /// `contentRect`, `pointPixelScale`) via `CaptureSourcePicker`'s
    /// `debugFilterObserver` hook, then the derived `CaptureSource`.
    ///
    /// **Units come from `PointRect`/`PixelRect`'s own `description`, not
    /// from a hand-written format string.** An earlier version of this
    /// function wrote `"\(display.width)x\(display.height) pt"` for
    /// `.display` and `"\(bufferSize.width)x\(bufferSize.height) px"` for
    /// `.window` — two independently-typed unit suffixes, side by side in
    /// one person's terminal, which is exactly the silent-mixing risk
    /// `PointRect`/`PixelRect` exist to make a compile error one layer
    /// down (design doc § Geometry: the Y-axis flip, Task 10.5). Routing
    /// `filter.contentRect` through `CGGeometryBridge.pointRect(from:)`
    /// here is not a new exception to rule 5 — it is exactly what the
    /// bridge is for, at the one file allowed to call it.
    ///
    /// Exits after exactly one selection, cancellation, or picker-start
    /// failure — see `task-7-report.md` for what to expect from each of the
    /// three selection cases, and for why the subject block's `build`/
    /// `commit` lines are the first thing to check before trusting anything
    /// printed after them.
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
                    print("derived CaptureSource: .window(windowID: \(window.windowID), " +
                          "title: \(window.title ?? "nil"), bufferSize: \(sizeInPixels))")
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
