import AVFoundation
import AppKit
import Capture
import Render
import SwiftUI

/// The camera, on screen, while the recording is running.
///
/// **A recorder that records your face and does not show it to you is asking you to perform
/// blind.** Every reference recorder that offers a camera puts a self-view on the screen —
/// you are looking at your own framing the whole time, not finding out afterwards that you
/// were off-centre for four minutes.
///
/// **It is not in the recording, and that is free rather than arranged.** `CaptureSource.filter`
/// excludes this whole application from a display capture — the fix for the floating recording
/// bar being burnt into the picture — so a panel this app owns is already invisible to the
/// stream. A window capture never sees it either, because it captures one other window. The
/// camera reaches the finished video through `CameraComposition`, from its own file, at render
/// time; what is on screen now is a monitor, not a source.
///
/// **What you move here is what the editor opens with.** The panel writes its position and
/// shape back as a `CameraOverlayStyle` in fractions of the screen, which is the same value the
/// stage composites with — so dragging the self-view to the left during a recording means the
/// camera is on the left when the editor opens, rather than being placed twice.
@MainActor
final class CameraSelfView {
    static let shared = CameraSelfView()

    private var panel: NSPanel?
    private var container: ShapedCameraView?
    /// Set by the coordinator so a drag can report where the camera ended up.
    var onStyleChange: ((CameraOverlayStyle) -> Void)?

    private init() {}

    /// Shows the self-view for `recorder`, laid out where `style` says.
    func show(recorder: CameraRecorder, style: CameraOverlayStyle) {
        hide()
        guard let layer = recorder.previewLayer(),
              let screen = NSScreen.main else { return }

        let size = Self.panelSize(for: style, on: screen)
        let origin = Self.origin(for: style, size: size, on: screen)
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        // **Above ordinary windows, below the menu bar's own panels.** It has to sit over the
        // thing being demonstrated — that is the point of it — and under the recorder's controls.
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let view = ShapedCameraView(previewLayer: layer, style: style)
        view.frame = NSRect(origin: .zero, size: size)
        view.autoresizingMask = [.width, .height]
        view.onMoved = { [weak self] in self?.reportStyle() }
        view.onStyleChosen = { [weak self] newStyle in self?.restyle(newStyle) }
        panel.contentView = view

        panel.orderFrontRegardless()
        self.panel = panel
        self.container = view
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        container = nil
    }

    /// Re-lays the panel for something chosen from its menu.
    ///
    /// **A shape or a size keeps the centre; a position moves it.** Resizing about the corner
    /// would walk the camera across the screen every time somebody tried a size — and a position
    /// preset that kept the centre would do nothing at all, which is the opposite failure.
    private func restyle(_ style: CameraOverlayStyle) {
        guard let panel, let container, let screen = panel.screen ?? NSScreen.main else { return }
        let size = Self.panelSize(for: style, on: screen)
        let moved = style.x != container.style.x || style.y != container.style.y
        let origin = moved
            ? Self.origin(for: style, size: size, on: screen)
            : NSPoint(x: panel.frame.midX - size.width / 2,
                      y: panel.frame.midY - size.height / 2)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        container.style = style
        reportStyle()
    }

    /// Turns where the panel IS into the style the stage will composite with.
    private func reportStyle() {
        guard let panel, let container,
              let screen = panel.screen ?? NSScreen.main else { return }
        let frame = screen.frame
        guard frame.width > 0, frame.height > 0 else { return }
        let centreX = (panel.frame.midX - frame.minX) / frame.width
        // AppKit's y grows upward and so does `CameraOverlayStyle.y`, so this one needs no flip
        // — unlike every conversion in `TargetPickerOverlay`, which is measuring against
        // `CGDisplayBounds`' top-left space.
        let centreY = (panel.frame.midY - frame.minY) / frame.height
        let width = panel.frame.width / frame.width
        let moved = container.style.changing(widthFraction: width, x: centreX, y: centreY)
        container.style = moved
        onStyleChange?(moved)
    }

    /// The panel's size in points, from the style's fraction of the screen it is on.
    ///
    /// A circle is square; a rectangle takes the camera's own 16:9. The stage applies the same
    /// rule in `CameraOverlayStyle.rect(inOutputWidth:outputHeight:sourceAspect:)`, so the
    /// self-view is the same shape as the thing that gets rendered.
    private static func panelSize(for style: CameraOverlayStyle, on screen: NSScreen) -> NSSize {
        let width = max(screen.frame.width * style.widthFraction, 120)
        let height = style.shape == .circle ? width : width * 9 / 16
        return NSSize(width: width.rounded(), height: height.rounded())
    }

    private static func origin(for style: CameraOverlayStyle, size: NSSize,
                               on screen: NSScreen) -> NSPoint {
        let frame = screen.visibleFrame
        let x = frame.minX + frame.width * style.x - size.width / 2
        let y = frame.minY + frame.height * style.y - size.height / 2
        return NSPoint(x: min(max(x, frame.minX), frame.maxX - size.width),
                       y: min(max(y, frame.minY), frame.maxY - size.height))
    }
}

/// The camera picture, in the shape the stage will draw it, and draggable.
///
/// **AppKit rather than SwiftUI.** The content is a `CALayer` the capture session owns, and
/// hosting one inside a SwiftUI hierarchy to then drag the window it is in is three layers of
/// indirection over `mouseDragged`.
private final class ShapedCameraView: NSView {
    var onMoved: (() -> Void)?
    var onStyleChosen: ((CameraOverlayStyle) -> Void)?

    var style: CameraOverlayStyle {
        didSet { applyStyle() }
    }

    private let preview: AVCaptureVideoPreviewLayer
    private var dragOrigin: NSPoint?
    private var pressOrigin: NSPoint?
    private var isDragging = false

