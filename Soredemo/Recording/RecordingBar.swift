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
    /// The pill: what a person sees, and the only part of the window that takes a click.
    static let barWidth: Double = 392
    static let barHeight: Double = 44
    /// The window, which is the pill plus transparent room for the pill's shadow. **The two
    /// were the same rectangle until 2026-09-16 and that is what made the shadow a rectangle**:
    /// eighteen points of blur inside four points of padding is a shadow sliced off flat at the
    /// window's edge. See `Glass.shadowRoomSides`.
    static var panelWidth: Double { barWidth + Glass.shadowRoomSides * 2 }
    static var panelHeight: Double { barHeight + Glass.shadowRoomTop + Glass.shadowRoomBottom }
    /// How far above the bottom of the screen the PILL sits — not the window, which now carries
    /// shadow room under it. Far enough to clear the Dock at its default size, which is where a
    /// person's eye already is during a demo. 76 rather than 72 because it used to be measured
    /// to the window's edge with four points of padding inside it; the bar has not moved.
    private static let bottomInset: Double = 76

    /// Moves the window while somebody drags the bar. Held here because the view is a struct
    /// rebuilt on every tick and the grab has to outlive that.
    private let dragger = WindowDragger()

    /// How many drag changes reached the bar, and what the window saw of the pointer.
    /// For `--show-recording-bar`.
    var dragMoves: Int { dragger.moves }
    var hitCounts: (pill: Int, halo: Int) {
        guard let hosting = contentView as? BarHostingView<RecordingBarView> else { return (0, 0) }
        return (hosting.hitsOnPill, hosting.hitsInHalo)
    }

    init(coordinator: RecordingCoordinator, startCollapsed: Bool = false) {
        super.init(contentRect: CGGeometryBridge.rect(from: PointRect(
                       x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight)),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // **Left on, and it is not what moves the bar.** `isMovableByWindowBackground` does not
        // survive an `NSHostingView`: driven with synthesised events, this panel with a plain
        // `NSView` in it moved 88 points and the identical panel with SwiftUI in it did not
        // move at all — which is why the bar could never be dragged. `WindowDragger` does the
        // moving; this stays because it costs nothing and is what a reader expects to find.
        isMovableByWindowBackground = true

        let hosting = BarHostingView(
            rootView: RecordingBarView(coordinator: coordinator, dragger: dragger,
                                       startCollapsed: startCollapsed))
        hosting.frame = CGGeometryBridge.rect(from: PointRect(
            x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight))
        // In AppKit's bottom-left space, the pill sits above the shadow room beneath it.
        hosting.pill = NSRect(x: Glass.shadowRoomSides, y: Glass.shadowRoomBottom,
                              width: Self.barWidth, height: Self.barHeight)
        contentView = hosting
        dragger.window = self
        placeAtBottomOfActiveScreen()
    }

    /// **The screen the pointer is on**, not the main one: a person recording their second
    /// display should not have the controls appear on the first.
    private func placeAtBottomOfActiveScreen() {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        // `bottomInset` is where the PILL goes, so the window starts a shadow's depth lower.
        setFrame(CGGeometryBridge.rect(from: PointRect(
            x: Double(visible.midX) - Self.panelWidth / 2,
            y: Double(visible.minY) + Self.bottomInset - Glass.shadowRoomBottom,
            width: Self.panelWidth, height: Self.panelHeight)), display: true)
    }

    /// Key so ⎋ and ⌘. reach it; never main, so the app behind it keeps its main window.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The bar's content, with the shadow's halo passing clicks through to whatever is behind.
///
/// **The window is bigger than the bar and the difference must not be clickable.** The extra is
/// transparent room for the shadow, and a window swallows every click inside its frame whether
/// anything is drawn there or not — without this the bar would eat clicks in an eighteen-point
/// halo around itself, on the screen somebody is recording, over the control they were reaching
/// for. The old four-point padding had the same defect at a size nobody noticed.
private final class BarHostingView<Content: View>: NSHostingView<Content> {
    /// The pill's rectangle in this view's own coordinates. A named zero rather than an
    /// optional: a view whose pill has not been set yet takes no clicks, which is the safe
    /// reading of "nobody has said where the bar is".
    var pill: NSRect = .zero
    /// How many hit tests landed on the bar, and how many fell in the shadow's halo. Printed by
    /// `--show-recording-bar`: "the bar did not move" has too many causes to guess between, and
    /// whether the window is seeing the pointer at all is the first fork.
    private(set) var hitsOnPill = 0
    private(set) var hitsInHalo = 0

    /// **The first click on this bar must count, and by default it does not.**
    ///
    /// AppKit discards the mouse-down that arrives at an inactive application's window unless
    /// the view under it says otherwise — it is treated as the click that brings the app
    /// forward. This bar is never the frontmost app: it floats over whatever is being recorded,
    /// on purpose. So EVERY click on it is a first click, and every one of them was being
    /// thrown away.
    ///
    /// Measured 2026-09-16 with `--show-recording-bar` and synthesised events: one press and
    /// drag moved the bar zero points and delivered zero gesture changes, while a click
    /// followed by the identical drag moved it 140 and delivered fifteen. The window was seeing
    /// the pointer the whole time — its own hit-test counter said so — which is what ruled out
    /// every explanation on the other side of AppKit.
    ///
    /// It is not only the drag: the Stop button sat behind the same rule, so stopping a
    /// recording took two presses and the first one looked like a bar that ignores you.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard pill.contains(point) else {
            hitsInHalo += 1
            return nil
        }
        hitsOnPill += 1
        return super.hitTest(point)
    }

    required init(rootView: Content) { super.init(rootView: rootView) }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BarHostingView is built in code; there is no nib to decode it from.")
    }
}

