//
//  SoredemoApp.swift
//  Soredemo
//
//  Created by Jesse Liang on 2026/8/1.
//

import AppKit
import SwiftUI

@main
struct SoredemoApp: App {
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
}
