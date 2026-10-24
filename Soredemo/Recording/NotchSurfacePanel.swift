import AppKit
import Capture
import Geometry
import SwiftUI

/// What the notch surface is showing, and where, on one screen. The state machine and the layout
/// are pure (`NotchSurface.swift`); this holds the one instance of each the panel draws.
@MainActor @Observable
final class NotchSurfaceModel {
    private(set) var state: NotchSurfaceState = .dormant
    /// The notch, in the screen's own top-left points.
    let notch: PointRect
    let screen: PointRect

    init(notch: PointRect, screen: PointRect) {
        self.notch = notch
        self.screen = screen
    }

    func send(_ event: NotchSurfaceState.Event) {
        state = state.handling(event)
    }

    /// The surface in the screen's top-left points, for the current state.
    var rect: PointRect { NotchSurfaceLayout.rect(for: state, notch: notch, screen: screen) }

    /// **The panel is the size of the largest state and never moves**; the shape inside animates.
    /// Moving the window per state would animate a window frame, which AppKit does not spring.
    var panelRect: PointRect {
        let largest = [NotchSurfaceState.open, .live(expanded: true), .glance].map {
            NotchSurfaceLayout.rect(for: $0, notch: notch, screen: screen)
        }
        let width = largest.map(\.width).max() ?? notch.width
        let height = largest.map(\.height).max() ?? notch.height
        let centre = notch.x + notch.width / 2
        return PointRect(x: centre - width / 2 - flare, y: 0, width: width + 2 * flare, height: height)
    }

    /// The surface in the panel's own top-left points.
    var localRect: PointRect {
        let panel = panelRect, surface = rect
        return PointRect(x: surface.x - panel.x, y: surface.y - panel.y,
                         width: surface.width, height: surface.height)
    }

    /// How far the top corners curl into the menu bar: the share of the notch's height the
    /// withdrawn design settled on (six of 32 on the machine both were measured on).
    var flare: Double { notch.height * 0.1875 }

    /// The bottom corners, which open as the surface grows: the notch's own curve when dormant,
    /// a panel's when open.
    var bottomRadius: Double {
        switch state {
        case .dormant: notch.height * 0.3
        case .glance, .live(expanded: false): notch.height * 0.45
        case .open, .live(expanded: true): 22
        }
    }
}

/// The notch surface's window.
///
/// **`isFloatingPanel` before `level`, and the order is the point.** `isFloatingPanel = true`
/// overwrites `level`, and the withdrawn notch design ran for its whole life at `.floating` —
/// under the menu bar — because the two lines were the other way round.
@MainActor
final class NotchSurfacePanel: NSPanel {
    private let model: NotchSurfaceModel

    init(model: NotchSurfaceModel, coordinator: RecordingCoordinator, screenFrame: PointRect) {
        self.model = model
        let panel = model.panelRect
        super.init(contentRect: CGGeometryBridge.rect(from: PointRect(
                       x: 0, y: 0, width: panel.width, height: panel.height)),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        // Above the menu bar, so the pointer on the notch reaches this window and not the bar's.
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        let hosting = NotchHostingView(
            rootView: NotchSurfaceView(model: model, coordinator: coordinator), model: model)
        hosting.frame = CGGeometryBridge.rect(from: PointRect(
            x: 0, y: 0, width: panel.width, height: panel.height))
        contentView = hosting
        // `screenFrame` is AppKit's bottom-left frame of the screen, as a `PointRect`.
        setFrame(CGGeometryBridge.rect(from: PointRect(
            x: screenFrame.x + panel.x,
            y: screenFrame.y + screenFrame.height - panel.height,
            width: panel.width, height: panel.height)), display: true)
    }

    /// Key only while the recorder is open — escape and the pickers need it there — and never
    /// during a take, when key focus would come off the application being recorded.
    override var canBecomeKey: Bool { model.state == .open }
    override var canBecomeMain: Bool { false }
}

/// The panel's content, taking clicks only inside the surface.
///
/// **The panel is larger than the shape and the difference must not be clickable**: it lies over
/// the menu bar, and an invisible rectangle there would eat clicks on the menu bar's items. The
/// same reason `RecordingBarPanel` passes its shadow's halo through.
private final class NotchHostingView<Content: View>: NSHostingView<Content> {
    private let model: NotchSurfaceModel

