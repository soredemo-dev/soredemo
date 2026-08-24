import AppKit
import Capture
import Geometry
import SwiftUI

/// Dragging out the rectangle to record.
///
/// **The third thing a recorder has to be able to point at.** A display capture of a demo living
/// in a 600-point panel spends nine tenths of its pixels on desktop, and a window capture cannot
/// do it at all when the subject is part of a window rather than all of it. a Rust recorder, an Electron recorder and
/// an Electron recorder all offer this.
///
/// **The rectangle is remembered, which is a Rust recorder's idea and the one that matters.** Its
/// `AreaSelectionPreferences` carry `bounds` and a `screenId`, and `getLockedAreaBounds` hands
/// them back only when the same display is still attached and the rectangle is still big enough
/// to record. Somebody recording six takes of the same panel wants the same rectangle six times,
/// and dragging it out again by eye means six slightly different videos.
@MainActor
final class RegionPickerOverlay {
    static let shared = RegionPickerOverlay()

    private var panels: [NSPanel] = []
    private var monitor: Any?
    private var localMonitor: Any?
    private let state = RegionState()

    private init() {}

    /// Shows the overlay and returns the region chosen, or `nil` if it was cancelled.
    func pick() async -> CaptureSource? {
        guard panels.isEmpty else { return nil }
        state.chosen = nil
        state.remembered = RememberedRegion.load()

        return await withCheckedContinuation { continuation in
            // Cleared before it is called, for `TargetPickerOverlay`'s reason: a
            // `CheckedContinuation` resumed twice is a hard crash, and escape and a click can
            // both finish one pick.
            state.onFinish = { [weak self] source in
                guard let self, self.state.onFinish != nil else { return }
                self.state.onFinish = nil
                self.dismiss()
                continuation.resume(returning: source)
            }
            present()
        }
    }

    /// Cancels a pick that is already up — see `RecordingCoordinator.cancelPendingStart`.
    func cancel() { state.onFinish?(nil) }

    private func present() {
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
            let hosting = NSHostingView(rootView: RegionPickerView(state: state, screen: screen))
            hosting.frame = panel.contentRect(forFrameRect: panel.frame)
            panel.contentView = hosting
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        // ⎋ cancels. Two monitors because the global one sees other applications and the local
        // one sees this app's own windows, and neither sees the other's.
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

    private func dismiss() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        monitor = nil
        localMonitor = nil
    }
}

/// What the overlay is showing, shared by every screen's panel.
@MainActor
@Observable
final class RegionState {
    /// The rectangle being dragged, in the GLOBAL top-left point space `CGDisplayBounds` reports
    /// in — the same space `WindowTarget.frame` uses, so one convention covers both pickers.
    var chosen: PointRect?
    var isResolving = false
    /// The last region recorded, offered as a starting rectangle.
    var remembered: PointRect?
    var onFinish: ((CaptureSource?) -> Void)?
}

/// The last region, so the next take is the same rectangle.
enum RememberedRegion {
    private static let key = "lastRecordedRegion"

    /// **Validated on the way out, not trusted.** a Rust recorder's `getLockedAreaBounds` refuses a
    /// remembered rectangle whose display is gone or whose size is below a floor; the same two
    /// checks, plus finiteness, because this arrives from `UserDefaults` where anything can be.
    static func load() -> PointRect? {
        guard let stored = UserDefaults.standard.array(forKey: key) as? [Double],
              stored.count == 4 else { return nil }
        let rect = (x: stored[0], y: stored[1], width: stored[2], height: stored[3])
        guard rect.width >= 40, rect.height >= 40,
              [rect.x, rect.y, rect.width, rect.height].allSatisfy({ $0.isFinite }),
              // Still on a display that is attached. A rectangle remembered from a monitor since
              // unplugged would put the recording off the edge of everything.
              NSScreen.screens.contains(where: { screen in
                  let frame = GlobalRect.topLeft(of: screen)
                  return rect.x >= frame.x - 1 && rect.y >= frame.y - 1
                      && rect.x + rect.width <= frame.x + frame.width + 1
                      && rect.y + rect.height <= frame.y + frame.height + 1
              })
        else { return nil }
        return PointRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    static func save(_ rect: PointRect) {
        UserDefaults.standard.set([rect.x, rect.y, rect.width, rect.height], forKey: key)
    }
}

/// A screen's frame in the global TOP-LEFT space, which is where both pickers measure.
///
/// **AppKit's y grows upward from the primary display's bottom and `CGDisplayBounds`' grows
/// downward from its top.** The conversion is written once, here, because the last time it was
/// written twice one of the copies was wrong and the zoom lane drew several kilometres off
/// screen.
enum GlobalRect {
    static func topLeft(of screen: NSScreen) -> PointRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return PointRect(x: screen.frame.minX,
                         y: primaryHeight - screen.frame.maxY,
                         width: screen.frame.width,
                         height: screen.frame.height)
    }
}

/// One screen's worth of the overlay: drag out a rectangle, see its size, click to record.
private struct RegionPickerView: View {
    let state: RegionState
    let screen: NSScreen

