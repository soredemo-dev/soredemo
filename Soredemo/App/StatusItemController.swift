import AppKit
import SwiftUI

/// The menu bar item, owned rather than declared.
///
/// **`MenuBarExtra` gives no control over where the item sits, and on a Mac with a notch that
/// decides whether it exists.** When the menu bar runs out of room macOS hides extras from the
/// LEFT — the end furthest from the clock — and a person whose bar is full simply does not see
/// the app they just launched. SwiftUI's scene exposes no `autosaveName`, no length, and no
/// position, so there is nothing to do about it from there.
///
/// An `NSStatusItem` has all three. `autosaveName` is the important one: it is what makes a
/// ⌘-drag stick, so a person who moves this item nearer the clock finds it there next launch
/// instead of moving it every time.
///
/// **`preferredPosition` is seeded once, and it is a defaults key AppKit writes rather than a
/// public API.** The key is in this app's own defaults domain and AppKit reads it back for the
/// same purpose; seeding it on first run is the difference between landing at the far left, where
/// a full bar hides it, and landing beside the system items. It is seeded ONCE — a person who
/// then moves the item has decided, and overwriting their position on every launch would be the
/// producer-value rule broken in the smallest possible way.
@MainActor
final class StatusItemController: NSObject {
    static let shared = StatusItemController()

    private var item: NSStatusItem?
    private var bridge: NSView?
    private var panel: NSPanel?
    private var dismissMonitor: Any?
    private var keyMonitor: Any?
    private var coordinator: RecordingCoordinator?
    private var refresh: Timer?

    /// AppKit's own key for a status item's remembered position, and the name it is keyed on.
    private static let autosaveName = "soredemo.recorder"
    private static let positionKey = "NSStatusItem Preferred Position \(autosaveName)"
    private static let seededKey = "statusItemPositionSeeded"
    /// What macOS rounds a menu bar window to. Not `Glass.barRadius`, which is the recording
    /// bar's pill: this pane is meant to be indistinguishable from a system one.
    private static let cornerRadius: Double = 10

    private override init() { super.init() }

