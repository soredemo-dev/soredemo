import Foundation
import Geometry

/// A screen, reduced to the numbers the notch surface needs.
///
/// A value rather than an `NSScreen` so every Mac shape can be built in a test — no test can
/// attach a 16-inch panel. Restored from the withdrawn notch transition (`e2b7863^`), where it was
/// checked against thirteen real geometries; see `2026-09-27-the-recorder-lives-in-the-notch.md`.
struct ScreenMetrics: Equatable {
    /// The screen's frame in global TOP-LEFT points.
    let frame: PointRect
    /// `NSScreen.safeAreaInsets.top`. Zero on a screen with no notch.
    let safeAreaTop: Double
    /// `NSScreen.auxiliaryTopLeftArea?.width` / `…Right…`. Both `nil` on a screen with no notch,
    /// which includes a notched panel in a display mode that excludes the notch strip.
    let auxiliaryLeftWidth: Double?
    let auxiliaryRightWidth: Double?

    /// Whether this screen has a notch, asked the way the screen answers it.
    var hasNotch: Bool { auxiliaryLeftWidth != nil && auxiliaryRightWidth != nil && safeAreaTop > 0 }

    /// The notch's own rectangle in global top-left points, or `nil`.
    var notch: PointRect? {
        guard hasNotch, let left = auxiliaryLeftWidth, let right = auxiliaryRightWidth else {
            return nil
        }
        let width = frame.width - left - right
        guard width > 0 else { return nil }
        return PointRect(x: frame.x + (frame.width - width) / 2, y: frame.y,
                         width: width, height: safeAreaTop)
    }
}

/// What the notch surface is showing. A pure value: every transition is a test.
enum NotchSurfaceState: Equatable {
    case dormant
    case glance
    case open
    case live(expanded: Bool)

    enum Event: Equatable {
        case pointerEntered, pointerLeft, clicked, clickedOutside, escape
        case recordingBegan, recordingEnded
    }

    func handling(_ event: Event) -> NotchSurfaceState {
        switch (self, event) {
        case (.live, .recordingEnded): .dormant
        // **Nothing but the pointer and the end of the take moves a live surface.** It is the
        // only thing on screen saying a recording is running.
        case (.live, .pointerEntered): .live(expanded: true)
        case (.live, .pointerLeft): .live(expanded: false)
        case (.live, _): self
        case (_, .recordingBegan): .live(expanded: false)
        case (.dormant, .pointerEntered): .glance
        case (.glance, .pointerLeft): .dormant
        case (.dormant, .clicked), (.glance, .clicked): .open
        // **Open survives the pointer leaving**: its pickers open menus, and a menu is outside
        // the surface. A click outside or escape closes it.
        case (.open, .clickedOutside), (.open, .escape): .dormant
        default: self
        }
    }
}

/// Where the surface is, per state, on a given screen.
///
/// **Lengths near the notch are shares of the notch's height; lengths that hold controls are
/// points.** The notch is a fixed number of pixels, so its size in points moves with the display
/// mode and so must the wings that extend it. A row of buttons holds text, and text is in points.
enum NotchSurfaceLayout {
    /// Each wing of the glance and of a live take, as a multiple of the notch's height.
    static let wingShare: Double = 2.4
    /// The open recorder and the expanded take: the smallest width their controls fit in, and
    /// how far each hangs below the notch.
    static let openMinimumWidth: Double = 460
    static let openDepth: Double = 96
    static let expandedMinimumWidth: Double = 400
    static let expandedDepth: Double = 44

    static func rect(for state: NotchSurfaceState, notch: PointRect, screen: PointRect) -> PointRect {
        let winged = notch.width + 2 * wingShare * notch.height
        let (width, height): (Double, Double) = switch state {
        case .dormant: (notch.width, notch.height)
        case .glance, .live(expanded: false): (winged, notch.height)
        case .open: (max(winged, openMinimumWidth), notch.height + openDepth)
        case .live(expanded: true): (max(winged, expandedMinimumWidth), notch.height + expandedDepth)
        }
        // Never wider than the screen allows around the notch's own centre.
        let centre = notch.x + notch.width / 2
        let room = 2 * min(centre - screen.x, screen.x + screen.width - centre)
        let clamped = min(width, room)
        return PointRect(x: centre - clamped / 2, y: notch.y, width: clamped, height: height)
    }
}

/// Whether the pointer at a position has entered or left the surface, decided from where it is
/// rather than from SwiftUI's hover.
///
/// **Hover flickered, measured.** SwiftUI's `onHover` on a shape that grows under the pointer
/// reported enter, then leave, then enter — three glances and three dormants for one pointer
/// resting on the notch, and the click that followed landed on a surface that had just shrunk.
/// So entering and leaving are asked of two different rectangles: the pointer ENTERS by reaching
/// the notch, and LEAVES only by leaving everything the surface has grown to. That gap is the
/// hysteresis that keeps a growing surface from dropping the pointer it grew under.
enum NotchSurfacePointer {
    /// The notch's wake zone reaches this share of the notch's height past each side and below.
    static let wakeMargin: Double = 0.25

    static func event(atX x: Double, y: Double, state: NotchSurfaceState,
                      notch: PointRect, surface: PointRect) -> NotchSurfaceState.Event? {
        let margin = notch.height * wakeMargin
        func contains(_ r: PointRect, grownBy m: Double) -> Bool {
            x >= r.x - m && x <= r.x + r.width + m && y >= r.y - m && y <= r.y + r.height + m
        }
        let onNotch = contains(notch, grownBy: margin)
        let onSurface = contains(surface, grownBy: margin)
        return switch state {
        case .dormant, .live(expanded: false): onNotch ? .pointerEntered : nil
        case .glance, .live(expanded: true): onSurface ? nil : .pointerLeft
        // Open closes on a click outside or escape: its menus take the pointer outside it.
        case .open: nil
        }
    }
}
