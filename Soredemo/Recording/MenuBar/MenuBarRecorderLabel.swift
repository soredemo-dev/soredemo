import AppKit
import Capture
import SwiftUI

/// What sits in the menu bar.
///
/// **This is the app.** A recorder is used from inside whatever is being demonstrated: the
/// moment a person opens a window to press Record, the thing they wanted to record is behind it.
/// So there is no window at launch and no Dock icon — the editor is opened by a recording
/// finishing, which is the only moment there is anything to edit.
///
/// **The icon carries the state, and nothing else does — it used to carry the clock too.**
/// A menu bar with the notch and a dozen extras in it has no room to spare, and an item that
/// grows when recording starts is an item macOS hides at the moment it matters most: measured on
/// a full menu bar, adding the timer text made this disappear entirely the instant a recording
/// began. So the width is constant. The elapsed time lives on the floating bar, which is on the
/// recorded screen the whole time anyway, and in the panel.
///
/// Idle it is the logomark as a template image, so the system tints it for a light or dark menu
/// bar. Recording it is a filled record symbol, and paused a filled pause — different SHAPES
/// rather than different colours, because a template image has no colour of its own.
struct MenuBarRecorderLabel: View {
    let coordinator: RecordingCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if coordinator.isRecording {
                Image(systemName: coordinator.isPaused
                      ? "pause.circle.fill" : "record.circle.fill")
            } else {
                // **No `.frame` here, and that is the fix.** Twice I sized this with a frame
                // and twice it changed nothing a person could see: SwiftUI scales a menu bar
                // image to the bar's height whatever frame it is given, so the only thing that
                // controls how big the mark LOOKS is the proportion of its canvas the ink
                // occupies. `scripts/make-menubar-logomark.swift` bakes that in — the ink is
                // 62% of a square canvas and the rest is transparent.
                //
                // Measured, which is how the frame theory died: an SF Symbol in the menu bar has
                // about 14pt of ink, and this mark inside a 13pt frame had 12pt — already
                // shorter, and still reading as larger, because a solid brushstroke carries far
                // more visual weight than line art at the same height.
                Image("LogomarkTemplate")
                    .renderingMode(.template)
            }
        }
        // **The label is where this lives because the label is always in the scene graph.** The
        // panel's body only runs while the popover is open, so an editor opened from there would
        // wait for a person to click the menu bar item after their recording finished.
        //
        // This is also what an `NSStatusItem` could not give back. Owning the item bought
        // position control and cost this: measured on the shipped app, nothing built the label,
        // so finishing a recording opened nothing and a first run never showed the permission
        // page. Both had been dead since the scene was removed.
        .onChange(of: coordinator.mediaURL) {
            guard coordinator.mediaURL != nil else { return }
            EditorWindowPresence.openEditor { openWindow(id: $0) }
        }
        // **First run opens the permission page.** Not every run: a person who has granted
        // everything is greeted by nothing, which is the correct amount of greeting. The check
        // is on what is MISSING rather than on a "have we shown this" flag, so someone who
        // revokes a permission later gets the page again instead of a silent failure.
        .task {
            guard !CapturePermissions.blockingFailures().isEmpty else { return }
            EditorWindowPresence.willOpen()
            openWindow(id: WindowID.permissions)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
