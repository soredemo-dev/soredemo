import AppKit
import Capture
import Geometry
import SwiftUI

/// Dragging out the rectangle to record.
///
/// **The third thing a recorder has to be able to point at.** A display capture of a demo living
/// in a 600-point panel spends nine tenths of its pixels on desktop, and a window capture cannot
/// do it at all when the subject is part of a window rather than all of it.
///
///
/// **The rectangle is remembered, and that is the part that matters.** A
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

    /// **Validated on the way out, not trusted.** A remembered rectangle must be refused when
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
        topLeft(x: Double(screen.frame.minX), maxY: Double(screen.frame.maxY),
                width: Double(screen.frame.width), height: Double(screen.frame.height))
    }

    /// A WINDOW's frame in the same space. **The same conversion, reached through the same
    /// function**, for the reason this type's own comment gives: the last time it was written
    /// twice one of the copies was wrong.
    static func topLeft(of window: NSWindow) -> PointRect {
        topLeft(x: Double(window.frame.minX), maxY: Double(window.frame.maxY),
                width: Double(window.frame.width), height: Double(window.frame.height))
    }

    /// The conversion itself, in bare numbers so both callers above share one line of
    /// arithmetic rather than two that look alike.
    private static func topLeft(x: Double, maxY: Double,
                                width: Double, height: Double) -> PointRect {
        let primaryHeight = Double(NSScreen.screens.first?.frame.height ?? 0)
        return PointRect(x: x, y: primaryHeight - maxY, width: width, height: height)
    }
}

/// One screen's worth of the overlay.
///
/// **Drawing the rectangle and starting the recording are two acts, not one.** The first version
/// started recording the moment the drag ended, which meant the rectangle could only ever be the
/// one your hand happened to leave — and a rectangle drawn by eye around a panel is almost never
/// the rectangle you wanted on the first try. So a drag proposes, handles adjust, and a button
/// commits.
private struct RegionPickerView: View {
    let state: RegionState
    let screen: NSScreen

    /// Where a drag began, and what it is doing — drawing a new rectangle, moving the one that
    /// is there, or pulling one of its edges.
    @State private var gesture: RegionGesture?

    /// Below this the region is not worth recording and a stray click would start one.
    private static let minimumSide: Double = 40
    /// How close to an edge counts as grabbing it rather than moving the whole rectangle.
    private static let handleReach: Double = 14

    var body: some View {
        ZStack(alignment: .topLeading) {
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

                // The four corners, so the rectangle looks adjustable rather than final.
                ForEach(RegionEdge.corners, id: \.name) { corner in
                    RegionHandle()
                        .offset(x: box.x + corner.x * box.width - 4,
                                y: box.y + corner.y * box.height - 4)
                }

                RegionConfirmBar(width: box.width, height: box.height,
                                 isResolving: state.isResolving,
                                 record: { choose() })
                    // Below the rectangle when there is room, above it when there is not — a bar
                    // off the bottom of the screen is a bar nobody can press.
                    .offset(x: box.x,
                            y: box.y + box.height + 44 < screen.frame.height
                                ? box.y + box.height + 8
                                : max(box.y - 36, 4))
            }
        }
        .compositingGroup()
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let startX = Double(value.startLocation.x)
                    let startY = Double(value.startLocation.y)
                    let x = Double(value.location.x), y = Double(value.location.y)
                    if gesture == nil { gesture = began(atX: startX, y: startY) }
                    guard let gesture else { return }
                    state.chosen = gesture.applied(toX: x, y: y,
                                                   screenFrame: GlobalRect.topLeft(of: screen))
                }
                .onEnded { _ in
                    // **The rectangle stays; nothing starts.** Ending a drag used to begin the
                    // recording, so the rectangle was whatever your hand left behind.
                    if let chosen = state.chosen,
                       chosen.width < Self.minimumSide || chosen.height < Self.minimumSide {
                        // A click, or a drag too small to record. Not a cancel — somebody who
                        // clicked by accident should still have the overlay, and ⎋ is the way out.
                        state.chosen = state.remembered
                    }
                    gesture = nil
                }
        )
        .onAppear {
            // The remembered rectangle is shown straight away, so a second take starts from the
            // first take's frame rather than from an empty screen.
            if state.chosen == nil { state.chosen = state.remembered }
        }
    }

    /// What a drag starting here means: pulling an edge of the rectangle, moving it, or drawing
    /// a new one.
    ///
    /// **Edges first, then inside, then a new rectangle.** A corner is inside the rectangle too,
    /// so testing "inside" first would make the handles unreachable — which is the bug every
    /// crop tool has had at least once.
    private func began(atX x: Double, y: Double) -> RegionGesture {
        let frame = GlobalRect.topLeft(of: screen)
        guard let chosen = state.chosen else {
            return .drawing(originX: frame.x + x, originY: frame.y + y)
        }
        let localX = chosen.x - frame.x, localY = chosen.y - frame.y
        if let edge = RegionEdge.grabbed(atX: x, y: y, boxX: localX, boxY: localY,
                                         width: chosen.width, height: chosen.height,
                                         reach: Self.handleReach) {
            return .resizing(edge: edge, from: chosen)
        }
        if x >= localX, x <= localX + chosen.width, y >= localY, y <= localY + chosen.height {
            return .moving(from: chosen, grabX: frame.x + x, grabY: frame.y + y)
        }
        return .drawing(originX: frame.x + x, originY: frame.y + y)
    }

    private func choose() {
        guard !state.isResolving, let rect = state.chosen,
              rect.width >= Self.minimumSide, rect.height >= Self.minimumSide else { return }
        state.isResolving = true
        RememberedRegion.save(rect)
        Task { @MainActor in
            let source = await RegionTargets.source(for: rect)
            state.onFinish?(source)
        }
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

/// One corner's grab handle.
private struct RegionHandle: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(.white)
            .frame(width: 8, height: 8)
            .shadow(color: .black.opacity(0.5), radius: 2)
            .allowsHitTesting(false)
    }
}

/// The size, and the button that starts the recording.
private struct RegionConfirmBar: View {
    let width: Double
    let height: Double
    let isResolving: Bool
    let record: () -> Void

    var body: some View {
        HStack(spacing: Space.snug) {
            Text(verbatim: "\(Int(width.rounded()))\u{00D7}\(Int(height.rounded()))")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white)
            if isResolving {
                ProgressView().controlSize(.small)
            } else {
                Button(action: record) {
                    HStack(spacing: Space.tight) {
                        Image(systemName: "record.circle.fill").font(.system(size: 11))
                        Text("Record").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, Space.snug)
                    .frame(height: 22)
                    .background(Capsule().fill(Signal.record))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text("\u{238B}").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, Space.snug)
        .padding(.vertical, Space.tight)
        .glassSurface(radius: 8)
    }
}
