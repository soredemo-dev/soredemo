import Foundation

/// Where the camera sits on the stage and what shape it is.
///
/// **Fractions of the output, as everything else on this stage is.** The same recording is
/// re-rendered at 1920, at 640 for a GIF and at whatever a portrait variant works out to; a
/// camera placed in points is placed correctly in exactly one of them.
///
/// `y` runs from the BOTTOM, matching `TextOverlayStyle` and CoreGraphics, and unlike
/// `RedactionRegion` — which is a rectangle picked off a picture and therefore measured
/// downward. The two conventions live one file apart on purpose; each is right for what it
/// describes, and the conversion happens once where each is drawn.
public struct CameraOverlayStyle: Hashable, Codable, Sendable {
    /// The camera's width as a fraction of the frame's width. Height follows from the source's
    /// aspect for a rectangle, and equals width for a circle.
    public let widthFraction: Double
    /// 0…1 across the frame, to the camera's own centre.
    public let x: Double
    /// 0…1 up from the bottom of the frame, to the camera's own centre.
    public let y: Double
    public let shape: Shape
    /// The corner radius for `.rounded`, as a fraction of the camera's own width.
    public let cornerFraction: Double
    /// **Mirrored by default.** A camera shows a person the reverse of what a viewer sees, and
    /// every video-call application mirrors the self-view for that reason — an unmirrored
    /// preview is the one that looks wrong to the person recording.
    public let isMirrored: Bool
    /// A ring around the camera, which is what separates it from a screenshot behind it.
    public let borderOpacity: Double
    public let shadowOpacity: Double

    public enum Shape: String, Hashable, Codable, Sendable, CaseIterable {
        case circle, rounded, square

        public var displayName: String {
            switch self {
            case .circle: "Circle"
            case .rounded: "Rounded"
            case .square: "Square"
            }
        }
    }

    public static let `default` = CameraOverlayStyle(
        widthFraction: 0.16, x: 0.87, y: 0.16, shape: .circle,
        cornerFraction: 0.18, isMirrored: true, borderOpacity: 0.35, shadowOpacity: 0.45)

