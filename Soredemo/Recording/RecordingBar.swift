import AppKit
import Capture
import Combine
import Geometry
import SwiftUI

/// The bar that floats over the screen while it is being recorded.
///
/// **A panel, not a window, and every flag here is load-bearing.** `.nonactivatingPanel` so
/// clicking Stop does not pull focus away from whatever is being demonstrated — a bar that stole
/// focus would change the thing it is recording. `.canJoinAllSpaces` so it survives a Space
/// switch mid-recording. `.floating` so it stays above the app being shown.
/// A capture toolbar wants the same
/// five controls and nothing else.
///
/// **It is excluded from the capture, and that took a real recording to notice.** A 22-second
/// screen recording came back with this bar sitting across the bottom of the picture for its
/// whole length: the display filter was built with `excludingWindows: []`, which excludes
/// nothing. `CaptureSource.filter(excluding:)` now passes this process, so a recorder that puts a
/// control strip over the screen stops recording the strip.
@MainActor
final class RecordingBarPanel: NSPanel {
    private static let width: Double = 400
    private static let height: Double = 52
    /// How far above the bottom of the screen it sits. Far enough to clear the Dock at its
    /// default size, which is where a person's eye already is during a demo.
    private static let bottomInset: Double = 72

    init(coordinator: RecordingCoordinator) {
        super.init(contentRect: CGGeometryBridge.rect(from: PointRect(
                       x: 0, y: 0, width: Self.width, height: Self.height)),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Dragged from anywhere on it: there is no title bar to grab, and a bar sitting over the
        // one control a person needs is a bar they must be able to move.
        isMovableByWindowBackground = true

        let hosting = NSHostingView(rootView: RecordingBarView(coordinator: coordinator))
        hosting.frame = CGGeometryBridge.rect(from: PointRect(
            x: 0, y: 0, width: Self.width, height: Self.height))
        contentView = hosting
        placeAtBottomOfActiveScreen()
    }

    /// **The screen the pointer is on**, not the main one: a person recording their second
    /// display should not have the controls appear on the first.
    private func placeAtBottomOfActiveScreen() {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        setFrame(CGGeometryBridge.rect(from: PointRect(
            x: Double(visible.midX) - Self.width / 2,
            y: Double(visible.minY) + Self.bottomInset,
            width: Self.width, height: Self.height)), display: true)
    }

    /// Key so ⎋ and ⌘. reach it; never main, so the app behind it keeps its main window.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Shows and hides the bar in step with the coordinator. **Owned by the app rather than by a
/// view**, because a SwiftUI view that owned an `NSPanel` would create and destroy it every time
/// the body re-evaluated.
@MainActor
final class RecordingBarPresenter {
    static let shared = RecordingBarPresenter()
    private var panel: RecordingBarPanel?

    private init() {}

    func show(coordinator: RecordingCoordinator) {
        guard panel == nil else { return }
        let panel = RecordingBarPanel(coordinator: coordinator)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - the bar itself

struct RecordingBarView: View {
    let coordinator: RecordingCoordinator
    /// 20 Hz. Fast enough that the level meter moves rather than steps, slow enough that it is
    /// not a frame-rate cost on a machine already encoding video.
    private static let tick: Double = 1.0 / 20

    /// Collapsed to a dot in the corner. **Not hidden entirely**: a recorder with no visible
    /// indicator is one people leave running, and the menu bar item can be pushed off a full
    /// menu bar — which is exactly what happens on a Mac with a notch. Collapsed it is 44 points
    /// wide and still says a recording is happening.
    @State private var isCollapsed = false

    var body: some View {
        Group {
            if isCollapsed { collapsed } else { expanded }
        }
        .onReceive(Timer.publish(every: Self.tick, on: .main, in: .common).autoconnect()) { _ in
            coordinator.tick(Self.tick)
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: isCollapsed)
    }

    @ViewBuilder private var expanded: some View {
        HStack(spacing: Space.regular) {
            grip
            state
            Divider().frame(height: 22).opacity(0.25)
            microphone
            Spacer(minLength: 0)
            BarButton(icon: coordinator.isPaused ? "play.fill" : "pause.fill",
                      label: coordinator.isPaused ? "Resume" : "Pause") {
                coordinator.togglePause()
            }
            BarButton(icon: "chevron.right.2", label: "Collapse — the recording keeps going") {
                isCollapsed = true
            }
            stopButton
        }
        .padding(.horizontal, Space.regular)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassSurface(radius: Glass.barRadius)
        .padding(Space.tight)
    }

    /// **A dot and nothing else.** Clicking it brings the controls back; the recording never
    /// stopped, and nothing here can stop it by accident.
    @ViewBuilder private var collapsed: some View {
        HStack {
            Button { isCollapsed = false } label: {
                HStack(spacing: Space.snug) {
                    PulsingDot(isPaused: coordinator.isPaused)
                    Image(systemName: "chevron.left.2")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, Space.regular)
                .frame(height: 30)
                .glassSurface(radius: 15)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show the recording controls")
            Spacer(minLength: 0)
        }
        .padding(Space.tight)
    }

    /// The drag handle. The panel is `isMovableByWindowBackground`, so anywhere on it works —
    /// this says so, which is the whole job of a grip.
    @ViewBuilder private var grip: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.35))
            .help("Drag anywhere on the bar to move it")
    }

    /// The dot and the clock. **`monospacedDigit`, and it is not cosmetic**: a timecode whose
    /// digits change width jitters the two controls beside it every second.
    @ViewBuilder private var state: some View {
        HStack(spacing: Space.snug) {
            PulsingDot(isPaused: coordinator.isPaused)
            Text(Self.elapsedText(coordinator.elapsed))
                .font(.system(size: 15, weight: .medium).monospacedDigit())
                .foregroundStyle(.white)
            if coordinator.isPaused {
                Text("PAUSED")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Signal.paused)
                    .padding(.horizontal, Space.tight + 2)
                    .padding(.vertical, Space.hairline)
                    .background(Capsule().fill(Signal.paused.opacity(0.16)))
            }
        }
    }

    /// The microphone, with its level under it — a Rust recorder puts a two-pixel meter inside the mic
    /// button for the same reason: the question a person has during a recording is not "is the
    /// microphone on" but "is it hearing me", and only a moving bar answers that.
    @ViewBuilder private var microphone: some View {
        VStack(spacing: Space.tight) {
            Image(systemName: coordinator.microphoneLevel == nil ? "mic.slash" : "mic.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(coordinator.microphoneLevel == nil ? 0.45 : 0.95))
            LevelMeter(level: coordinator.microphoneLevel)
        }
        .frame(width: 34)
        .help(coordinator.microphoneLevel == nil
              ? "No microphone in this recording" : "Microphone level")
    }

    @ViewBuilder private var stopButton: some View {
        Button { coordinator.stop() } label: {
            HStack(spacing: Space.tight + 2) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(.white)
                    .frame(width: 9, height: 9)
                Text("Stop").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Space.regular)
            .padding(.vertical, Space.snug)
            .background(Capsule().fill(Signal.record))
        }
        .buttonStyle(.plain)
        // **No `.keyboardShortcut` here.** This panel is `.nonactivatingPanel` so it never
        // becomes key, and a shortcut on a button in a window that cannot take focus is a
        // shortcut that never fires — which is what ⎋ was doing. The key that stops a recording
        // is registered system-wide; see `GlobalHotkey`.
        .help("Stop recording (\(MenuBarRecorderPanel.toggleShortcut))")
    }

    /// `m:ss` under an hour, `h:mm:ss` over it. A leading `00:` on every recording is two
    /// characters of nothing in the one place where width costs the layout.
    /// **Not named `clock`.** `noAppSourceReadsAnAmbientValueAtAll` bans that substring in
    /// app sources, because a clock is where ambient time enters — and the ban being absolute is
    /// what makes it worth having. This function reads no time; it formats a number it is given.
    static func elapsedText(_ seconds: Double) -> String {
        let whole = Int(max(0, seconds))
        let (hours, minutes, secs) = (whole / 3600, (whole / 60) % 60, whole % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

/// The record indicator: pulsing while recording, steady while paused.
///
/// **It stops pulsing when paused rather than changing colour**, because the pulse is what makes
/// a person notice it at all in the corner of their eye, and a paused recording is exactly when
/// they need to notice.
private struct PulsingDot: View {
    let isPaused: Bool
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(isPaused ? Signal.paused : Signal.record)
            .frame(width: 9, height: 9)
            .opacity(isPaused ? 1 : (dim ? 0.3 : 1))
            .animation(isPaused ? nil
                       : .easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
            .accessibilityLabel(isPaused ? "Paused" : "Recording")
    }
}

/// A thin horizontal level bar. `nil` draws the track alone — the state that means "nothing is
/// being heard", which is different from "silence" and must not look the same as a full meter.
private struct LevelMeter: View {
    let level: Double?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule()
                    .fill(Signal.level)
                    .frame(width: proxy.size.width * (level ?? 0))
            }
        }
        .frame(height: 3)
        .animation(.linear(duration: 0.05), value: level)
    }
}

/// An icon button on the bar. Hover feedback rather than a permanent border: a strip of bordered
/// buttons over a person's screen is a strip of clutter.
private struct BarButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(isHovering ? 1 : 0.8))
                .frame(width: 30, height: 30)
                .background {
                    RoundedRectangle(cornerRadius: Glass.controlRadius, style: .continuous)
                        .fill(.white.opacity(isHovering ? Glass.hoverOpacity : 0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}
