import CoreGraphics
import Foundation

/// **The render tier's CoreGraphics exit, and the only file in `Sources/Headless`
/// allowed to name `CGRect`, `CGPoint`, `CGSize` or `CGFloat`.**
///
/// `Soredemo/Capture/CGGeometryBridge.swift` is the APP tier's bridge. It holds the
/// ENTRANCES — the `AXValue` decoders and the `ScreenCaptureKit` frame-attachment
/// decoder — which need `ApplicationServices` and belong to Phase 3A-2. The three
/// functions here are the EXITS: they take plain scalars, they touch no
/// accessibility API and no ScreenCaptureKit, and each one exists because the render
/// path needed it (their own doc comments name the Phase 2B task that added them).
///
/// **The split is by tier, not by convenience.** These three moved because
/// `CursorArt` moved and every point it builds comes through `point(x:y:)`; moving
/// the whole app bridge to keep one file would have dragged `ApplicationServices`,
/// the AX decoders and the attachment decoder into this target — 3A-2's scope pulled
/// forward into the task whose entire purpose is to move as little as possible. When
/// `Capture` moves in 3A-2 the two bridges are reconsidered TOGETHER, and the
/// expected outcome is that they become one again.
///
/// **Each bridge is confined by its own test, so neither is confined by memory.**
/// `AppSourceAllowListTests.coreGraphicsGeometryTypesAppearOnlyInTheBridge` scans
/// `Soredemo/` against the app bridge;
/// `HeadlessEntryRuleTests.coreGraphicsGeometryTypesAppearOnlyInTheHeadlessBridge`
/// scans `Sources/Headless` against this one. Two tiers, two bridges, two tests, and
/// neither test has an exception — which is the only reason either is worth having.
/// `theTwoGeometryBridgesShareNoFunctionSignature` is the third: while the split exists,
/// no conversion may be defined on both sides of it.
///
/// `HeadlessCheck` cannot do this job. Rule 2 (the package-wide CG ban) is OFF in
/// headless mode, deliberately, because this tier is where CG conversion legitimately
/// happens — "where it happens" still has to be one file, and that is what the test
/// above pins.
public nonisolated enum HeadlessGeometryBridge {
    /// The render pipeline's own exit: `RenderPlan.outputWidth`/`.outputHeight`, as the `CGRect`
    /// `CIImage.cropped(to:)` needs.
    ///
    /// **Added for the compositor seam (Phase 2B Task 3), not in that task's brief.** The brief's
    /// literal text for `CoreImageFrameRenderer.render(_:source:into:)` builds
    /// `CGRect(x: 0, y: 0, width: CGFloat(plan.outputWidth), height: CGFloat(plan.outputHeight))`
    /// inline, which is exactly what
    /// `AppSourceAllowListTests.coreGraphicsGeometryTypesAppearOnlyInTheBridge` (rule 5) exists to
    /// catch: measured red, naming `CGRect` and `CGFloat` at
    /// `Soredemo/Render/CoreImageFrameRenderer.swift:32-34`. `plan.outputWidth`/`.outputHeight` are
    /// plain `Int`s, not a package geometry type, so this takes scalars rather than adding a
    /// `StageRect` overload — a `StageRect` decode-then-discard-the-position would be a fact this
    /// call site does not have (the output canvas has no position, only an extent).
    public nonisolated static func outputCanvas(width: Int, height: Int) -> CGRect {
        CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
    }

    /// The composition's own exit: `AVVideoComposition.Configuration.renderSize` is a `CGSize`,
    /// and `CompositionBuilder` (Phase 2B Task 4) holds only the plain `Int`s a `RenderPlan`
    /// carries. Same shape as `outputCanvas(width:height:)` immediately above — an extent with no
    /// position — added for the same reason: rule 5 confines `CGSize` to one file per tier, and
    /// `CompositionBuilder.swift` writing `CGSize(width:height:)` inline would be exactly the
    /// violation `outputCanvas` was added to fix in `CoreImageFrameRenderer.swift`.
    public nonisolated static func renderSize(width: Int, height: Int) -> CGSize {
        CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    /// The cursor art's own exit: `Sources/Headless/CursorArt.swift` (Phase 2B Task 5) builds
    /// `CGMutablePath`s for the drawn pointer and its click ripple, and every `move(to:)`/
    /// `addLine(to:)`/`addCurve(to:control1:control2:)` on a `CGMutablePath` takes a `CGPoint`.
    /// Scalars in, `CGPoint` out — the same shape as `outputCanvas(width:height:)` and
    /// `renderSize(width:height:)` immediately above: `NormalizedPointerPlacement.x`/`.y` and the
    /// path-geometry constants `CursorArt` computes from them are plain `Double`s, not a package
    /// geometry type, so this takes scalars rather than adding a `StageRect`-shaped overload.
    ///
    /// **Added for the drawn pointer (Phase 2B Task 5), not in that task's brief.** The brief's
    /// interface list asks for `CursorArt.pointerPath(scale:)` and `.ripplePath(phase:)` with no
    /// point-making function named anywhere to build either `CGPath` from — the same gap
    /// `outputCanvas`/`renderSize` closed for Tasks 3 and 4, this time for the one CoreGraphics
    /// type the bridge had not yet needed to hand back out.
    public nonisolated static func point(x: Double, y: Double) -> CGPoint {
        CGPoint(x: x, y: y)
    }
}