    init(rootView: Content, model: NotchSurfaceModel) {
        self.model = model
        super.init(rootView: rootView)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not from a nib") }
    @MainActor @preconcurrency required init(rootView: Content) { fatalError("use init(rootView:model:)") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let surface = model.localRect
        let x = Double(local.x)
        let fromTop = isFlipped ? Double(local.y) : Double(bounds.height) - Double(local.y)
        let inside = x >= surface.x && x <= surface.x + surface.width
            && fromTop >= 0 && fromTop <= surface.y + surface.height
        return inside ? super.hitTest(point) : nil
    }

    /// The first click on the notch counts even though this app is not frontmost — which it
    /// never is while somebody is using the notch.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The surface's black: a notch assistant's outward-curling top corners, bottom corners that open as it
/// grows. **A `Canvas`, not a `Shape`**: `Shape.path(in:)` would name `CGRect` in the app, which
/// rule 5 forbids, so the outline comes from `CGGeometryBridge.notchOutline`. `Animatable` so the
/// radius springs with the frame instead of jumping when the state changes.
private struct NotchBackground: View, Animatable {
    var bottomRadius: Double
    let flare: Double

    var animatableData: Double {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGGeometryBridge.notchOutline(
                width: Double(size.width), height: Double(size.height),
                flare: flare, bottomRadius: bottomRadius)), with: .color(.black))
        }
    }
}

/// What is drawn in the surface, per state. The shape and its size animate on one spring; the
/// content cross-fades inside it, so text never stretches with the frame.
struct NotchSurfaceView: View {
    let model: NotchSurfaceModel
    let coordinator: RecordingCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// a notch assistant's spring, which the tuning page kept. Reduce Motion gets a short fade instead:
    /// a surface travelling a few hundred points is what that setting exists to stop.
    private var motion: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.84)
    }

    var body: some View {
        let surface = model.localRect
        let panel = model.panelRect
        ZStack(alignment: .top) {
            NotchBackground(bottomRadius: model.bottomRadius, flare: model.flare)
                .frame(width: surface.width + 2 * model.flare, height: surface.height)
            content
                .frame(width: surface.width, height: surface.height, alignment: .top)
                .clipped()
        }
        .frame(width: panel.width, height: panel.height, alignment: .top)
        .animation(motion, value: model.state)
        .environment(\.colorScheme, .dark)
        .onExitCommand { model.send(.escape) }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        // The pointer and the click that wake and open the surface are read by the presenter's
        // monitors, not by views here: see `NotchSurfacePointer` for why hover could not do it.
        case .dormant:
            Color.clear
        case .glance:
            glanceRow.transition(.opacity)
        case .open:
            VStack(spacing: 0) {
                // **The mode switch sits in the wing, and it is two symbols.** The open surface's
                // depth is fixed — a third row was cut in half at its edge once already — and the
                // wing beside the notch is about 125 points. Measured with the real translations,
                // a worded switch is 84 to 188 points wide: past the wing, under the camera
                // housing, in eight of ten languages. The symbols are 50 in all of them, and the
                // right wing says which mode is on in words.
                wings(left: {
                    Picker("Capture", selection: Binding(get: { coordinator.capturePurpose },
                                                         set: { coordinator.capturePurpose = $0 })) {
                        Image(systemName: "record.circle").accessibilityLabel(Text("Record"))
                            .tag(RecordingCoordinator.CapturePurpose.take)
                        Image(systemName: "camera.viewfinder").accessibilityLabel(Text("Screenshot"))
                            .tag(RecordingCoordinator.CapturePurpose.picture)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .help(coordinator.capturePurpose == .take ? Text("Record") : Text("Screenshot"))
                }, right: {
                    if coordinator.capturePurpose == .take {
                        Text(verbatim: GlobalHotkey.toggleRecordingSpelling).opacity(0.6)
                    } else {
                        Text("Screenshot").lineLimit(1).minimumScaleFactor(0.8)
                    }
                })
                NotchRecorderControls(coordinator: coordinator) { model.send(.escape) }
                    .padding(.horizontal, Space.regular)
                    .padding(.bottom, Space.regular)
            }
            .transition(.opacity)
        case .live(let expanded):
            VStack(spacing: 0) {
                wings(left: {
                    HStack(spacing: Space.tight + 2) {
                        PulsingDot(isPaused: coordinator.isPaused)
                        Text(verbatim: RecordingBarView.elapsedText(coordinator.elapsed))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                    }
                }, right: {
                    NotchSoundWing(coordinator: coordinator)
                })
                if expanded {
                    NotchTakeControls(coordinator: coordinator)
                        .padding(.horizontal, Space.regular)
                        .padding(.bottom, Space.snug)
                        .transition(.opacity)
                }
            }
        }
    }

    private var glanceRow: some View {
        wings(left: {
            HStack(spacing: Space.tight) {
                Image(systemName: "record.circle.fill").foregroundStyle(Signal.record)
                Text("Record").lineLimit(1).minimumScaleFactor(0.7)
            }
        }, right: {
            Text(verbatim: GlobalHotkey.toggleRecordingSpelling).opacity(0.6)
        })
    }

    /// One row the notch's own height: something on each side of it, nothing over the camera.
    private func wings(@ViewBuilder left: () -> some View, @ViewBuilder right: () -> some View) -> some View {
        HStack(spacing: 0) {
            left().frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: model.notch.width)
            right().frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 12))
        .foregroundStyle(.white)
        .padding(.horizontal, Space.regular)
        .frame(height: model.notch.height)
    }
}

