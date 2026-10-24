import AppKit
import Capture
import Geometry
import SwiftUI

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
        let fromTop = isFlipped ? Double(local.y) : Double(bounds.height) - Double(local.y)
        return NotchSurfacePointer.isInside(x: Double(local.x), y: fromTop, of: surface)
            ? super.hitTest(point) : nil
    }

    /// The first click on the notch counts even though this app is not frontmost — which it
    /// never is while somebody is using the notch.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
