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

    /// The camera's rectangle in output pixels, given the source's aspect.
    ///
    /// **A circle is square before it is masked.** Fitting a 4:3 camera into a circle by using
    /// its own aspect would give an ellipse; the frame is squared and the source is cropped to
    /// fill it, which is what every video-call application does with a round self-view.
    public func rect(inOutputWidth outputWidth: Int, outputHeight: Int,
                     sourceAspect: Double)
    -> (x: Double, y: Double, width: Double, height: Double) {
        let width = Double(outputWidth) * widthFraction
        let height = shape == .circle
            ? width
            : width / max(sourceAspect, 0.01)
        return (Double(outputWidth) * x - width / 2,
                Double(outputHeight) * y - height / 2,
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