/// Moves the bar's window while somebody drags it.
///
/// **The bar was never draggable and nothing said so.** `isMovableByWindowBackground` is set on
/// the panel and does not survive an `NSHostingView`: measured with synthesised events, the
/// same panel moved 88 points with a plain `NSView` in it and did not move at all with SwiftUI
/// in it. Two earlier repairs were measured and rejected — an `NSView` behind the content
/// answering `mouseDownCanMoveWindow`, and the same view inside a `ZStack`; neither moved the
/// window either. What works is doing the move ourselves, and the button beside it still fires.
@MainActor
final class WindowDragger {
    /// Weak: the panel owns this, and this must not own the panel back.
    weak var window: NSWindow?
    private var drag = WindowDrag()
    /// How many changes the gesture has delivered. **`--show-recording-bar` prints it**, because
    /// "the bar did not move" has two causes that look identical from outside: the gesture never
    /// fired, or it fired and the move did not take. One number separates them.
    private(set) var moves = 0

    /// One change of the gesture.
    ///
    /// **The pointer is read from the system, not from the gesture.** `DragGesture` reports a
    /// translation inside a coordinate space that belongs to the window being moved, so a
    /// window moved by it stops after one frame. See `WindowDrag`.
    func moved() {
        moves += 1
        guard let window else { return }
        let pointer = NSEvent.mouseLocation
        let origin = drag.origin(pointerX: Double(pointer.x), pointerY: Double(pointer.y),
                                 windowX: Double(window.frame.minX),
                                 windowY: Double(window.frame.minY))
        window.setFrameOrigin(NSPoint(x: origin.x, y: origin.y))
    }

    func ended() { drag.end() }
}

/// Shows and hides the bar in step with the coordinator. **Owned by the app rather than by a
/// view**, because a SwiftUI view that owned an `NSPanel` would create and destroy it every time
/// the body re-evaluated.
@MainActor
final class RecordingBarPresenter {
    static let shared = RecordingBarPresenter()
    private var panel: RecordingBarPanel?

    private init() {}

    func show(coordinator: RecordingCoordinator, startCollapsed: Bool = false) {
        guard panel == nil else { return }
        let panel = RecordingBarPanel(coordinator: coordinator, startCollapsed: startCollapsed)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Where the bar's window is, for `--show-recording-bar` to say whether a drag moved it.
    /// The WINDOW's frame, shadow room included, because that is what a move changes.
    var barFrame: PointRect? {
        panel.map { CGGeometryBridge.pointRect(from: $0.frame) }
    }

    /// How many drag changes the bar has seen. See `WindowDragger.moves`.
    var dragMoves: Int { panel?.dragMoves ?? 0 }
    var hitCounts: (pill: Int, halo: Int) { panel?.hitCounts ?? (0, 0) }
}

// MARK: - the bar itself

struct RecordingBarView: View {
    let coordinator: RecordingCoordinator
    /// What moves the window. Owned by the panel; see `WindowDragger` for why the bar cannot be
    /// dragged by AppKit alone.
    let dragger: WindowDragger