    public init(widthFraction: Double, x: Double, y: Double, shape: Shape,
                cornerFraction: Double, isMirrored: Bool,
                borderOpacity: Double, shadowOpacity: Double) {
        // Clamped rather than trapped: sliders and decoders both reach here — rule 8's case.
        self.widthFraction = min(max(widthFraction, 0.05), 0.6)
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
        self.shape = shape
        self.cornerFraction = min(max(cornerFraction, 0), 0.5)
        self.isMirrored = isMirrored
        self.borderOpacity = min(max(borderOpacity, 0), 1)
        self.shadowOpacity = min(max(shadowOpacity, 0), 1)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            widthFraction: try container.decodeIfPresent(Double.self,
                                                         forKey: .widthFraction) ?? 0.16,
            x: try container.decodeIfPresent(Double.self, forKey: .x) ?? 0.87,
            y: try container.decodeIfPresent(Double.self, forKey: .y) ?? 0.16,
            shape: try container.decodeIfPresent(Shape.self, forKey: .shape) ?? .circle,
            cornerFraction: try container.decodeIfPresent(Double.self,
                                                          forKey: .cornerFraction) ?? 0.18,
            isMirrored: try container.decodeIfPresent(Bool.self, forKey: .isMirrored) ?? true,
            borderOpacity: try container.decodeIfPresent(Double.self,
                                                         forKey: .borderOpacity) ?? 0.35,
            shadowOpacity: try container.decodeIfPresent(Double.self,
                                                         forKey: .shadowOpacity) ?? 0.45)
    }

    private enum CodingKeys: String, CodingKey {
        case widthFraction, x, y, shape, cornerFraction, isMirrored, borderOpacity, shadowOpacity
    }

    /// The same style with one field changed — the shape every style in this tier uses, for the
    /// reason `TextOverlayStyle.changing` gives.
    public func changing(widthFraction: Double? = nil, x: Double? = nil, y: Double? = nil,
                         shape: Shape? = nil, cornerFraction: Double? = nil,
                         isMirrored: Bool? = nil, borderOpacity: Double? = nil,
                         shadowOpacity: Double? = nil) -> CameraOverlayStyle {
        CameraOverlayStyle(widthFraction: widthFraction ?? self.widthFraction,
                           x: x ?? self.x, y: y ?? self.y, shape: shape ?? self.shape,
                           cornerFraction: cornerFraction ?? self.cornerFraction,
                           isMirrored: isMirrored ?? self.isMirrored,
                           borderOpacity: borderOpacity ?? self.borderOpacity,
                           shadowOpacity: shadowOpacity ?? self.shadowOpacity)
    }

    /// Nine places a camera is usually put, so a corner is one press rather than two sliders
    /// aimed by eye.
    ///
    /// **Both reference recorders with a webcam offer these.** an Electron recorder's
    /// `getWebcamPositionForPreset` is the same nine and an Electron recorder carries the same list; a
    /// person putting a camera in the bottom-right — which is where almost every camera goes —
    /// should not have to find 0.87 and 0.16 by dragging.
    public enum Position: String, Hashable, Codable, Sendable, CaseIterable {
        case topLeft, topCenter, topRight
        case centerLeft, center, centerRight
        case bottomLeft, bottomCenter, bottomRight

        /// Where the camera's CENTRE goes, in the same fractions `x` and `y` are in. The edge
        /// values are inset by half the camera plus the margin, which `rect` would clamp to
        /// anyway — stated here so a preset and a drag to the same corner agree exactly.
        public var fractions: (x: Double, y: Double) {
            switch self {
            case .topLeft: (0, 1)
            case .topCenter: (0.5, 1)
            case .topRight: (1, 1)
            case .centerLeft: (0, 0.5)
            case .center: (0.5, 0.5)
            case .centerRight: (1, 0.5)
            case .bottomLeft: (0, 0)
            case .bottomCenter: (0.5, 0)
            case .bottomRight: (1, 0)
            }
        }

        public var displayName: String {
            switch self {
            case .topLeft: "Top Left"
            case .topCenter: "Top Center"
            case .topRight: "Top Right"
            case .centerLeft: "Center Left"
            case .center: "Center"
            case .centerRight: "Center Right"
            case .bottomLeft: "Bottom Left"
            case .bottomCenter: "Bottom Center"
            case .bottomRight: "Bottom Right"
            }
        }
    }

    /// The same style, moved to one of the nine. `rect` does the insetting, so an edge preset
    /// lands exactly where a drag into that corner does.
    public func placed(at position: Position) -> CameraOverlayStyle {
        changing(x: position.fractions.x, y: position.fractions.y)
    }

    /// How far the camera is kept from the frame's edge, as a fraction of the output's WIDTH.
    ///
    /// One dimension for both axes so the inset looks the same on all four sides — a fraction
    /// of each axis would be a wider gap at the sides of a 16:9 frame than at the top.
    public static let edgeMarginFraction = 0.025

    /// The camera's rectangle in output pixels, given the source's aspect.
    ///
    /// **A circle is square before it is masked.** Fitting a 4:3 camera into a circle by using
    /// its own aspect would give an ellipse; the frame is squared and the source is cropped to
    /// fill it, which is what every video-call application does with a round self-view.
    ///
    /// **Held inside the frame, which it was not.** `x` and `y` place the camera's CENTRE and
    /// are clamped to 0…1, so `x = 1` hung half a face off the right edge of the export — and
    /// the self-view writes exactly that value when somebody drags into a corner, which is where
    /// people put cameras. an Electron recorder places its overlay inside `container − overlay − margin × 2`
    /// for this reason and an Electron recorder does the same; neither can produce a half-cropped camera
    /// at any setting.
    ///
    /// Clamped rather than remapped, deliberately. Remapping would change what a stored `x`
    /// MEANS, and a project saved before this would open with its camera somewhere else — the
    /// producer-value rule broken to fix a rendering bug. A drag that saturates at the edge is
    /// also what a person dragging expects.
    ///
    /// A camera too big for the frame is centred rather than clamped to a corner: with no room
    /// to satisfy both margins, the symmetric answer is the only one that is not arbitrary.
    public func rect(inOutputWidth outputWidth: Int, outputHeight: Int,
                     sourceAspect: Double)
    -> (x: Double, y: Double, width: Double, height: Double) {
        let width = Double(outputWidth) * widthFraction
        let height = shape == .circle
            ? width
            : width / max(sourceAspect, 0.01)
        let margin = Double(outputWidth) * Self.edgeMarginFraction
        let placedX = Double(outputWidth) * x - width / 2
        let placedY = Double(outputHeight) * y - height / 2
        let maximumX = Double(outputWidth) - margin - width
        let maximumY = Double(outputHeight) - margin - height
        return (maximumX < margin ? (Double(outputWidth) - width) / 2
                                  : min(max(placedX, margin), maximumX),
                maximumY < margin ? (Double(outputHeight) - height) / 2
                                  : min(max(placedY, margin), maximumY),
                width, height)
    }
}

/// The camera's picture on this frame, and how to draw it.
///
/// **A style and nothing else.** The pixels come from a second video track the compositor is
/// handed; carrying them here would put a `CVPixelBuffer` in the deterministic tier, which is
/// the boundary this whole arrangement exists to keep.
public struct CameraOverlay: Hashable, Sendable {
    public let style: CameraOverlayStyle

    public init(style: CameraOverlayStyle) {
        self.style = style
    }
}