    init(previewLayer: AVCaptureVideoPreviewLayer, style: CameraOverlayStyle) {
        self.preview = previewLayer
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(preview)
        applyStyle()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not in a nib") }

    override func layout() {
        super.layout()
        // No implicit animation: the layer is resized on every window drag, and CoreAnimation's
        // default quarter-second would make the picture lag the frame it is inside.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.frame = bounds
        applyStyle()
        CATransaction.commit()
    }

    private func applyStyle() {
        guard let layer else { return }
        let radius: Double
        switch style.shape {
        case .circle: radius = bounds.width / 2
        case .rounded: radius = bounds.width * style.cornerFraction
        case .square: radius = 0
        }
        preview.cornerRadius = radius
        preview.cornerCurve = .continuous
        preview.masksToBounds = true
        // **Mirrored to match the stage.** A self-view that is not mirrored is the one that
        // looks wrong to the person in front of it, which is why every video-call app mirrors —
        // and `CameraOverlayStyle.isMirrored` already defaults to true for the render.
        preview.connection?.automaticallyAdjustsVideoMirroring = false
        preview.connection?.isVideoMirrored = style.isMirrored
        layer.borderWidth = 0
        layer.shadowOpacity = Float(style.shadowOpacity)
        layer.shadowRadius = 12
        layer.shadowOffset = .zero
        preview.borderWidth = style.borderOpacity > 0 ? 2 : 0
        preview.borderColor = NSColor.white.withAlphaComponent(style.borderOpacity).cgColor
    }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = NSEvent.mouseLocation
        pressOrigin = dragOrigin
        isDragging = false
    }

    /// **The window is moved by its frame, not by the drag's translation.** `NSEvent`'s
    /// `deltaX`/`deltaY` are per-event and lose whatever the run loop coalesced; the difference
    /// between two absolute mouse locations cannot.
    ///
    /// **A threshold before anything moves.** Without one, a press that wandered a point — which
    /// most presses do — nudged the camera, and since the position is persisted, the nudge was
    /// permanent. an Electron recorder's overlay uses a 6px threshold for the same reason; this is the same
    /// number because the reason is the same and the hand is the same.
    ///
    /// **Clamped to the screen on every frame, not only when the panel is placed.** Dragging
    /// past an edge otherwise walks the camera off the display, where it cannot be grabbed back
    /// — and the position it writes is what the export composites with. an Electron recorder clamps inside
    /// its `requestAnimationFrame` for this; here every drag event does it.
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragOrigin, let press = pressOrigin, let window else { return }
        let now = NSEvent.mouseLocation
        if !isDragging {
            guard hypot(now.x - press.x, now.y - press.y) >= Self.dragThreshold else { return }
            isDragging = true
        }
        var frame = window.frame
        frame.origin.x += now.x - start.x
        frame.origin.y += now.y - start.y
        if let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, visible.minX),
                                 visible.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, visible.minY),
                                 visible.maxY - frame.height)
        }
        window.setFrameOrigin(frame.origin)
        dragOrigin = now
    }

    static let dragThreshold: Double = 6

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
        pressOrigin = nil
        // Only a real drag reports. A click that never crossed the threshold moved nothing, and
        // writing the position back would round-trip it through the screen-fraction conversion
        // for no reason.
        if isDragging { onMoved?() }
        isDragging = false
    }

    /// Shape and size, where a person looking at the camera would look for them.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for shape in CameraOverlayStyle.Shape.allCases {
            let item = NSMenuItem(title: NSLocalizedString(shape.displayName, comment: ""),
                                  action: #selector(chooseShape(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = shape.rawValue
            item.state = shape == style.shape ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (name, fraction) in Self.sizes {
            let item = NSMenuItem(title: NSLocalizedString(name, comment: ""),
                                  action: #selector(chooseSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = fraction
            // Compared with a tolerance, because a drag writes a continuous width and no size
            // in this list would ever be exactly equal to it again.
            item.state = abs(style.widthFraction - fraction) < 0.01 ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        // The same nine the editor's grid offers, so a person who arranges the camera here and
        // a person who arranges it afterwards are using one vocabulary.
        let positions = NSMenu()
        for position in CameraOverlayStyle.Position.allCases {
            let item = NSMenuItem(title: NSLocalizedString(position.displayName, comment: ""),
                                  action: #selector(choosePosition(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = position.rawValue
            positions.addItem(item)
        }
        let positionItem = NSMenuItem(title: NSLocalizedString("Position", comment: ""),
                                      action: nil, keyEquivalent: "")
        positionItem.submenu = positions
        menu.addItem(positionItem)
        menu.addItem(.separator())
        let mirror = NSMenuItem(title: NSLocalizedString("Mirror", comment: ""),
                                action: #selector(toggleMirror), keyEquivalent: "")
        mirror.target = self
        mirror.state = style.isMirrored ? .on : .off
        menu.addItem(mirror)
        return menu
    }

    static let sizes: [(String, Double)] = [("Small", 0.12), ("Medium", 0.16), ("Large", 0.22)]

    @objc private func chooseShape(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let shape = CameraOverlayStyle.Shape(rawValue: raw) else { return }
        onStyleChosen?(style.changing(shape: shape))
    }

    @objc private func chooseSize(_ sender: NSMenuItem) {
        guard let fraction = sender.representedObject as? Double else { return }
        onStyleChosen?(style.changing(widthFraction: fraction))
    }

    @objc private func choosePosition(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let position = CameraOverlayStyle.Position(rawValue: raw) else { return }
        onStyleChosen?(style.placed(at: position))
    }

    @objc private func toggleMirror() {
        onStyleChosen?(style.changing(isMirrored: !style.isMirrored))
    }
}