    /// **Two `Double`s, not a `CGPoint`.** Rule 5 keeps CoreGraphics geometry types out of the
    /// app target entirely, and a drag's start is the one place a view is handed one — SwiftUI's
    /// `startLocation` is a `CGPoint`, so the components are taken off it and the type is never
    /// named here.
    @State private var anchor: (x: Double, y: Double)?

    /// Below this the region is not worth recording and a stray click would start one.
    /// a Rust recorder refuses a remembered rectangle under a minimum for the same reason.
    private static let minimumSide: Double = 40

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                // The dim, light enough to still recognise what is underneath — the same value
                // the window picker uses, because they are the same decision.
                Color.black.opacity(0.35)

                if let box = localBox() {
                    // **A hole, not a highlight.** The region is what will be recorded, so it is
                    // shown at full brightness with the dim cut away from it; brightening a
                    // rectangle over a dimmed screen would still be a dimmed rectangle.
                    Rectangle()
                        .fill(.white)
                        .frame(width: box.width, height: box.height)
                        .offset(x: box.x, y: box.y)
                        .blendMode(.destinationOut)

                    Rectangle()
                        .strokeBorder(.white.opacity(0.9), lineWidth: 1.5)
                        .frame(width: box.width, height: box.height)
                        .offset(x: box.x, y: box.y)

                    RegionSizeLabel(width: box.width, height: box.height,
                                    isResolving: state.isResolving)
                        .offset(x: box.x, y: max(box.y - 30, 4))
                }
            }
            .compositingGroup()
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if anchor == nil {
                            anchor = (Double(value.startLocation.x), Double(value.startLocation.y))
                        }
                        guard let anchor else { return }
                        state.chosen = global(from: anchor,
                                              toX: Double(value.location.x),
                                              toY: Double(value.location.y))
                    }
                    .onEnded { value in
                        defer { anchor = nil }
                        guard let anchor,
                              let rect = global(from: anchor,
                                                toX: Double(value.location.x),
                                                toY: Double(value.location.y)),
                              rect.width >= Self.minimumSide, rect.height >= Self.minimumSide
                        else {
                            // A click rather than a drag. Not a cancel — somebody who clicked by
                            // accident should still have the overlay, and \u{238B} is the way out.
                            state.chosen = state.remembered
                            return
                        }
                        state.chosen = rect
                        choose(rect)
                    }
            )
            .onAppear {
                // The remembered rectangle is shown straight away, so a second take starts from
                // the first take's frame rather than from an empty screen.
                if state.chosen == nil { state.chosen = state.remembered }
            }
            .onTapGesture {
                // Tapping with a remembered rectangle up records it — the "same again" path,
                // which is the whole reason the rectangle is remembered.
                guard !state.isResolving, let rect = state.chosen,
                      rect.width >= Self.minimumSide, rect.height >= Self.minimumSide else { return }
                choose(rect)
            }
            .onChange(of: proxy.size) { }
        }
    }

    private func choose(_ rect: PointRect) {
        state.isResolving = true
        RememberedRegion.save(rect)
        Task { @MainActor in
            let source = await RegionTargets.source(for: rect)
            state.onFinish?(source)
        }
    }

    /// The dragged rectangle in the global top-left space, normalised so a drag in any direction
    /// gives a positive size.
    private func global(from start: (x: Double, y: Double),
                        toX endX: Double, toY endY: Double) -> PointRect? {
        let frame = GlobalRect.topLeft(of: screen)
        let x0 = min(start.x, endX), x1 = max(start.x, endX)
        let y0 = min(start.y, endY), y1 = max(start.y, endY)
        guard x1 > x0 || y1 > y0 else { return nil }
        return PointRect(x: frame.x + x0, y: frame.y + y0, width: x1 - x0, height: y1 - y0)
    }

    /// The chosen rectangle in THIS panel's own coordinates, or `nil` when it is on another
    /// screen — which is how a two-display drag shows on one and not the other.
    private func localBox() -> (x: Double, y: Double, width: Double, height: Double)? {
        guard let chosen = state.chosen else { return nil }
        let frame = GlobalRect.topLeft(of: screen)
        let x = chosen.x - frame.x
        let y = chosen.y - frame.y
        guard x + chosen.width > 0, y + chosen.height > 0,
              x < frame.width, y < frame.height else { return nil }
        return (x, y, chosen.width, chosen.height)
    }
}

/// The size of the rectangle, where a person is already looking.
private struct RegionSizeLabel: View {
    let width: Double
    let height: Double
    let isResolving: Bool

    var body: some View {
        HStack(spacing: Space.snug) {
            Text("\(Int(width.rounded()))\u{00D7}\(Int(height.rounded()))")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
            if isResolving {
                ProgressView().controlSize(.small)
            } else {
                Text("\u{238B}").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Space.snug)
        .padding(.vertical, Space.tight)
        .glassSurface(radius: 8)
        .allowsHitTesting(false)
    }
}
