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
    private var popover: NSPopover?
    private var coordinator: RecordingCoordinator?
    private var refresh: Timer?

    /// AppKit's own key for a status item's remembered position, and the name it is keyed on.
    private static let autosaveName = "soredemo.recorder"
    private static let positionKey = "NSStatusItem Preferred Position \(autosaveName)"
    private static let seededKey = "statusItemPositionSeeded"

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

    @objc private func togglePanel() {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = item?.button, let coordinator else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        // The panel sizes itself; `contentSize` is a first guess AppKit corrects once the
        // hosting view reports its own.
        popover.contentSize = NSSize(width: 292, height: 340)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarRecorderPanel(coordinator: coordinator))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        self.popover = popover
    }
}
