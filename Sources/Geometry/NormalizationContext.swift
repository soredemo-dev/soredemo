import Foundation

/// The one place in this codebase where the Y axis flips (design doc §
/// Geometry: the Y-axis flip). Converts raw pixels for a single display into
/// normalised, revision-tagged coordinates, and back.
///
/// **Every input to `normalize` is display-local top-left pixels — never
/// global ones, and never points.** `CGDisplayBounds`, `CGEventGetLocation`,
/// and AX `kAXPositionAttribute` are all top-left, but a *global* point (e.g.
/// from `CGEventGetLocation`, which reports coordinates relative to the whole
/// desktop, in points) still has to cross two boundaries before it means
/// anything here:
///
/// 1. **Routed** to the display it actually landed on, via
///    `DisplayArrangement.route` (Task 10) — which returns display-local
///    **points**, not pixels.
/// 2. **Converted** from points to this display's native pixels, via
///    `DisplayGeometry.pixels(from:)` (Task 10.5) — `route` deliberately does
///    not do this itself, and neither does this initialiser; each unit
///    conversion happens in exactly one place.
///
/// So the full pipeline is global point (points) → `route` → local point
/// (points) → `DisplayGeometry.pixels(from:)` → local point (pixels) →
/// `normalize`. Skipping either step — feeding a global point straight in,
/// or feeding `route`'s point output straight in without the pixel
/// conversion — produces a plausible-looking `NormalizedPoint`: the
/// arithmetic below doesn't know it was handed the wrong display's width and
/// height, or the wrong unit, so it computes a wrong answer with no error
/// anywhere. Do not "helpfully" widen this initialiser to accept global or
/// point-valued coordinates, or a display list — route and convert first,
/// then normalize against the one display the point is actually on, in
/// pixels.
///
/// The flip itself anchors on the rect's **bottom** edge, not its top: a
/// frame's normalised `y` is `1 - ((topLeftY + height) / pixelHeight)`, not
/// `1 - (topLeftY / pixelHeight)`. Using the top-edge formula for a frame
/// produces an error equal to the frame's own height — small enough to look
/// like a rounding bug, large enough to land a click or a zoom on the wrong
/// control. `ConversionTests.swift` pins the direction with a rect anchored
/// away from vertical centre, specifically because a vertically centred rect
/// round-trips correctly even when the flip is inverted.
public struct NormalizationContext: Sendable {
    /// The display this context normalises pixels against. Its `revision` is
    /// stamped onto every `NormalizedFrame` this context produces, and is
    /// checked against every frame this context is asked to `denormalize`.
    public let geometry: DisplayGeometry

    public init(geometry: DisplayGeometry) {
        self.geometry = geometry
    }

    private var pixelWidth: Double { Double(geometry.pixelWidth) }
    private var pixelHeight: Double { Double(geometry.pixelHeight) }

    /// Normalises a single display-local, top-left-origin pixel point.
    /// A point has no height to anchor against, so this is the frame formula
    /// with `height == 0`.
    public func normalize(topLeftX: Double, topLeftY: Double) -> NormalizedPoint {
        NormalizedPoint(x: topLeftX / pixelWidth,
                         y: 1 - (topLeftY / pixelHeight))
    }

    /// Normalises a display-local, top-left-origin pixel rectangle.
    ///
    /// The flip moves the anchor from the rect's top edge to its bottom edge:
    /// normalised `y` is `1 - ((topLeftY + height) / pixelHeight)`. The
    /// resulting frame carries `geometry.revision`, per this type's contract.
    public func normalize(topLeftX: Double, topLeftY: Double,
                           width: Double, height: Double) -> NormalizedFrame {
        let origin = NormalizedPoint(x: topLeftX / pixelWidth,
                                      y: 1 - ((topLeftY + height) / pixelHeight))
        let size = NormalizedSize(width: width / pixelWidth, height: height / pixelHeight)
        return NormalizedFrame(origin: origin, size: size, revision: geometry.revision)
    }

    /// Inverts `normalize(topLeftX:topLeftY:width:height:)`, returning
    /// display-local, top-left-origin pixels.
    ///
    /// Traps if `frame` was normalised against a different display
    /// configuration than `geometry` — comparing across a revision mismatch
    /// is a wrong answer computed in silence (see `NormalizedFrame`'s own
    /// documentation), and here it would additionally scale the frame's own
    /// normalised numbers by the wrong display's pixel dimensions. Like every
    /// precondition in this module, this cannot be exercised with `#expect`;
    /// see the task report for the out-of-process verification.
    public func denormalize(_ frame: NormalizedFrame) -> PixelRect {
        precondition(frame.revision == geometry.revision, """
            geometry revision mismatch: \(frame.revision) vs \(geometry.revision). A frame \
            normalized against a different display configuration cannot be denormalized here.
            """)
        let width = frame.size.width * pixelWidth
        let height = frame.size.height * pixelHeight
        let x = frame.origin.x * pixelWidth
        // Inverse of the forward formula: origin.y == 1 - ((topLeftY + height) / pixelHeight),
        // so topLeftY == pixelHeight * (1 - (origin.y + size.height)).
        let y = pixelHeight * (1 - (frame.origin.y + frame.size.height))
        return PixelRect(x: x, y: y, width: width, height: height)
    }
}
