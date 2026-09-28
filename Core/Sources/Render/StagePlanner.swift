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
        let fittedWidth = min(available.w, available.h * sourceAspect)
        let fittedHeight = fittedWidth / sourceAspect

        // **Snapped to whole output pixels.** A card whose edge falls at x = 113.6 is drawn
        // with every source pixel resampled at a 0.6 px phase, which at a 1:1 scale turns a
        // crisp screenshot into a uniformly soft one — the worst case being exactly the
        // export a person asked for at the recording's own size. The snap costs at most
        // half a pixel of aspect, below anything visible; it is applied to the size first
        // and the origin second so the card stays centred to the same half pixel.
        let cardWidth = max(fittedWidth.rounded(), 2)
        let cardHeight = max(fittedHeight.rounded(), 2)
        let card = StageRect(x: ((output.w - cardWidth) / 2).rounded(),
                             y: ((output.h - cardHeight) / 2).rounded(),
                             width: cardWidth, height: cardHeight)
        // A radius larger than half the shorter side is not a rounder rectangle, it is an
        // undefined one. Clamped here so no renderer has to decide.
        let radius = min(style.cornerRadius, min(cardWidth, cardHeight) / 2)

        // **A device frame replaces the card rather than surrounding it.** The recording draws
        // into `card`, so with a body around it the card must BE the screen — otherwise the
        // picture would fill the whole device including its bezel. The body is fitted into the
        // same space the plain card would have had, so a stage does not grow when a frame is
        // turned on, and the screen's own corner radius replaces the style's: a device's corners
        // are the device's, not a slider's.
        if let model = style.deviceModel,
           let placed = DeviceFrame.placement(
               model: model, finish: style.deviceFinish,
               availableWidth: available.w, availableHeight: available.h,
               centreX: output.w / 2, centreY: output.h / 2, sourceAspect: sourceAspect) {
            return RenderPlan(outputWidth: outputWidth, outputHeight: outputHeight,
                              card: placed.screen, cornerRadius: placed.screenCornerRadius,
                              style: style, pointer: pointer, deviceFrame: placed)
        }
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
                                 shape: PointerShape? = nil,
                                 hotspot: NormalizedPoint? = nil,
                                 opacity: Double = 1,
                                 tiltDegrees: Double = 0,
                                 smearRadius: Double = 0,
                                 smearAngle: Double = 0,
                                 pressScale: Double = 1) -> NormalizedPointerPlacement {
        // The SAME mapping the renderer applies to the content: a pointer drawn at its
        // un-zoomed place while the recording beneath it moved would sit somewhere the
        // user never pointed — `1a98402`'s class arriving through the camera.
        // …and then the SAME turn the card takes, for the same reason: on a leaned or turned card
        // the flat position is somewhere the picture no longer is. See `StageTilt.project`.
        let placed = plan.style.tilt.project(
            StagePoint(x: plan.contentX(ofNormalised: point.x), y: plan.contentY(ofNormalised: point.y)),
            on: plan.card)
        return NormalizedPointerPlacement(x: placed.x, y: placed.y,
                                          ripplePhase: ripplePhase, shape: shape, hotspot: hotspot,
                                          opacity: opacity, tiltDegrees: tiltDegrees,
                                          smearRadius: smearRadius, smearAngle: smearAngle,
                                          pressScale: pressScale)
    }
}
