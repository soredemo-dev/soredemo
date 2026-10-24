import AppKit
import Capture
import Geometry
import SwiftUI

/// The bar that floats over the screen while it is being recorded.
///
/// **A panel, not a window, and every flag here is load-bearing.** `.nonactivatingPanel` so
/// clicking Stop does not pull focus away from whatever is being demonstrated — a bar that stole
/// focus would change the thing it is recording. `.canJoinAllSpaces` so it survives a Space
/// switch mid-recording. `.floating` so it stays above the app being shown. These are the flags
/// any capture toolbar on macOS ends up with, for the same reasons.
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

    /// Never main, so the app behind it keeps its main window.
    ///
    /// **`canBecomeKey` is true and its reason has gone.** It was for ⎋ and ⌘.; ⎋ left with
    /// `5fffe28`, when the stop key became system-wide, and nothing on the bar listens for a key
    /// now. Left as it is rather than changed unmeasured: whether a click on Pause makes the bar
    /// key and takes the keyboard from the app being recorded is the open question in
    /// `docs/design/2026-10-24-splitting-the-recording-bar.md`, and focus is the one thing this
    /// bar must not get wrong.
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
