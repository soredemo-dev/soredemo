import AppKit
import Geometry

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
            // `_ =`: a global monitor sees another application's event and cannot consume it,
            // so whether it would have been consumed has nowhere to go.
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

    /// The live take's daruma on screen, global points y up — where the countdown's lands. `nil`
    /// when the notch does not host the take.
    func liveMarkOnScreen() -> (x: Double, y: Double)? {
        guard let model, panel != nil else { return nil }
        let mark = NotchSurfaceLayout.liveMarkCentre(notch: model.notch, screen: model.screen)
        return (screenFrame.x + mark.x, screenFrame.y + screenFrame.height - mark.y)
    }
    /// How long a finished take shows before the notch settles: the menu bar's painted eye is
    /// held as long, so the two say "done" together.
    static let finishedSeconds = 2.6

    func recordingEnded() {
        model?.send(.recordingEnded)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.finishedSeconds) { [weak self] in
            MainActor.assumeIsolated { self?.model?.send(.settled) }
        }
    }

    /// One pointer event. Returns whether it was consumed: a click that opened the surface must
    /// not ALSO reach whatever is under the notch's wings in the menu bar.
    private func handle(_ kind: NSEvent.EventType, inSurfacePanel: Bool) -> Bool {
        guard let model else { return false }
        let location = NSEvent.mouseLocation
        let x = Double(location.x) - screenFrame.x
        let y = screenFrame.y + screenFrame.height - Double(location.y)
        let surface = model.rect
        let onSurface = NotchSurfacePointer.isInside(x: x, y: y, of: surface)
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
