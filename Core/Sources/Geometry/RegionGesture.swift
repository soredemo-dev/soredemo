import Foundation

// The region overlay's geometry: what a drag on it is doing, and which edge it has hold of.
//
// **In the package because it is arithmetic, not a view.** It lived beside the SwiftUI that drew
// it, which meant no test could reach it — and clamping, flipping and normalising a dragged
// rectangle is exactly the kind of thing that is wrong in one of eight cases and looks fine in
// the other seven. Nothing here names AppKit; the caller converts its screen to a `PointRect`.

/// What a drag on the overlay is doing.
///
/// **A value rather than three booleans**, because the three are exclusive and a state where two
/// were true would be a rectangle being drawn and moved at once.
public enum RegionGesture: Sendable {
    case drawing(originX: Double, originY: Double)
    case moving(from: PointRect, grabX: Double, grabY: Double)
    case resizing(edge: RegionEdge, from: PointRect)

    /// The rectangle this gesture produces with the pointer here.
    ///
    /// `screenFrame` is the panel's own frame in the global top-left space, and the pointer is
    /// in the panel's local coordinates — an `NSScreen` is not taken, so this file has no AppKit
    /// in it and the arithmetic can be tested without one.
    public func applied(toX x: Double, y: Double, screenFrame: PointRect) -> PointRect {
        let globalX = screenFrame.x + x, globalY = screenFrame.y + y
        switch self {
        case .drawing(let originX, let originY):
            return PointRect(x: min(originX, globalX), y: min(originY, globalY),
                             width: abs(globalX - originX), height: abs(globalY - originY))
        case .moving(let from, let grabX, let grabY):
            // **Moved by the difference, not to the pointer.** Snapping the rectangle's origin
            // to the cursor would jump it the moment a drag began anywhere but its top-left.
            return PointRect(x: from.x + (globalX - grabX), y: from.y + (globalY - grabY),
                             width: from.width, height: from.height)
        case .resizing(let edge, let from):
            return edge.resized(from, toX: globalX, y: globalY)
        }
    }
}

/// Which edge or corner of the rectangle a drag has hold of.
public enum RegionEdge: Hashable, Sendable {
    public static let allEdges: [RegionEdge] = [
        .top, .bottom, .leading, .trailing,
        .topLeading, .topTrailing, .bottomLeading, .bottomTrailing,
    ]

    case top, bottom, leading, trailing
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    /// The four corners, as fractions of the rectangle, for drawing their handles. Named because
    /// `ForEach` wants a stable identity and a tuple of two `Double`s has none.
    public static let corners: [(name: String, x: Double, y: Double)] = [
        ("topLeading", 0, 0), ("topTrailing", 1, 0),
        ("bottomLeading", 0, 1), ("bottomTrailing", 1, 1),
    ]

    /// Which edge is within `reach` of this point, or `nil` for none.
    ///
    /// **Corners before edges**, because a corner is on two edges and a person aiming at one
    /// means the corner. Written as a lookup rather than a chain of `if`s so the precedence is
    /// visible rather than implied by the order somebody happened to type.
    public static func grabbed(atX x: Double, y: Double, boxX: Double, boxY: Double,
                        width: Double, height: Double, reach: Double) -> RegionEdge? {
        let nearLeading = abs(x - boxX) <= reach
        let nearTrailing = abs(x - (boxX + width)) <= reach
        let nearTop = abs(y - boxY) <= reach
        let nearBottom = abs(y - (boxY + height)) <= reach
        let insideX = x >= boxX - reach && x <= boxX + width + reach
        let insideY = y >= boxY - reach && y <= boxY + height + reach
        guard insideX, insideY else { return nil }
        switch (nearTop, nearBottom, nearLeading, nearTrailing) {
        case (true, _, true, _): return .topLeading
        case (true, _, _, true): return .topTrailing
        case (_, true, true, _): return .bottomLeading
        case (_, true, _, true): return .bottomTrailing
        case (true, _, _, _): return .top
        case (_, true, _, _): return .bottom
        case (_, _, true, _): return .leading
        case (_, _, _, true): return .trailing
        default: return nil
        }
    }

    /// The rectangle with this edge pulled to a point, normalised so dragging an edge past its
    /// opposite flips rather than producing a negative size.
    public func resized(_ rect: PointRect, toX x: Double, y: Double) -> PointRect {
        var left = rect.x, top = rect.y
        var right = rect.x + rect.width, bottom = rect.y + rect.height
        switch self {
        case .top: top = y
        case .bottom: bottom = y
        case .leading: left = x
        case .trailing: right = x
        case .topLeading: top = y; left = x
        case .topTrailing: top = y; right = x
        case .bottomLeading: bottom = y; left = x
        case .bottomTrailing: bottom = y; right = x
        }
        return PointRect(x: min(left, right), y: min(top, bottom),
                         width: abs(right - left), height: abs(bottom - top))
    }
}
