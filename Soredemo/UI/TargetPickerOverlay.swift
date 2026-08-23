import AppKit
import Capture
import Geometry
import SwiftUI

/// Choosing what to record by pointing at it.
///
/// **Apple's picker tells you the least a picker can.** `SCContentSharingPicker` lists windows
/// by name in a popover: to find the one you mean you read a list, and to know how big the
/// recording will be you find out afterwards. ScreenKite dims the desktop, highlights whatever
/// is under the pointer, and puts a card on it with the application's name and the size — you
/// point at the thing itself. That is the picker this is.
///
/// **What is NOT on the card: the window's title.** ScreenKite's shows it — "Spotify" over
/// "Spotify Premium". A window title carries whatever is open in it: a document name, a
/// customer's name, a URL with a token in it. This app's rule is that it does not read ambient
/// user content, and `noAppSourceReadsUserContent` names `SCWindow.title` as a gap its scan
/// cannot catch textually. A gap is a place to be careful, not a permission.
@MainActor
final class TargetPickerOverlay {
    static let shared = TargetPickerOverlay()
    private var panels: [NSPanel] = []
    private var refresh: Task<Void, Never>?
    private var monitor: Any?
    private let state = PickerState()

    private init() {}

    /// Shows the overlay and returns what was chosen, or `nil` if it was cancelled.
    func pick() async -> CaptureSource? {
        guard panels.isEmpty else { return nil }
        state.targets = await WindowTargets.onScreen()
        state.chosen = nil

        return await withCheckedContinuation { continuation in
            // **Cleared before it is called, so it can only be called once.** A
            // `CheckedContinuation` resumed twice is a hard crash, and there are two ways in:
            // press \u{238B} while a chosen window is still being resolved and both the escape
            // monitor and the resolve task finish this pick, or let \u{238B} arrive at the global
            // and the local monitor. Neither is exotic — the resolve is a system round trip a
            // person waits through — and the app disappearing mid-pick is what it looked like.
            state.onFinish = { [weak self] source in
                guard let self, self.state.onFinish != nil else { return }
                self.state.onFinish = nil
                self.dismiss()
                continuation.resume(returning: source)
            }
            present()
        }
    }

    /// **The window list is re-read while the overlay is up, not frozen when it opens.**
    /// Measured with a dump from inside the app: `SCShareableContent.windows` really is ordered
    /// front to back and really does follow the active application, so the hit test — first
    /// match wins — was right. What was wrong is that it was testing against a list captured
    /// before the overlay appeared. Bring another window forward while pointing (\u{2318}\u{21E5}
    /// still works over an overlay) and every point in the overlap kept answering with the
    /// window that used to be on top — Claude in front of Spotify, and the card said Spotify.
    ///
    /// Windows also move, close and open while a person is deciding, and a picker that shows
    /// where a window WAS is worse than one that shows nothing.
    ///
    /// Polled rather than observed: there is no notification for z-order, and 400ms is far below
    /// the time it takes to bring an app forward and move the pointer back.
    private func startRefreshing() {
        refresh = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, !self.panels.isEmpty, !Task.isCancelled else { return }
                let fresh = await WindowTargets.onScreen()
                guard !Task.isCancelled else { return }
                self.state.targets = fresh
            }
        }
    }

    private func present() {
        // **One panel per screen.** A single panel sized to the union of every display is one
        // rectangle the window server has to composite across displays with different scales;
        // a panel per screen is what every overlay on this platform does.
        for screen in NSScreen.screens {
            let panel = NSPanel(contentRect: screen.frame,
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = false
            let hosting = NSHostingView(rootView: TargetPickerView(state: state, screen: screen))
            hosting.frame = panel.contentRect(forFrameRect: panel.frame)
            panel.contentView = hosting
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        startRefreshing()
        // ⎋ cancels. A local monitor rather than a `.keyboardShortcut`, because these panels are
        // non-activating and never become key — the same reason the recording bar's ⎋ did
        // nothing until the shortcut became a global hot key.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in self?.state.onFinish?(nil) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            Task { @MainActor in self?.state.onFinish?(nil) }
            return nil
        }
    }

    private var localMonitor: Any?

    private func dismiss() {
        refresh?.cancel()
        refresh = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        monitor = nil
        localMonitor = nil
    }
}