    func install(coordinator: RecordingCoordinator) {
        guard item == nil else { return }
        self.coordinator = coordinator
        seedPreferredPositionOnce()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = Self.autosaveName
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.button?.toolTip = "Soredemo"
        self.item = item
        updateIcon()

        // **The one view in this app that is alive from launch to quit.** `openWindow` is a
        // SwiftUI environment action and nothing in AppKit holds one, so the editor cannot be
        // opened from here when a recording finishes unless some view is around to do it. Zero
        // size and hit testing off — it is behaviour, not a picture; the mark above is the
        // picture. See `MenuBarWindowBridge`, which was dead code from the day `MenuBarExtra`
        // was removed until it was hung here.
        let bridge = NSHostingView(rootView: MenuBarWindowBridge(coordinator: coordinator))
        bridge.frame = NSRect(origin: .zero, size: .zero)
        item.button?.addSubview(bridge)
        self.bridge = bridge

        // **Polled, and only a second.** The icon has three states and they change when a
        // recording starts, pauses or stops — none of which is frequent, and a second late is
        // invisible on a menu bar. An observation-tracking loop would be exact and would also be
        // a retain cycle waiting to be written wrong for a picture that changes three times an
        // hour.
        refresh = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateIcon() }
        }
    }

    /// **A number small enough to sit beside the system items.** AppKit orders third-party items
    /// by this value, ascending from the right; new items with no value land far to the left,
    /// which is exactly where a full menu bar hides them first.
    private func seedPreferredPositionOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.seededKey) else { return }
        defaults.set(1, forKey: Self.positionKey)
        defaults.set(true, forKey: Self.seededKey)
    }

    private func updateIcon() {
        guard let button = item?.button, let coordinator else { return }
        let symbol: String? = coordinator.isRecording
            ? (coordinator.isPaused ? "pause.circle.fill" : "record.circle.fill")
            : nil
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription:
                                    coordinator.isPaused ? "Paused" : "Recording")
        } else {
            // The logomark as a template image, so the system tints it for a light or dark bar.
            let mark = NSImage(named: "LogomarkTemplate")
            mark?.isTemplate = true
            mark?.size = NSSize(width: 18, height: 18)
            button.image = mark
        }
        button.image?.isTemplate = true
    }

    /// **A borderless panel dressed as `MenuBarExtra`'s window style**, kept while the item
    /// itself stays an `NSStatusItem` for the position control that scene does not give.
    ///
    /// Two wrong answers came before this one. An `NSPopover` draws its own opaque background
    /// and an arrow at the button and neither can be turned off, so the content — designed for a
    /// chromeless floating pane — came out with two backgrounds and a spike. Then the panel drew
    /// the app's own `glassSurface`, which is pinned dark: correct for the recording bar, which
    /// floats over a person's screen, and wrong here, where a dark pane hanging off a light menu
    /// bar is the thing that looks broken.
    ///
    /// So the surface is `NSVisualEffectView` with the `.menu` material — literally what the
    /// system draws behind a menu bar window, in the system's own light or dark. The content
    /// draws nothing of its own and fills it edge to edge.
    @objc private func togglePanel() {
        if panel != nil {
            dismissPanel()
            return
        }
        guard let button = item?.button, let buttonWindow = button.window,
              let coordinator else { return }

        let hosting = NSHostingView(rootView: MenuBarRecorderPanel(coordinator: coordinator))
        // **Floored, because a fitting size of zero is a panel nobody can see.** `fittingSize`
        // is measured before the view has been in a window, and a SwiftUI hierarchy that has not
        // laid out yet can report nothing at all. The width is fixed by the panel itself; the
        // floor on the height is what stops a bad measurement becoming an invisible menu.
        let measured = hosting.fittingSize
        let size = NSSize(width: max(measured.width, 292), height: max(measured.height, 240))
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        // `.popUpMenu`, which is where a menu bar item's own window sits: above ordinary
        // floating windows and below a screen saver.
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let surface = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        surface.material = .menu
        surface.blendingMode = .behindWindow
        // `.active`, not `.followsWindowActiveState`: this is a non-activating panel, so the
        // window is never key and the material would render in its inactive, flatter form for
        // the whole time it is up.
        surface.state = .active
        surface.wantsLayer = true
        surface.layer?.cornerRadius = Self.cornerRadius
        surface.layer?.cornerCurve = .continuous
        surface.layer?.masksToBounds = true
        hosting.frame = surface.bounds
        hosting.autoresizingMask = [.width, .height]
        surface.addSubview(hosting)
        panel.contentView = surface

        // Under the button and right-aligned to it, which is where every menu bar panel on this
        // system opens — and clamped to the screen, because an item near the right edge would
        // otherwise put its panel half off it.
        let buttonInScreen = buttonWindow.convertToScreen(button.frame)
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let x = min(max(buttonInScreen.maxX - size.width, visible.minX + 8),
                    visible.maxX - size.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: buttonInScreen.minY - size.height - 6))
        panel.orderFrontRegardless()
        self.panel = panel
        button.highlight(true)
        installDismissMonitors()
    }

    /// **Closed by a click anywhere else, and by ⎋.** A popover does this for free; a borderless
    /// panel does not, and a menu that stays open after you click past it is the thing that
    /// makes one feel broken. The global monitor catches clicks in other applications, the local
    /// one catches clicks in this app's own windows — neither sees the other's.
    private func installDismissMonitors() {
        dismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.dismissPanel() }
            }
        keyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                if event.type == .keyDown {
                    guard event.keyCode == 53 else { return event }
                    Task { @MainActor in self?.dismissPanel() }
                    return nil
                }
                // A click inside the panel itself is the person using it.
                if event.window === self?.panel { return event }
                Task { @MainActor in self?.dismissPanel() }
                return event
            }
    }

    private func dismissPanel() {
        panel?.orderOut(nil)
        panel = nil
        item?.button?.highlight(false)
        if let dismissMonitor { NSEvent.removeMonitor(dismissMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        dismissMonitor = nil
        keyMonitor = nil
    }
}
