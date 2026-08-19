import Foundation
import Geometry
// `PointerShape` rides on the placement since the recorder-parity work.
import Project

/// Turns an output size and a source size into the rectangle the recording is drawn in.
///
/// Pure, and deliberately takes sizes rather than a `ProjectSnapshot`: the geometry question has
/// nothing to do with the document, and a function that takes the document cannot be tested
/// without building one.
public enum StagePlanner {
    public static func plan(outputWidth: Int, outputHeight: Int,
                            sourceWidth: Int, sourceHeight: Int,
                            style: StageStyle,
                            pointer: NormalizedPointerPlacement? = nil) -> RenderPlan {
        precondition(outputWidth > 0 && outputHeight > 0,
                     "output must be positive, got \(outputWidth)x\(outputHeight)")
        precondition(sourceWidth > 0 && sourceHeight > 0,
                     "source must be positive, got \(sourceWidth)x\(sourceHeight)")

        let output = (w: Double(outputWidth), h: Double(outputHeight))
        let inset = style.insetFraction
        let available = (w: output.w * (1 - 2 * inset), h: output.h * (1 - 2 * inset))

        // Fit, never fill: the recording is evidence and must not be cropped.
        let sourceAspect = Double(sourceWidth) / Double(sourceHeight)
        let cardWidth = min(available.w, available.h * sourceAspect)
        let cardHeight = cardWidth / sourceAspect

        let card = StageRect(x: (output.w - cardWidth) / 2, y: (output.h - cardHeight) / 2,
                             width: cardWidth, height: cardHeight)
        // A radius larger than half the shorter side is not a rounder rectangle, it is an
        // undefined one. Clamped here so no renderer has to decide.
        let radius = min(style.cornerRadius, min(cardWidth, cardHeight) / 2)
        return RenderPlan(outputWidth: outputWidth, outputHeight: outputHeight,
                          card: card, cornerRadius: radius, style: style, pointer: pointer)
    }

    /// A normalised point (bottom-left origin, 0…1 over the SOURCE — `NormalizedPoint`'s own doc
    /// comment) placed in OUTPUT pixels, inside `plan`'s card.
    ///
    /// `NormalizedPoint` is already bottom-left — `Normalized.swift`'s own header says the flip
    /// between top-left pixel sources and this space happens in exactly one place,
    /// `NormalizationContext`, on entry — so there is no flip here, and there must not be one: a
    /// second flip here would silently undo the first for every pointer sample drawn.
    ///
    /// `ripplePhase` defaults to `nil` — no click, no ripple — and a caller passes one only when it
    /// has computed one; this function does not derive a phase from anything of its own.
    public static func placement(for point: NormalizedPoint, in plan: RenderPlan,
                                 ripplePhase: Double? = nil,
                                 shape: PointerShape? = nil) -> NormalizedPointerPlacement {
        // The SAME mapping the renderer applies to the content: a pointer drawn at its
        // un-zoomed place while the recording beneath it moved would sit somewhere the
        // user never pointed — `1a98402`'s class arriving through the camera.
        NormalizedPointerPlacement(x: plan.contentX(ofNormalised: point.x),
                                   y: plan.contentY(ofNormalised: point.y),
                                   ripplePhase: ripplePhase, shape: shape)
    }
}