    /// Whether it opens collapsed. **Only `--show-recording-bar` passes true**: the check that
    /// drives it has to be able to reach the collapsed state, where the bar is one control and
    /// nothing else — which is exactly where "it cannot be dragged" hid.
    let startCollapsed: Bool

    /// Collapsed to a dot in the corner. **Not hidden entirely**: a recorder with no visible
    /// indicator is one people leave running, and the menu bar item can be pushed off a full
    /// menu bar — which is exactly what happens on a Mac with a notch. Collapsed it is 44 points
    /// wide and still says a recording is happening.
    @State private var isCollapsed = false

    var body: some View {
        Group {
            if isCollapsed { collapsed } else { expanded }
        }
        .onAppear { isCollapsed = startCollapsed }
        // **The window's shadow room, and it is padding rather than a bigger pill.** The panel
        // is the bar plus this on every side; without it the shadow is clipped at the window's
        // edge and reads as a hard rectangle. See `Glass.shadowRoomSides`.
        .padding(.horizontal, Glass.shadowRoomSides)
        .padding(.top, Glass.shadowRoomTop)
        .padding(.bottom, Glass.shadowRoomBottom)
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
            clipButton
            stopButton
        }
        .padding(.horizontal, Space.regular)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { dragSurface }
        .glassSurface(radius: Glass.barRadius)
    }

    /// **Where the drag lives: behind the controls, not over them.** A gesture on the whole bar
    /// competes with every button on it; one on a layer underneath is reached only where no
    /// control is, which is exactly "drag it by its background". Measured: with this in place a
    /// synthesised drag moves the window 88 points AND the Stop button still fires.
    @ViewBuilder private var dragSurface: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { _ in dragger.moved() }
                    .onEnded { _ in dragger.ended() })
    }

    /// **A dot and nothing else.** Clicking it brings the controls back; the recording never
    /// stopped, and nothing here can stop it by accident.
    ///
    /// **Not a `Button`, and that is why the collapsed bar could not be dragged.** A `Button`
    /// takes the mouse for the whole press, so the drag surface behind it never saw one — and
    /// collapsed, the button IS the bar: there is nothing else to grab. A tap and a drag on the
    /// same view lets SwiftUI tell them apart by distance, which is the same thing a person
    /// does with their hand.
    @ViewBuilder private var collapsed: some View {
        HStack {
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
            // Four points rather than the expanded bar's one: collapsed, a click is the
            // primary action and a press that wandered must still open it.
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { _ in dragger.moved() }
                    .onEnded { _ in dragger.ended() })
            .onTapGesture { isCollapsed = false }
            .help("Click to show the controls, drag to move the bar")
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background { dragSurface }
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
            Text(verbatim: Self.elapsedText(coordinator.elapsed))
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

    /// The microphone, with its level under it — a surveyed recorder puts a two-pixel meter inside
    /// the mic button for the same reason: the question a person has during a recording is not "is the
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
              ? Text("No microphone in this recording") : Text("Microphone level"))
    }

    /// Save the last fifteen seconds, while the recording keeps going.
    ///
    /// **Present only while it would work.** `clipReadiness` has three answers and only one of
    /// them is a button: a Mac without the API gets nothing, a buffer that failed to start gets
    /// nothing — the recording is unaffected either way, and a control that refuses when
    /// pressed is worse than one that was never there. The reason is not lost: it is in the
    /// status line if anybody looks.
    ///
    /// **Not a shortcut.** This panel is `.nonactivatingPanel` and never becomes key, for the
    /// reason the Stop button records; a system-wide key for this would need registering
    /// beside the stop key, which is a decision about somebody's keyboard and not one to make
    /// on their behalf.
    @ViewBuilder private var clipButton: some View {
        if case .ready(let ceiling) = coordinator.clipReadiness {
            Button { coordinator.saveClip(lastSeconds: ceiling) } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Space.snug)
                    .padding(.vertical, Space.snug)
            }
            .buttonStyle(.plain)
            .help("Save the last \(Int(ceiling)) seconds — the recording keeps going")
        }
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
struct PulsingDot: View {
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
            .accessibilityLabel(isPaused ? Text("Paused") : Text("Recording"))
    }
}

/// A thin horizontal level bar. `nil` draws the track alone — the state that means "nothing is
/// being heard", which is different from "silence" and must not look the same as a full meter.
struct LevelMeter: View {
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
    let label: LocalizedStringKey
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
