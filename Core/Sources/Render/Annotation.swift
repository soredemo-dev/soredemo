import Foundation

/// What an annotation is a picture of.
///
/// **Four, and every one of them is a drag from one point to another.** That is the whole
/// interaction model: press where it starts, release where it ends. A shape needing a third
/// point — a curve's control handle, a polygon's next vertex — is a second interaction to
/// explain and a second thing to get wrong on a touchpad, and a Rust recorder's own annotation set stops at
/// the same place for what looks like the same reason.
///
/// **A freehand pen is deliberately absent.** It is the one shape whose data is not two points
/// but a path of hundreds, which changes the storage, the retiming and the hit-testing all at
/// once — and a shaky freehand circle drawn with a trackpad is worse than an ellipse. If it is
/// ever wanted it is its own row, not a fifth case here.
public enum AnnotationShape: String, Hashable, Codable, Sendable, CaseIterable {
    /// A line with a head at the END — the point the drag finished on, which is what a person
    /// was aiming at.
    case arrow
    /// The same line with no head. For underlining, not for pointing.
    case line
    /// The box with the drag's two points as opposite corners.
    case rectangle
    /// The ellipse inscribed in that box. A face, a button, a paragraph — none of them are
    /// rectangles, and `RedactionRegion.isOval` exists for the same reason.
    case ellipse

    public var displayName: String {
        switch self {
        case .arrow: "Arrow"
        case .line: "Line"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        }
    }

    /// Whether this shape encloses an area a fill could go in. An arrow's fill would be the
    /// head only, which reads as a bug rather than as a choice.
    public var canBeFilled: Bool {
        switch self {
        case .arrow, .line: false
        case .rectangle, .ellipse: true
        }
    }
}

/// How an annotation is drawn.
///
/// **Every measurement is a fraction of the OUTPUT, never of the source and never in points.**
/// The same recording is exported at 1920, at 640 for a GIF, and at whatever a portrait variant
/// works out to; a stroke specified in pixels is right in exactly one of them.
///
/// **The fraction is of the output's SHORTER edge**, not its height and not its width. A 3-pixel
/// stroke on a 1920×1080 landscape and on a 1080×1920 portrait should be the same weight to the
/// eye, and only the shorter edge gives that — height alone makes the portrait's strokes nearly
/// twice as heavy, which is exactly the failure `variants` exists to avoid elsewhere.
public struct AnnotationStyle: Hashable, Codable, Sendable {
    /// Stroke weight as a fraction of the output's shorter edge.
    public let strokeWidthFraction: Double
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double
    /// How solidly the interior is filled, for the shapes that have one. `0` is an outline,
    /// which is the default and the useful one: a filled box hides what it is drawing attention
    /// to. A low fill is a highlighter.
    ///
    /// Ignored for `.arrow` and `.line` — see `AnnotationShape.canBeFilled`. Stored rather than
    /// refused so that switching a rectangle to an arrow and back does not silently discard a
    /// value the person chose.
    public let fillOpacity: Double
    /// A drop shadow under the stroke. **The cheapest thing that keeps a coloured line legible
    /// over a screenshot of the same colour**, and here for the reason `TextOverlayStyle`'s
    /// shadow is: an annotation that vanishes into the background is worse than none, because
    /// the recording was made assuming it was visible.
    public let shadowOpacity: Double
    public let shadowBlurFraction: Double

    /// **Red at a weight that reads at 1080p without covering what it points at.** Measured
    /// against the reference recorders rather than picked: a Rust recorder's default annotation stroke is
    /// in the same place relative to the frame, and a stroke at half this is invisible in a
    /// GIF export downscaled to 640.
    public static let `default` = AnnotationStyle(
        strokeWidthFraction: 0.006, red: 0.93, green: 0.16, blue: 0.16, alpha: 1,
        fillOpacity: 0, shadowOpacity: 0.45, shadowBlurFraction: 0.004)

    public init(strokeWidthFraction: Double, red: Double, green: Double, blue: Double,
                alpha: Double, fillOpacity: Double,
                shadowOpacity: Double, shadowBlurFraction: Double) {
        // Clamped rather than trapped, for `TextOverlayStyle`'s reason: every one of these
        // arrives from a slider AND from a decoder, and rule 8 forbids trapping on untrusted
        // input. The stroke's floor is not zero — a zero-width stroke is an annotation that
        // silently does not exist, which is the shape of defect `borderOpacity` was.
        self.strokeWidthFraction = min(max(strokeWidthFraction, 0.0005), 0.08)
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
        self.alpha = min(max(alpha, 0), 1)
        self.fillOpacity = min(max(fillOpacity, 0), 1)
        self.shadowOpacity = min(max(shadowOpacity, 0), 1)
        self.shadowBlurFraction = min(max(shadowBlurFraction, 0), 0.05)
    }

