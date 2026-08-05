import CoreGraphics
import Foundation

/// **The pointer this app draws, and it is never the real cursor.**
///
/// `CaptureSession` records with `showsCursor = false` (Phase 2 design doc), deliberately: the
/// real pointer image is never in a master recording's own pixels. What appears on screen at
/// playback is drawn here, from the observation track (`Render.PointerTrack`), and it is this
/// app's own art — a fixed arrow silhouette. **The real shape is lost in the substitution**: an
/// I-beam over text, a resize handle over a window edge, a hand over a link, a spinner while
/// something loads. There is no supported route for this app to read another application's
/// cursor image, so recovering the real shape is not a future feature this file is a placeholder
/// for — it is a known, recorded limitation. Nothing here should be read as "eventually this will
/// show the real cursor."
///
/// **This file moved from `Soredemo/Render/` into the `Headless` target in Phase 3A-1 Task 2**,
/// as the walking skeleton's one type: it is the tier `swift test` can link and run, so what used
/// to be readable only as text is now executable. Its rule-5 half moved with it — the scan that
/// confines CoreGraphics geometry here is
/// `HeadlessEntryRuleTests.coreGraphicsGeometryTypesAppearOnlyInTheHeadlessBridge` over
/// `Sources/Headless`, and the bridge it permits is `HeadlessGeometryBridge.swift`, not the app's.
///
/// Every `CGPoint` a `CGMutablePath` needs here comes from `HeadlessGeometryBridge.point(x:y:)`,
/// which is in this same module and so needs no import. That test confines `CGPoint` itself to
/// that one file — a path-building function is exactly the call site that would otherwise reach
/// for `CGPoint(x:y:)` directly. `CGPath`, `CGMutablePath` and `CGFloat`-typed
/// parameters fed a `Double` argument are not in rule 5's banned list — see that test's own banned
/// array — so this file names them freely; only the four literal type names it lists are confined.
///
/// **The ripple's circle is built from four cubic Bézier arcs, not `CGPath(ellipseIn:)`.** That
/// initialiser takes a `CGRect`, which is exactly what rule 5 confines to the bridge,
/// and opening a second bridge gap (a rect-from-scalars overload) for one call site here was not
/// worth it when every point a Bézier-arc circle needs is already reachable through
/// `HeadlessGeometryBridge.point(x:y:)` — the one gap the brief actually named. `circleKappa` below is
/// the standard constant for that approximation (a circle of radius `r` approximated by four
/// cubic Béziers each spanning a quarter turn, control points offset by `r * κ` along the
/// tangent) and is accurate to within a fraction of a percent of the true circle, which is
/// nowhere close to visible at the pixel sizes this app draws a ripple at.
/// `nonisolated` on the type, matching `FrameRendering`, `StageCompositor` and
/// `CoreImageFrameRenderer`. **The reason below is now about two build settings, not one, and the
/// annotation is load-bearing in only one of them** — corrected when this file moved, because a
/// reason that has stopped applying reads exactly like one that still does. In the SwiftPM
/// `Headless` target the default is `nonisolated` and the modifier is redundant; the app target
/// and `scripts/run-cross-boundary-probe.sh` both compile the callers (and, in the probe's case,
/// this very file) with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` / `-default-isolation
/// MainActor`, where it is not. It stays because the probe still compiles this source under that
/// setting, so the measurement recorded below is still reproducible. Under MainActor default,
/// an unannotated declaration here would be implicitly MainActor-isolated — harmless were every
/// caller itself on the main actor, which is not true of `CoreImageFrameRenderer.render(_:source
/// :into:)`. That method runs on `AVVideoCompositing.startRequest(_:)`'s callback, which
/// AVFoundation delivers on its own queue, not the main actor: calling a MainActor-isolated
/// `CursorArt` function from there would not fail to compile (an implicitly-async cross-actor
/// call inserts a hop silently) but would TRAP AT RUNTIME the first time a frame with a pointer on
/// it was ever composited, because `render(_:source:into:)` is itself synchronous and nonisolated,
/// and hopping to the main actor from inside a synchronous nonisolated function is exactly the
/// fault this annotation exists to make a compile-time error instead. Measured: removing this
/// modifier and re-running `scripts/run-cross-boundary-probe.sh` reproduces exactly that failure
/// shape at compile time — "call to main actor-isolated ... in a synchronous nonisolated context"
/// — for every call `CoreImageFrameRenderer.cursorImage(for:outputHeight:)` makes into this type.
public nonisolated enum CursorArt {
    /// Outline points for the arrow silhouette, in a space where **the tip is the origin** and
    /// the rest of the arrow extends toward positive `x` and negative `y` — "down and to the
    /// right" in OUTPUT PIXELS' bottom-left-origin convention (`RenderPlan.swift`'s header),
    /// which is the same convention the raw `CGContext` bitmap `CoreImageFrameRenderer` draws
    /// this into uses natively (a `CGContext` you build yourself, rather than one AppKit hands
    /// you already flipped, has bottom-left origin — Quartz's native space, matching Core
    /// Image's). A caller translates this path so the tip lands exactly on the recorded
    /// position, the same "hot spot at the tip" convention the system's own arrow cursor uses.
    ///
    /// Seven points: the classic arrow-cursor silhouette — a long left edge down from the tip,
    /// a short diagonal tail, and a barbed right edge back up — closed into one outline.
    private static let outline: [(x: Double, y: Double)] = [
        (0, 0), (0, -22), (5, -17), (8.5, -24.5), (11.5, -23), (8, -15.5), (16, -15.5),
    ]

    /// The largest coordinate magnitude in `outline`, at `scale == 1` — what a caller sizing a
    /// canvas to hold the arrow at some `scale` needs to know, without re-deriving it from the
    /// point list by hand each time. `24.5` (the tail point's `y`) is the largest single
    /// magnitude among the seven points above.
    public static let pointerMaxExtent: Double = 24.5

    /// The classic arrow-cursor silhouette, scaled uniformly by `scale`, as a closed path a
    /// caller fills and/or strokes. See `outline` above for the coordinate space and the tip
    /// convention.
    public static func pointerPath(scale: Double) -> CGPath {
        let path = CGMutablePath()
        let first = outline[0]
        path.move(to: HeadlessGeometryBridge.point(x: first.x * scale, y: first.y * scale))
        for point in outline.dropFirst() {
            path.addLine(to: HeadlessGeometryBridge.point(x: point.x * scale, y: point.y * scale))
        }
        path.closeSubpath()
        return path
    }

    /// The ripple's radius at the click instant (`phase == 0`) — small but non-zero, so the first
    /// drawn frame already shows a ring rather than a dot.
    static let rippleStartRadius: Double = 6
    /// The ripple's radius once it has fully expanded (`phase == 1`), in the same OUTPUT-PIXEL
    /// unit as `pointerMaxExtent` — fixed, and NOT scaled by `pointerPath`'s `scale`: a click
    /// ripple reads as one consistent size regardless of how large the drawn pointer itself is.
    public static let rippleEndRadius: Double = 28

    /// κ, the standard control-point offset (as a fraction of the radius) for approximating a
    /// quarter-circle arc with one cubic Bézier segment.
    private static let circleKappa = 0.5522847498307936

    /// A circle centred at the origin, radius interpolated linearly from `rippleStartRadius` to
    /// `rippleEndRadius` as `phase` runs `0...1`. The caller fades the STROKE ALPHA as `phase`
    /// rises — this function only draws the growing ring; a `CGPath` carries no colour or alpha
    /// of its own to fade.
    ///
    /// `phase` is clamped to `0...1` before use: a caller holding a slightly out-of-range phase
    /// (a spring overshoot, a rounding artefact one ULP past either end) gets a circle at the
    /// nearer bound rather than a path built from a radius outside the range this type documents.
    public static func ripplePath(phase: Double) -> CGPath {
        let clamped = min(max(phase, 0), 1)
        let radius = rippleStartRadius + (rippleEndRadius - rippleStartRadius) * clamped
        let k = radius * circleKappa

        let path = CGMutablePath()
        path.move(to: HeadlessGeometryBridge.point(x: radius, y: 0))
        path.addCurve(to: HeadlessGeometryBridge.point(x: 0, y: radius),
                      control1: HeadlessGeometryBridge.point(x: radius, y: k),
                      control2: HeadlessGeometryBridge.point(x: k, y: radius))
        path.addCurve(to: HeadlessGeometryBridge.point(x: -radius, y: 0),
                      control1: HeadlessGeometryBridge.point(x: -k, y: radius),
                      control2: HeadlessGeometryBridge.point(x: -radius, y: k))
        path.addCurve(to: HeadlessGeometryBridge.point(x: 0, y: -radius),
                      control1: HeadlessGeometryBridge.point(x: -radius, y: -k),
                      control2: HeadlessGeometryBridge.point(x: -k, y: -radius))
        path.addCurve(to: HeadlessGeometryBridge.point(x: radius, y: 0),
                      control1: HeadlessGeometryBridge.point(x: k, y: -radius),
                      control2: HeadlessGeometryBridge.point(x: radius, y: -k))
        path.closeSubpath()
        return path
    }
}
