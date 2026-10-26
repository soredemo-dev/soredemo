import Geometry
import Observation

/// What the notch surface is showing, and where, on one screen. The state machine and the layout
/// are pure (`NotchSurface.swift`); this holds the one instance of each the panel draws.
@MainActor @Observable
final class NotchSurfaceModel {
    private(set) var state: NotchSurfaceState = .dormant
    /// The notch, in the screen's own top-left points.
    let notch: PointRect
    let screen: PointRect

    init(notch: PointRect, screen: PointRect) {
        self.notch = notch
        self.screen = screen
    }

    func send(_ event: NotchSurfaceState.Event) {
        state = state.handling(event)
    }

    /// The surface in the screen's top-left points, for the current state.
    var rect: PointRect { NotchSurfaceLayout.rect(for: state, notch: notch, screen: screen) }

    /// **The panel is the size of the largest state and never moves**; the shape inside animates.
    /// Moving the window per state would animate a window frame, which AppKit does not spring.
    var panelRect: PointRect {
        let largest = [NotchSurfaceState.open, .live(expanded: true), .glance].map {
            NotchSurfaceLayout.rect(for: $0, notch: notch, screen: screen)
        }
        let width = largest.map(\.width).max() ?? notch.width
        let height = largest.map(\.height).max() ?? notch.height
        let centre = notch.x + notch.width / 2
        return PointRect(x: centre - width / 2 - flare, y: 0, width: width + 2 * flare, height: height)
    }

    /// The surface in the panel's own top-left points.
    var localRect: PointRect {
        let panel = panelRect, surface = rect
        return PointRect(x: surface.x - panel.x, y: surface.y - panel.y,
                         width: surface.width, height: surface.height)
    }

    /// How far the top corners curl into the menu bar: the share of the notch's height the
    /// withdrawn design settled on (six of 32 on the machine both were measured on).
    var flare: Double { notch.height * 0.1875 }

    /// The bottom corners, which open as the surface grows: the notch's own curve when dormant,
    /// a panel's when open.
    var bottomRadius: Double {
        switch state {
        case .dormant: notch.height * 0.3
        case .glance, .live(expanded: false), .finished: notch.height * 0.45
        case .open, .live(expanded: true): 22
        }
    }
}