/// What the overlay is showing. Shared by every screen's panel, so the highlight follows the
/// pointer across displays rather than each panel keeping its own idea of where it is.
@MainActor
@Observable
final class PickerState {
    var targets: [WindowTarget] = []
    var chosen: WindowTarget?
    /// Set while a chosen window is being turned into a `CaptureSource`, which re-queries the
    /// system and can take a moment.
    var isResolving = false
    var onFinish: ((CaptureSource?) -> Void)?
}

/// One screen's worth of the overlay.
private struct TargetPickerView: View {
    let state: PickerState
    let screen: NSScreen

    /// The pointer, in this panel's own coordinates.
    @State private var local: (x: Double, y: Double) = (0, 0)
    @State private var hovered: WindowTarget?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The dim. Light enough that a person can still recognise what they are pointing at
            // — a picker that hides the screen is a picker you have to guess in.
            Color.black.opacity(0.35)

            if let target = hovered {
                let box = localFrame(of: target)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(0.08))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                    }
                    .frame(width: box.width, height: box.height)
                    .offset(x: box.x, y: box.y)
                    .allowsHitTesting(false)

                TargetCard(target: target, isResolving: state.isResolving)
                    .position(x: box.x + box.width / 2, y: box.y + box.height / 2)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            guard case .active(let point) = phase else { hovered = nil; return }
            local = (Double(point.x), Double(point.y))
            rehighlight()
        }
        // **The list can change while the pointer is still.** Bringing a window forward without
        // moving the mouse is exactly the case that started this, and a highlight that only
        // updates on movement would answer with the old window until the pointer twitched.
        .onChange(of: state.targets) { rehighlight() }
        .onTapGesture {
            guard let hovered, !state.isResolving else { return }
            state.isResolving = true
            Task {
                let source = await WindowTargets.source(for: hovered)
                state.onFinish?(source)
            }
        }
    }

    private func rehighlight() {
        hovered = WindowTargets.target(at: globalX(local.x), y: globalY(local.y),
                                       in: state.targets)
    }

    /// **The panel's y runs down and the screen's runs up.** A panel covering `screen.frame` has
    /// its origin at the frame's bottom-left in AppKit terms, while SwiftUI lays out downward
    /// from the top — and `WindowTarget.frame` is in the global TOP-LEFT space `CGDisplayBounds`
    /// reports. Three conventions; the two conversions are here and nowhere else.
    private func globalX(_ x: Double) -> Double { Double(screen.frame.minX) + x }

    private func globalY(_ y: Double) -> Double {
        // The primary display's top is global y = 0 and AppKit's y grows upward from the
        // primary display's BOTTOM, so a screen's top in global coordinates is the primary
        // display's height less this screen's maximum y.
        let primaryHeight = Double(NSScreen.screens.first?.frame.height ?? 0)
        return primaryHeight - Double(screen.frame.maxY) + y
    }

    private func localFrame(of target: WindowTarget)
    -> (x: Double, y: Double, width: Double, height: Double) {
        let primaryHeight = Double(NSScreen.screens.first?.frame.height ?? 0)
        return (target.frame.x - Double(screen.frame.minX),
                target.frame.y - (primaryHeight - Double(screen.frame.maxY)),
                target.frame.width, target.frame.height)
    }
}

/// The card over the highlighted window: its application's icon, its name, and its size.
private struct TargetCard: View {
    let target: WindowTarget
    let isResolving: Bool

    var body: some View {
        VStack(spacing: Space.snug) {
            if let icon = Self.icon(forBundleIdentifier: target.bundleIdentifier) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 52, height: 52)
            }
            Text(target.applicationName)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
            Text(target.sizeDescription)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.65))
            if isResolving {
                ProgressView().controlSize(.small)
            } else {
                Text("Click to record \u{00B7} \u{238B} to cancel")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, Space.section)
        .padding(.vertical, Space.roomy)
        .glassSurface(radius: 18)
    }

    /// The application's icon from its bundle identifier.
    ///
    /// **By identifier, through the workspace** — not by reading the window. `NSWorkspace` maps
    /// a bundle identifier to an application URL, and an icon is a property of the app rather
    /// than of anything a person has open in it.
    static func icon(forBundleIdentifier identifier: String?) -> NSImage? {
        guard let identifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
