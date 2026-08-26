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
    /// The preset this camera sits on, or `nil` when it was placed by hand.
    ///
    /// **a Rust recorder's arrangement, and it is the right one.** Its `Camera` carries a `position` enum
    /// AND an `Option<XY<f64>> manual_position` that overrides it when set. Baking a preset into
    /// coordinates — which is what this did — means "bottom right" stops being bottom right the
    /// moment the size changes, and the control that set it stops looking chosen. A preset that
    /// stays a preset is re-evaluated against whatever the camera's size is now.
    public let position: Position?
    /// Whether the camera is drawn at all.
    ///
    /// **Off, not deleted.** a Rust recorder's `Camera.hide` exists because "I do not want my face in this
    /// one" and "throw away the footage of my face" are different decisions, and only one of them
    /// is reversible. Turning the track off leaves the file in the package and the switch where
    /// somebody can change their mind.
    public let isHidden: Bool
    /// How much of its size the camera keeps while the stage is zoomed in, 0…1.
    ///
    /// **A zoom makes the picture bigger and the camera should not stay put.** The stage zooms
    /// into a click; a camera that holds its full width is covering a larger share of a smaller
    /// area, which is exactly when it is most in the way. a Rust recorder models this as `scale_during_zoom`
    /// and defaults it to 0.7, which is carried over rather than re-guessed. `1` holds the size,
    /// which is what this did before the field existed.
    public let scaleDuringZoom: Double
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
    /// **Move out of the cursor's way** — see `CameraDodge`, which owns the rules. Off by
    /// default for the reason every other option here is: a saved project must look as it did.
    public let avoidsCursor: Bool

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

    /// **`position` is `.bottomRight` here and `nil` in the decoder, and the difference is the
    /// point.** A new recording starts on the preset, so moving the camera's size keeps it in the
    /// corner. A project saved before this field existed has coordinates and no preset, and
    /// honouring those coordinates is the only reading that does not move somebody's camera.
    public static let `default` = CameraOverlayStyle(
        widthFraction: 0.16, x: 0.87, y: 0.16, position: .bottomRight, isHidden: false,
        scaleDuringZoom: 0.7, shape: .circle,
        cornerFraction: 0.18, isMirrored: true, borderOpacity: 0.35, shadowOpacity: 0.45)

    public init(widthFraction: Double, x: Double, y: Double,
                position: Position? = nil, isHidden: Bool = false,
                scaleDuringZoom: Double = 1, shape: Shape,
                cornerFraction: Double, isMirrored: Bool,
                borderOpacity: Double, shadowOpacity: Double,
                avoidsCursor: Bool = false) {
        self.position = position
        self.isHidden = isHidden
        // Clamped like every other field — rule 8's case, and a zoom scale of zero would be a
        // camera that vanishes on the first click.
        self.scaleDuringZoom = min(max(scaleDuringZoom, 0.1), 1)
        // Clamped rather than trapped: sliders and decoders both reach here — rule 8's case.
        self.widthFraction = min(max(widthFraction, 0.05), 0.6)
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
        self.shape = shape
        self.cornerFraction = min(max(cornerFraction, 0), 0.5)
        self.isMirrored = isMirrored
        self.borderOpacity = min(max(borderOpacity, 0), 1)
        self.shadowOpacity = min(max(shadowOpacity, 0), 1)
        self.avoidsCursor = avoidsCursor
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            widthFraction: try container.decodeIfPresent(Double.self,
                                                         forKey: .widthFraction) ?? 0.16,
            x: try container.decodeIfPresent(Double.self, forKey: .x) ?? 0.87,
            y: try container.decodeIfPresent(Double.self, forKey: .y) ?? 0.16,
            // **`nil`, not `.default`'s `.bottomRight`.** A project written before this field
            // existed carries coordinates and no preset, and the only reading that does not move
            // somebody's camera is to honour the coordinates.
            position: try container.decodeIfPresent(Position.self, forKey: .position),
            isHidden: try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false,
            // `1` for the same reason: a project written before this held its size through a
            // zoom, and opening it must not shrink the camera somebody had placed.
            scaleDuringZoom: try container.decodeIfPresent(Double.self,
                                                           forKey: .scaleDuringZoom) ?? 1,
            shape: try container.decodeIfPresent(Shape.self, forKey: .shape) ?? .circle,
            cornerFraction: try container.decodeIfPresent(Double.self,
                                                          forKey: .cornerFraction) ?? 0.18,
            isMirrored: try container.decodeIfPresent(Bool.self, forKey: .isMirrored) ?? true,
            borderOpacity: try container.decodeIfPresent(Double.self,
                                                         forKey: .borderOpacity) ?? 0.35,
            shadowOpacity: try container.decodeIfPresent(Double.self,
                                                         forKey: .shadowOpacity) ?? 0.45,
            avoidsCursor: try container.decodeIfPresent(Bool.self, forKey: .avoidsCursor) ?? false)
    }

    private enum CodingKeys: String, CodingKey {
        case widthFraction, x, y, position, isHidden, scaleDuringZoom, shape, cornerFraction
        case isMirrored, borderOpacity, shadowOpacity, avoidsCursor
    }

    /// The same style with one field changed — the shape every style in this tier uses, for the
    /// reason `TextOverlayStyle.changing` gives.
    /// **Moving by hand clears the preset**, because it is no longer on one. `position` is not
    /// reachable through this for that reason — `placed(at:)` sets it and a coordinate clears it,
    /// so the two cannot both claim to be where the camera is.
    public func changing(widthFraction: Double? = nil, x: Double? = nil, y: Double? = nil,
                         isHidden: Bool? = nil, scaleDuringZoom: Double? = nil,
                         shape: Shape? = nil, cornerFraction: Double? = nil,
                         isMirrored: Bool? = nil, borderOpacity: Double? = nil,
                         shadowOpacity: Double? = nil,
                         avoidsCursor: Bool? = nil) -> CameraOverlayStyle {
        CameraOverlayStyle(widthFraction: widthFraction ?? self.widthFraction,
                           x: x ?? self.x, y: y ?? self.y,
                           position: (x == nil && y == nil) ? self.position : nil,
                           isHidden: isHidden ?? self.isHidden,
                           scaleDuringZoom: scaleDuringZoom ?? self.scaleDuringZoom,
                           shape: shape ?? self.shape,
                           cornerFraction: cornerFraction ?? self.cornerFraction,
                           isMirrored: isMirrored ?? self.isMirrored,
                           borderOpacity: borderOpacity ?? self.borderOpacity,
                           shadowOpacity: shadowOpacity ?? self.shadowOpacity,
                           avoidsCursor: avoidsCursor ?? self.avoidsCursor)
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
    ///
    /// The coordinates are written too, so anything reading `x`/`y` without knowing about
    /// presets — the self-view's panel placement, a saved project opened by an older build —
    /// still puts the camera in the right corner.
    public func placed(at position: Position) -> CameraOverlayStyle {
        CameraOverlayStyle(widthFraction: widthFraction,
                           x: position.fractions.x, y: position.fractions.y,
                           position: position, isHidden: isHidden,
                           scaleDuringZoom: scaleDuringZoom, shape: shape,
                           cornerFraction: cornerFraction, isMirrored: isMirrored,
                           borderOpacity: borderOpacity, shadowOpacity: shadowOpacity,
                           avoidsCursor: avoidsCursor)
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
    ///
    /// `contentZoom` is the stage's zoom for this frame; the camera keeps `scaleDuringZoom` of
    /// its width while the stage is zoomed in, interpolated so it shrinks as the zoom rises
    /// rather than snapping the moment a zoom starts.
    public func rect(inOutputWidth outputWidth: Int, outputHeight: Int,
                     sourceAspect: Double, contentZoom: Double = 1)
    -> (x: Double, y: Double, width: Double, height: Double) {
        // a Rust recorder's own default is 0.7 AT the zoom; between 1× and the zoom in force the camera
        // walks down to it, so a gentle zoom moves the camera a little and a hard one moves it
        // a lot. A snap at the first frame of a zoom would read as a glitch.
        let zoomed = max(contentZoom, 1)
        let shrink = zoomed <= 1 ? 1 : scaleDuringZoom + (1 - scaleDuringZoom) / zoomed
        let placement = position?.fractions ?? (x: x, y: y)
        let x = placement.x
        let y = placement.y
        let widthFraction = self.widthFraction * shrink
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