/// The open recorder: what to record, and with which microphone and camera.
private struct NotchRecorderControls: View {
    let coordinator: RecordingCoordinator
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            HStack(spacing: Space.snug) {
                target("display", "Screen") { coordinator.beginRecording(.displaysOnly) }
                target("macwindow", "Window") { coordinator.beginWindowRecordingByPointing() }
                target("rectangle.dashed", "Area") { coordinator.beginRegionRecording() }
                // **A plugged-in phone or tablet, the same fourth choice the menu offers.** This row
                // was built from the menu's first three and the fourth — which exists only while a
                // device does — was missed, so recording a phone from the notch was impossible.
                // A take's only: a phone is recorded through a stack with no screenshot path.
                if coordinator.capturePurpose == .take {
                    ForEach(coordinator.availableMobileScreens) { device in
                        target(device.symbolName, verbatim: device.displayName) {
                            coordinator.beginMobileRecording(device)
                        }
                    }
                    ForEach(coordinator.mobileScreensWaiting, id: \.self) { name in waiting(name) }
                }
            }
            HStack(spacing: Space.snug) {
                Menu {
                    Button("No microphone") { coordinator.microphone = .off }
                    Button("System default") { coordinator.microphone = .systemDefault }
                    ForEach(coordinator.availableMicrophones, id: \.self) { source in
                        Button(LocalizedStringKey(source.displayName)) { coordinator.microphone = source }
                    }
                } label: {
                    Label(LocalizedStringKey(coordinator.microphone.displayName),
                          systemImage: coordinator.microphone == .off ? "mic.slash" : "mic")
                }
                Menu {
                    Button("No camera") { coordinator.camera.choose(.off) }
                    ForEach(coordinator.camera.available, id: \.self) { source in
                        Button(LocalizedStringKey(source.displayName)) { coordinator.camera.choose(source) }
                    }
                } label: {
                    Label(LocalizedStringKey(coordinator.camera.source.displayName),
                          systemImage: coordinator.camera.source == .off ? "video.slash" : "video")
                }
                // **A hint, beside the choice it is about, and IN this row.** The open surface's
                // depth is fixed (`NotchSurfaceLayout.openDepth`); as a third row it was cut in
                // half at the surface's bottom edge — reported 2026-09-29 with a screenshot. This
                // row has the width to spare. Only when true; see `AudioRoute` for why it
                // suggests headphones and not muting.
                if coordinator.speakersReachTheMicrophone {
                    Spacer(minLength: Space.snug)
                    Label("The speakers will be heard in the recording", systemImage: "speaker.wave.2.fill")
                        .lineLimit(1)
                        .foregroundStyle(Signal.paused)
                        .help("The built-in microphone hears the built-in speakers, so whatever this Mac plays is recorded twice. Headphones keep it out of the take.")
                }
            }
            .menuStyle(.borderlessButton)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.8))
            // **Hidden, not removed, for a picture**: a picture has no sound and no camera, and
            // keeping the row's space stops the surface's content jumping when the mode changes.
            .opacity(coordinator.capturePurpose == .take ? 1 : 0)
            .disabled(coordinator.capturePurpose != .take)
        }
        .onChange(of: coordinator.microphone) { coordinator.refreshAudioRoute() }
        // When the surface opens, which is the moment a phone was plugged in for — the menu's
        // own `.task` does the same, and without it the notch showed yesterday's devices.
        .task {
            coordinator.refreshMicrophones()
            coordinator.refreshAudioRoute()
            coordinator.camera.refresh()
            coordinator.refreshMobileScreens()
        }
    }

    /// A device on the cable that is not offering its screen — almost always locked. Shown, not
    /// hidden: a person holding a plugged-in phone and seeing no choice for it has no way to
    /// guess why. The full sentence is the menu's, already in every language.
    private func waiting(_ name: String) -> some View {
        VStack(spacing: Space.tight) {
            Image(systemName: "lock.iphone").font(.system(size: 18))
            Text(verbatim: name).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(.white.opacity(0.45))
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.05)))
        .help(Text("\(name) is connected. Unlock it \u{2014} and tap Trust if it asks \u{2014} to record its screen."))
    }

    private func target(_ icon: String, verbatim title: String, _ start: @escaping () -> Void) -> some View {
        targetButton(icon, label: Text(verbatim: title), start)
    }

    /// A way to start. Closes the surface first: the picker that follows is a window of its own,
    /// and the surface hanging open over it would be in the way of the choice it asks for.
    private func target(_ icon: String, _ title: LocalizedStringKey, _ start: @escaping () -> Void) -> some View {
        targetButton(icon, label: Text(title), start)
    }

    private func targetButton(_ icon: String, label: Text, _ start: @escaping () -> Void) -> some View {
        Button {
            done()
            start()
        } label: {
            VStack(spacing: Space.tight) {
                Image(systemName: icon).font(.system(size: 18))
                label.font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The right wing of a live take: the level, unless there is something more urgent to say.
///
/// **A microphone that hears nothing replaces the meter**, because a meter at the bottom of its
/// track looks exactly like a quiet room.
private struct NotchSoundWing: View {
    let coordinator: RecordingCoordinator

    var body: some View {
        if coordinator.guards.microphoneHearsNothing {
            Label("The microphone hears nothing", systemImage: "mic.slash.fill")
                .labelStyle(.iconOnly)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Signal.paused)
                .frame(width: 36)
                .help("The microphone hears nothing")
        } else {
            LevelMeter(level: coordinator.guards.microphoneLevel).frame(width: 36, height: 4)
        }
    }
}

/// A take's controls, shown only while the pointer is on the surface.
private struct NotchTakeControls: View {
    let coordinator: RecordingCoordinator

    var body: some View {
        HStack(spacing: Space.snug) {
            Button { coordinator.togglePause() } label: {
                Label {
                    coordinator.isPaused ? Text("Resume") : Text("Pause")
                } icon: {
                    Image(systemName: coordinator.isPaused ? "play.fill" : "pause.fill")
                }
            }
            if case .ready(let ceiling) = coordinator.clipReadiness {
                Button { coordinator.saveClip(lastSeconds: ceiling) } label: {
                    Label("Save the last \(Int(ceiling)) seconds — the recording keeps going",
                          systemImage: "clock.arrow.circlepath")
                        .labelStyle(.iconOnly)
                }
                .help(Text("Save the last \(Int(ceiling)) seconds — the recording keeps going"))
            }
            Spacer(minLength: 0)
            Button { coordinator.stop() } label: {
                Label("Stop", systemImage: "stop.fill")
                    .padding(.horizontal, Space.regular)
                    .padding(.vertical, Space.tight)
                    .background(Capsule().fill(Signal.record))
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white)
    }
}

/// Installs the surface on the screen that has a notch and keeps it in step with the take.
///
/// **Owned by the app, not by a view**, for the reason `RecordingBarPresenter` is: a view that
/// owned an `NSPanel` would make and destroy it whenever its body re-evaluated.
@MainActor
final class NotchSurfacePresenter {
    static let shared = NotchSurfacePresenter()
    /// The setting. On by default — the whole point is that it is where a person looks first.
    static let enabledKey = "recorderLivesInNotch"

    private var panel: NotchSurfacePanel?
    private var model: NotchSurfaceModel?
    private var monitors: [Any] = []
    private weak var coordinator: RecordingCoordinator?
    private var screenObserver: NSObjectProtocol?
    /// The notched screen's AppKit frame, for turning a pointer location into the surface's space.
    private var screenFrame = PointRect(x: 0, y: 0, width: 0, height: 0)

    private init() {}

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Whether the notch is where the take is shown — and so the floating bar is not.
    var hostsTheTake: Bool { panel != nil }

    func install(coordinator: RecordingCoordinator) {
        self.coordinator = coordinator
        remove()
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                queue: .main) { [] _ in
                    Task { @MainActor in
                        guard let coordinator = NotchSurfacePresenter.shared.coordinator else { return }
                        NotchSurfacePresenter.shared.install(coordinator: coordinator)
                    }
                }
        }
        guard Self.isEnabled, let (screen, notch, frame) = Self.notchedScreen() else { return }
        let model = NotchSurfaceModel(notch: notch, screen: screen)
        let panel = NotchSurfacePanel(model: model, coordinator: coordinator, screenFrame: frame)
        panel.orderFrontRegardless()
        self.model = model
        self.panel = panel
        self.screenFrame = frame
        if coordinator.isRecording { model.send(.recordingBegan) }
        // The pointer and clicks everywhere: in other applications (global) and in this one's own
        // windows, the surface included (local). Mouse events need no permission to monitor.
        let kinds: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: kinds, handler: { event in
            let kind = event.type
            Task { @MainActor in _ = NotchSurfacePresenter.shared.handle(kind, inSurfacePanel: false) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: kinds, handler: { event in
            let inPanel = event.window === NotchSurfacePresenter.shared.panel
            return NotchSurfacePresenter.shared.handle(event.type, inSurfacePanel: inPanel) ? nil : event
        }) { monitors.append(local) }
        observeOpening()
    }

    func remove() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        panel?.orderOut(nil)
        panel = nil
        model = nil
    }

    func recordingBegan() { model?.send(.recordingBegan) }
    func recordingEnded() { model?.send(.recordingEnded) }

    /// One pointer event. Returns whether it was consumed: a click that opened the surface must
    /// not ALSO reach whatever is under the notch's wings in the menu bar.
    private func handle(_ kind: NSEvent.EventType, inSurfacePanel: Bool) -> Bool {
        guard let model else { return false }
        let location = NSEvent.mouseLocation
        let x = Double(location.x) - screenFrame.x
        let y = screenFrame.y + screenFrame.height - Double(location.y)
        let surface = model.rect
        let onSurface = x >= surface.x && x <= surface.x + surface.width
            && y >= surface.y && y <= surface.y + surface.height
        switch kind {
        case .leftMouseDown, .rightMouseDown:
            switch model.state {
            case .dormant where onSurface, .glance where onSurface:
                model.send(.clicked)
                return inSurfacePanel
            case .open where !onSurface && !inSurfacePanel:
                model.send(.clickedOutside)
            default: break
            }
        default:
            if let event = NotchSurfacePointer.event(atX: x, y: y, state: model.state,
                                                     notch: model.notch, surface: surface) {
                model.send(event)
            }
        }
        return false
    }

    /// Key while open, so escape and the pickers work; handed back as soon as it closes.
    private func observeOpening() {
        guard let model else { return }
        withObservationTracking { _ = model.state } onChange: {
            Task { @MainActor in
                let presenter = NotchSurfacePresenter.shared
                if presenter.model?.state == .open { presenter.panel?.makeKey() }
                presenter.observeOpening()
            }
        }
    }

    /// The first screen with a notch: its metrics in its own top-left points, the notch, and its
    /// AppKit frame for placing the panel. `nil` when no attached screen has one.
    private static func notchedScreen() -> (PointRect, PointRect, PointRect)? {
        for screen in NSScreen.screens {
            let frame = screen.frame
            let metrics = ScreenMetrics(
                frame: PointRect(x: 0, y: 0, width: Double(frame.width), height: Double(frame.height)),
                safeAreaTop: Double(screen.safeAreaInsets.top),
                auxiliaryLeftWidth: screen.auxiliaryTopLeftArea.map { Double($0.width) },
                auxiliaryRightWidth: screen.auxiliaryTopRightArea.map { Double($0.width) })
            if let notch = metrics.notch {
                return (metrics.frame, notch, PointRect(x: Double(frame.minX), y: Double(frame.minY),
                                                        width: Double(frame.width), height: Double(frame.height)))
            }
        }
        return nil
    }
}
