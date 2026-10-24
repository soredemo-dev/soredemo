import Foundation
import Geometry

/// Where a recorded element is on an exported picture — the box a guide draws around what a step
/// pressed, and the target a walkthrough asks the viewer to click.
///
/// **The cursor's own road.** The element's four corners go through `StagePlanner.placement`, the
/// function the drawn pointer is placed by — the card, the camera's zoom and the card's turn — so
/// the box and the cursor cannot disagree about where a thing is. Whatever the cursor does with a
/// crop, the box does too. See `docs/design/2026-10-25-where-the-element-is-in-the-picture.md`.
public enum WalkthroughHotspot {
    /// A box as fractions of the picture, **top-left origin** — what an HTML overlay is positioned
    /// by. The plan's pixels are bottom-left; the flip is made here, once.
    public struct Box: Hashable, Sendable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
    }

    /// The element's box on the picture `plan` draws, clipped to the picture, or `nil` when none
    /// of it is on the picture — a camera that has moved off the element, rather than a box
    /// clamped to an edge the element is not at.
    public static func box(of frame: NormalizedFrame, in plan: RenderPlan) -> Box? {
        let width = Double(plan.outputWidth), height = Double(plan.outputHeight)
        guard width > 0, height > 0 else { return nil }
        let corners = [
            NormalizedPoint(x: frame.minX, y: frame.minY),
            NormalizedPoint(x: frame.minX + frame.size.width, y: frame.minY),
            NormalizedPoint(x: frame.minX, y: frame.minY + frame.size.height),
            NormalizedPoint(x: frame.minX + frame.size.width, y: frame.minY + frame.size.height),
        ].map { StagePlanner.placement(for: $0, in: plan) }
        let left = max(corners.map(\.x).min() ?? 0, 0)
        let right = min(corners.map(\.x).max() ?? 0, width)
        let bottom = max(corners.map(\.y).min() ?? 0, 0)
        let top = min(corners.map(\.y).max() ?? 0, height)
        guard right > left, top > bottom else { return nil }
        return Box(x: left / width, y: 1 - top / height,
                   width: (right - left) / width, height: (top - bottom) / height)
    }
}
