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
/// **The mark is a daruma, and its painted eye is the record button.** Idle the eye is a ring;
/// counting down it is faint inside a draining red ring; recording it is filled, in the record
/// red; paused it is two bars; and when a take finishes the second eye is painted in for a moment.
/// `MenuBarMark` decides which. The plain states are template images, so the system tints them;
/// the two with red are drawn — `RecordingMark`, `CountdownMark`. All five share one canvas,
/// drawn by `scripts/make-daruma-marks.swift`, so the item keeps one width whatever it shows.
struct MenuBarRecorderLabel: View {
    let coordinator: RecordingCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch MenuBarMark.state(countdown: CountdownPresenter.shared.running,
                                     isStarting: coordinator.isStartingCapture,
                                     isRecording: coordinator.isRecording,
                                     isPaused: coordinator.isPaused,
                                     isFinished: coordinator.paintedEye.isPainted) {
            case .paused:
                Image("LogomarkPausedTemplate")
                    .renderingMode(.template)
                    .accessibilityLabel(Text("Paused"))
            case .recording:
                Image(nsImage: RecordingMark.image)
                    .accessibilityLabel(Text("Recording"))
            case .countingDown(let ring):
                Image(nsImage: CountdownMark.image(ring: ring))
                    .accessibilityLabel(Text("Counting down"))
            case .finished:
                Image("LogomarkDoneTemplate")
                    .renderingMode(.template)
                    .accessibilityLabel(Text("Recording finished"))
            case .idle:
                // **No `.frame` here, and that is the fix.** Twice I sized this with a frame
                // and twice it changed nothing a person could see: SwiftUI scales a menu bar
                // image to the bar's height whatever frame it is given, so the only thing that
                // controls how big the mark LOOKS is the proportion of its canvas the ink
                // occupies. `scripts/make-daruma-marks.swift` bakes that in — the ink is 88% of a
                // square canvas and the rest is transparent.
                //
                // Measured on a screenshot of the menu bar (2026-10-25, 2x): the system's own
                // symbols — volume, Wi-Fi, Control Center — have 12 to 13pt of ink. At 62% the
                // daruma had 11pt and read as a size smaller than its neighbours, and at 70%, level
                // with them in height, it still did: it is narrower, and its face is cut out. 88% is
                // 15.8pt, between Google Drive's and LINE's marks, which reads as the same size.
                Image("LogomarkTemplate")
                    .renderingMode(.template)
                    .accessibilityLabel(Text("Soredemo"))
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

/// The recording state's mark: the daruma's body in the menu bar's own ink, its eye in the record
/// red, as the website draws it.
///
/// **A template image cannot carry the red** — it is alpha only, and the system paints all of it
/// one colour — so this is two images drawn together each time the item is drawn: the body
/// filled with `labelColor`, which resolves against the appearance the menu bar is drawing in
/// (light or dark, which follows the wallpaper rather than the system's setting), and the red eye
/// over it unchanged. Drawn rather than baked, so the body follows the bar when the wallpaper or
/// the appearance changes.
private enum RecordingMark {
    static let image: NSImage = {
        let body = NSImage(named: "LogomarkRecordingBody")
        let eye = NSImage(named: "LogomarkRecordingEye")
        let size = body?.size ?? NSSize(width: 18, height: 18)
        return NSImage(size: size, flipped: false) { rect in
            guard let body, let eye else { return false }
            body.draw(in: rect)
            NSColor.labelColor.set()
            rect.fill(using: .sourceAtop)
            eye.draw(in: rect)
            return true
        }
    }()
}