    /// Clamped on the way OUT as well as in, because the synthesised `Decodable` never calls the
    /// initialiser above — rule 8's case, and the same shape `RedactionStyle.clamped` takes.
    public var clamped: AnnotationStyle {
        AnnotationStyle(strokeWidthFraction: strokeWidthFraction, red: red, green: green,
                        blue: blue, alpha: alpha, fillOpacity: fillOpacity,
                        shadowOpacity: shadowOpacity, shadowBlurFraction: shadowBlurFraction)
    }

    /// The stroke in output pixels. Never below one: a stroke rounded to zero is a line nobody
    /// can see and nothing reports.
    public func strokeWidth(forOutputWidth width: Int, outputHeight height: Int) -> Double {
        max(1, Double(min(width, height)) * strokeWidthFraction)
    }

    public func shadowBlur(forOutputWidth width: Int, outputHeight height: Int) -> Double {
        Double(min(width, height)) * shadowBlurFraction
    }

    /// The same style with one field changed. Written once for `TextOverlayStyle`'s reason: an
    /// eight-argument initialiser repeated per slider is eight chances to pass `green` where
    /// `blue` belongs.
    public func changing(strokeWidthFraction: Double? = nil,
                         red: Double? = nil, green: Double? = nil, blue: Double? = nil,
                         alpha: Double? = nil, fillOpacity: Double? = nil,
                         shadowOpacity: Double? = nil) -> AnnotationStyle {
        AnnotationStyle(
            strokeWidthFraction: strokeWidthFraction ?? self.strokeWidthFraction,
            red: red ?? self.red, green: green ?? self.green, blue: blue ?? self.blue,
            alpha: alpha ?? self.alpha, fillOpacity: fillOpacity ?? self.fillOpacity,
            shadowOpacity: shadowOpacity ?? self.shadowOpacity,
            shadowBlurFraction: shadowBlurFraction)
    }
}

/// One annotation to draw on this frame, with both of its points already in OUTPUT pixels.
///
/// **The mapping from the source has already happened, and that is the whole reason this type is
/// separate from `AnnotationItem`.** An annotation is anchored to a place in the RECORDING — the
/// button it points at — so when the camera zooms, it has to move with what it is pointing at.
/// `RenderPlan.contentX(ofNormalised:)` is the one mapping that does this, and it is the same
/// one the drawn cursor goes through (`StagePlanner.placement`); a second implementation of it
/// is how a pointer and an arrow come to disagree about where the same click was.
///
/// **Position follows the content; SIZE does not.** The stroke is a fraction of the output, so
/// zooming to 3× moves the arrow onto its target without making it three times fatter. That is
/// the cursor's convention and not the redaction's: a mosaic is *in* the picture and scales with
/// it, an annotation is drawn *over* the picture and does not. Both are defensible and they are
/// not interchangeable — an arrow that thickened with the zoom would swallow the control it was
/// pointing at exactly when the camera moved in to show it.
public struct AnnotationOverlay: Hashable, Sendable {
    public let shape: AnnotationShape
    /// Output pixels, bottom-left origin — Core Image's space, so nothing downstream flips.
    public let startX: Double
    public let startY: Double
    public let endX: Double
    public let endY: Double
    public let style: AnnotationStyle
    /// The entrance or exit state for this frame — `(1, 1)` when the annotation is simply on.
    /// Reuses `TextAnimation`'s vocabulary rather than inventing a second one; `rise` is dropped
    /// because an annotation is anchored to a place and must not drift away from it while
    /// arriving.
    public let opacity: Double
    public let scale: Double

    public init(shape: AnnotationShape, startX: Double, startY: Double,
                endX: Double, endY: Double, style: AnnotationStyle,
                opacity: Double = 1, scale: Double = 1) {
        self.shape = shape
        self.startX = startX
        self.startY = startY
        self.endX = endX
        self.endY = endY
        self.style = style
        self.opacity = min(max(opacity, 0), 1)
        self.scale = scale
    }

    /// How far apart the two points are, in output pixels.
    public var length: Double {
        (pow(endX - startX, 2) + pow(endY - startY, 2)).squareRoot()
    }

    /// Nothing to draw. A zero-length annotation is what a click that did not become a drag
    /// produces — `RedactionRegion.isEmpty` names the same case for the same reason.
    public var isEmpty: Bool { length <= 0 || opacity <= 0 }

    /// The box the two points bound, as `(x, y, width, height)` in output pixels with a
    /// bottom-left origin.
    ///
    /// **Scalars, not a rect.** Rule 5 confines `CGRect` to the bridge, and a return type of
    /// `CGRect` names it just as surely as a literal does — the check that caught
    /// `RedactionArt.mosaicked` taking one applies here.
    public var boundingBox: (x: Double, y: Double, width: Double, height: Double) {
        (x: min(startX, endX), y: min(startY, endY),
         width: abs(endX - startX), height: abs(endY - startY))
    }
}
