import AppKit
import Capture
import Geometry
import SwiftUI

/// The three seconds between choosing what to record and the recording starting.
///
/// **Without it the first second of every recording is a hand moving away from the mouse.** The
/// picker closes and the capture is already running; there is nowhere to put the pointer and no
/// moment to compose. It is a variant of the recording state rather than a separate mode, and
/// it is on by default.
///
/// **It counts on the screen being recorded, and it is excluded from the recording** — the
/// capture filter leaves this process out, which is what `CaptureSource.filter(excluding:)` is
/// for. A countdown that appeared in the file would be worse than none.
@MainActor
final class CountdownPresenter {
    static let shared = CountdownPresenter()
    private var panel: NSPanel?

    private init() {}

    /// Runs the countdown and returns when it is finished. Returns immediately for zero, which
    /// is what "off" is — a person who turned it off is not waiting for a frame of it.
    func run(seconds: Int) async {
        guard seconds > 0 else { return }
        let state = CountdownState(remaining: seconds)
        show(state)
        defer { hide() }

        for value in stride(from: seconds, through: 1, by: -1) {
            state.remaining = value
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func show(_ state: CountdownState) {
        let side: Double = 220
        let panel = NSPanel(contentRect: CGGeometryBridge.rect(from: PointRect(
                                x: 0, y: 0, width: side, height: side)),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // **Click-through.** The whole point of the countdown is the seconds before recording,
        // and a person using them to position a window must not be blocked by the count.
        panel.ignoresMouseEvents = true

        let hosting = NSHostingView(rootView: CountdownView(state: state))
        hosting.frame = CGGeometryBridge.rect(from: PointRect(
            x: 0, y: 0, width: side, height: side))
        panel.contentView = hosting

        // Centred on the screen the pointer is on — the one about to be recorded.
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrame(CGGeometryBridge.rect(from: PointRect(
                x: Double(visible.midX) - side / 2,
                y: Double(visible.midY) - side / 2,
                width: side, height: side)), display: true)
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// The count, as an object the panel's view can watch. A plain value would need the hosting view
/// rebuilt each second, which recreates the animation from scratch.
@MainActor
@Observable
final class CountdownState {
    var remaining: Int
    init(remaining: Int) { self.remaining = remaining }
}

private struct CountdownView: View {
    let state: CountdownState

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .overlay { Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1) }
                .shadow(color: .black.opacity(0.4), radius: 24)
            Text("\(state.remaining)")
                .font(.system(size: 96, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                // Keyed on the value so each number gets its own transition rather than the
                // digits morphing into one another.
                .id(state.remaining)
                .transition(.scale(scale: 1.35).combined(with: .opacity))
        }
        .padding(Space.roomy)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: state.remaining)
    }
}
