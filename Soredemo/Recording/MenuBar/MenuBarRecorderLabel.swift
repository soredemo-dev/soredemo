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
/// **The mark is the daruma character, drawn** — the same figure the panel, the notch and the
/// countdown draw, at 18 points (`DarumaMark`). Idle it looks ahead; counting down a red ring
/// drains round its right eye; recording that eye is lit red; paused its eyes are ⏸; when a take
/// finishes it smiles with both eyes for a moment. `MenuBarMark` decides which. The ink-only
/// states are template images, so the system tints them; the two with red are not.
struct MenuBarRecorderLabel: View {
    let coordinator: RecordingCoordinator
    @Environment(\.openWindow) private var openWindow
    @AppStorage(DarumaFaceStyle.defaultsKey) private var faceStyle = DarumaFaceStyle.window

    var body: some View {
        let state = MenuBarMark.state(countdown: CountdownPresenter.shared.running,
                                      isStarting: coordinator.isStartingCapture,
                                      isRecording: coordinator.isRecording,
                                      isPaused: coordinator.isPaused,
                                      isFinished: coordinator.paintedEye.isPainted)
        // **No `.frame`**: SwiftUI scales a menu bar image to the bar's height whatever frame it is
        // given, so how big the mark looks is the share of its canvas the ink takes — 88%, measured
        // against the system's own symbols (2026-10-25). `DarumaMark` draws at that share.
        Image(nsImage: DarumaMark.image(for: state, faceWindow: faceStyle == .window))
            .accessibilityLabel(Self.label(state))
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

    private static func label(_ state: MenuBarMark) -> Text {
        switch state {
        case .idle: Text("Soredemo")
        case .countingDown: Text("Counting down")
        case .recording: Text("Recording")
        case .paused: Text("Paused")
        case .finished: Text("Recording finished")
        }
    }
}
