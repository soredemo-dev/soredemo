import AppKit
import Capture
import Geometry

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
