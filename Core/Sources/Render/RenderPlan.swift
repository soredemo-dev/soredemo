import Foundation
import Geometry
// `PointerShape` rides on the placement since the recorder-parity work.
import Project

/// A rectangle in OUTPUT PIXELS, bottom-left origin.
///
/// Not `CGRect`: the package may not name Core Graphics types (D6 rule 2, enforced by the
/// plugin on every build), and the reason is not stylistic — `CGRect` in the package is how a
/// pixel value crosses a module boundary without anyone converting it.
public struct StageRect: Hashable, Codable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        precondition(x.isFinite && y.isFinite && width.isFinite && height.isFinite,
                     "StageRect requires finite components, got \(x) \(y) \(width) \(height)")
        precondition(width >= 0 && height >= 0,
                     "StageRect requires non-negative extent, got \(width)x\(height)")
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

extension StageRect {
    /// Matches the synthesised shape exactly — `x`, `y`, `width`, `height` — so
    /// this hand-written conformance changes validation, not the wire form. Same
    /// shape as `HostRange.init(from:)` / `DisplayGeometry.init(from:)`: rule 8
    /// (ARCHITECTURE.md D6, D2-14) requires a validating decoder initialiser on any
    /// `Codable` type whose memberwise `init` preconditions, because the synthesised
    /// `init(from:)` assigns stored properties directly and never calls it. The
    /// architecture-checker plugin refuses a `StageRect` written without it.
    private enum CodingKeys: String, CodingKey {
        case x, y, width, height
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let x = try container.decode(Double.self, forKey: .x)
        let y = try container.decode(Double.self, forKey: .y)
        let width = try container.decode(Double.self, forKey: .width)
        let height = try container.decode(Double.self, forKey: .height)
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "StageRect requires finite components, got \(x) \(y) \(width) \(height)"))
        }
        guard width >= 0 && height >= 0 else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "StageRect requires non-negative extent, got \(width)x\(height)"))
        }
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
    }
}

/// What sits behind the recorded card.
///
/// **The gradient case is why this is an enum and not three colour fields.** A solid
/// background is what the first renderer could draw, and it is what makes a recording look
/// like a screenshot on a coloured rectangle. Every comparable tool — Screen Studio, a Rust recorder,
/// `../opensource/a Swift recorder` — defaults to a gradient, because the card's shadow has
/// nothing to fall across on a flat fill and the frame reads as unfinished. Adding the case
/// here rather than a `isGradient` flag beside the colours keeps a solid background costing
/// no gradient filter at all, which `aSolidBackgroundDrawsNoGradient` pins.
public enum StageBackground: Hashable, Codable, Sendable {
    case solid(red: Double, green: Double, blue: Double)
    /// Two colours interpolated along a line at `angleDegrees`, measured counter-clockwise
    /// from the +x axis so 0° runs left→right and 90° bottom→top — the CoreImage convention
    /// the renderer works in, stated here so the value means one thing wherever it is read.
    ///
    /// **Interpolated in the working colour space, not in sRGB gamma.** A gradient between
    /// two saturated colours mixed in gamma space passes through a desaturated band in the
    /// middle; the renderer uses `CISmoothLinearGradient`, whose easing also removes the
    /// Mach banding a linear ramp shows on a flat fill.
    case linearGradient(startRed: Double, startGreen: Double, startBlue: Double,
                        endRed: Double, endGreen: Double, endBlue: Double,
                        angleDegrees: Double)

    /// A picture behind the card, by its filename inside the project package.
    ///
    /// **A filename, not a path.** An absolute path is a background that works until the file
    /// is moved, renamed, or the project is opened on another machine — and a wallpaper that
    /// silently becomes black is worse than one that was never offered. The chosen image is
    /// copied into `<package>/backgrounds/` when it is picked, so the background travels with
    /// the recording exactly as the media and the observation log already do.
    ///
    /// **No path separators.** This name is joined to a directory by a renderer; a value
    /// carrying `../` would reach outside the package. `Codable` cannot be trusted to hand back
    /// what was written, so the decoder rejects it — rule 8's case.
    case image(filename: String)

    /// **Nothing behind the card at all, so the export carries a hole rather than a colour.**
    ///
    /// The one thing the competitor everybody compares this app to is publicly criticised for
    /// lacking, alongside device frames — both named in the same sentence, about product demos
    /// and app showcases. A transparent export is what lets a rounded, shadowed recording be
    /// dropped onto a landing page, into Final Cut over a brand colour, or over another clip,
    /// without anybody keying out a background that was never wanted.
    ///
    /// **It is a property of the picture, not of the export**, which is why it lives here beside
    /// the colours rather than in `ExportPreset`. Somebody choosing it sees the checkerboard in
    /// the preview immediately, and the shadow they have set falls on nothing — which is worth
    /// seeing before an export rather than after one.
    ///
    /// **Only two codecs can carry it**, and choosing one that cannot does not fail: it hands
    /// back a black rectangle with nothing reported. `TransparentExport` turns that into a
    /// refusal with a name; `ExportCodec.carriesTransparency` is the property it reads.
    case transparent

    /// The presets the picker offers. Named rather than anonymous tuples because a project
    /// records which one was chosen and a name survives a value being retuned.
    public static let presets: [(name: String, background: StageBackground)] = [
        ("Charcoal", .solid(red: 0.09, green: 0.09, blue: 0.11)),
        ("Dusk", .linearGradient(startRed: 0.10, startGreen: 0.11, startBlue: 0.22,
                                 endRed: 0.35, endGreen: 0.16, endBlue: 0.36,
                                 angleDegrees: 115)),
        ("Ember", .linearGradient(startRed: 0.38, startGreen: 0.13, startBlue: 0.20,
                                  endRed: 0.86, endGreen: 0.44, endBlue: 0.22,
                                  angleDegrees: 70)),
        ("Tide", .linearGradient(startRed: 0.05, startGreen: 0.24, startBlue: 0.33,
                                 endRed: 0.16, endGreen: 0.55, endBlue: 0.52,
                                 angleDegrees: 60)),
        ("Paper", .linearGradient(startRed: 0.93, startGreen: 0.92, startBlue: 0.89,
                                  endRed: 0.82, endGreen: 0.83, endBlue: 0.85,
                                  angleDegrees: 100)),
    ]

    /// The directory an image background's file lives in, inside the package.
    public static let imageDirectory = "backgrounds"

    /// True when `filename` is a plain name this type will accept.
    ///
    /// Rejects anything with a separator or a leading dot: the name is joined to a directory by
    /// whoever draws it, and `../../etc/passwd` is a filename as far as a string is concerned.
    public static func isSafeImageFilename(_ filename: String) -> Bool {
        !filename.isEmpty
            && !filename.hasPrefix(".")
            && !filename.contains("/")
            && !filename.contains("\\")
    }

    public init(from decoder: any Decoder) throws {
        // Hand-written so the image case can be validated. The other two are value-only and
        // decode exactly as the synthesised conformance would.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // **Checked by presence, because this case carries nothing to decode.** The synthesised
        // encoder writes an empty nested container under the key, so `contains` is the whole
        // question — `decodeIfPresent` would need a payload type that does not exist.
        if container.contains(.transparent) {
            self = .transparent
        } else if let solid = try container.decodeIfPresent(Solid.self, forKey: .solid) {
            self = .solid(red: solid.red, green: solid.green, blue: solid.blue)
        } else if let gradient = try container.decodeIfPresent(Gradient.self,
                                                               forKey: .linearGradient) {
            self = .linearGradient(startRed: gradient.startRed, startGreen: gradient.startGreen,
                                   startBlue: gradient.startBlue, endRed: gradient.endRed,
                                   endGreen: gradient.endGreen, endBlue: gradient.endBlue,
                                   angleDegrees: gradient.angleDegrees)
        } else if let image = try container.decodeIfPresent(ImageName.self, forKey: .image) {
            guard Self.isSafeImageFilename(image.filename) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "a background image filename may not contain a path: "
                        + image.filename))
            }
            self = .image(filename: image.filename)
        } else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath, debugDescription: "no known background case"))
        }
    }

    private enum CodingKeys: String, CodingKey { case solid, linearGradient, image, transparent }
    private struct Solid: Codable { let red, green, blue: Double }
    private struct Gradient: Codable {
        let startRed, startGreen, startBlue, endRed, endGreen, endBlue, angleDegrees: Double
    }
    private struct ImageName: Codable { let filename: String }
}

public struct StageStyle: Hashable, Codable, Sendable {
    public let insetFraction: Double
    public let cornerRadius: Double
    public let shadowRadius: Double
    public let shadowOpacity: Double
    public let background: StageBackground
    /// **A hairline light edge around the card, off by default.**
    ///
    /// What it is for: a shadow separates the card from the background by darkening what is
    /// behind it, which works everywhere except at the corners, where the card's own edge meets
    /// the shadow's softest part. A one-pixel light edge is what interface chrome uses there,
    /// and a Rust recorder offers it beside the shadow for the same reason.
    ///
    /// **Light, not a colour of its own.** A border that could be any colour is a second
    /// background control, and the job here is edge definition rather than decoration — which a
    /// light edge does over every background this app ships. Its honest limitation, said rather
    /// than discovered: over a pale wallpaper it does nothing, and the shadow is the control
    /// that works there.
    public let borderOpacity: Double
    /// The device body drawn around the recording, or `nil` for none.
    ///
    /// **Absent by default and for every recording made on a Mac.** A Mac screen inside an iPad
    /// is nonsense; this is offered for a phone recording and chosen by a person, never assumed.
    public let deviceModel: DeviceFrame.Model?
    /// The body's finish. Kept even while `deviceModel` is `nil`, so turning a frame off and on
    /// again returns the one somebody picked rather than the default.
    public let deviceFinish: DeviceFrame.Finish

    /// How much the background PICTURE is blurred, from 0 to 1.
    ///
    /// **For a wallpaper, which is what makes it worth having.** Somebody's desktop picture is a
    /// photograph: it has a horizon, a face, a logo, and all of that competes with the recording
    /// sitting on top of it. Blurred, the same picture keeps its colours and its light and stops
    /// being a picture — which is the whole reason Screen Studio puts this slider directly under
    /// its wallpaper grid rather than in a settings panel.
    ///
    /// **A blur here is nothing like the one `Redaction` refuses.** That refusal is a security
    /// argument: a Gaussian is a convolution, a convolution with a known kernel is reversible,
    /// and something hidden behind one is not hidden. Nothing is hidden behind a wallpaper.
    ///
    /// **It does nothing to a solid colour or a gradient, and that is arithmetic rather than a
    /// rule.** A blur is a weighted average of neighbours; on a flat fill every neighbour is the
    /// same colour, and on a smooth gradient the average of a symmetric neighbourhood is the
    /// value at its centre. So the slider is only offered where it changes something, and the
    /// renderer skips the pass rather than paying for one that cannot be seen.
    public let backgroundBlur: Double

    public static let `default` = StageStyle(
        insetFraction: 0.06, cornerRadius: 18, shadowRadius: 32, shadowOpacity: 0.35,
        background: .solid(red: 0.09, green: 0.09, blue: 0.11))

    public init(insetFraction: Double, cornerRadius: Double, shadowRadius: Double,
                shadowOpacity: Double, background: StageBackground,
                borderOpacity: Double = 0,
                deviceModel: DeviceFrame.Model? = nil,
                deviceFinish: DeviceFrame.Finish = .graphite,
                backgroundBlur: Double = 0) {
        precondition(insetFraction >= 0 && insetFraction < 0.5,
                     "insetFraction must be in [0, 0.5), got \(insetFraction)")
        self.insetFraction = insetFraction
        self.cornerRadius = cornerRadius
        self.shadowRadius = shadowRadius
        self.shadowOpacity = shadowOpacity
        self.background = background
        // Clamped rather than trapped: it arrives from a slider and from a decoder.
        self.borderOpacity = min(max(borderOpacity, 0), 1)
        self.deviceModel = deviceModel
        self.deviceFinish = deviceFinish
        // Clamped for the same reason `borderOpacity` is: a slider and a decoder both reach here.
        self.backgroundBlur = min(max(backgroundBlur.isFinite ? backgroundBlur : 0, 0), 1)
    }
}

extension StageStyle {
    /// Matches the synthesised shape exactly — `insetFraction`, `cornerRadius`,
    /// `shadowRadius`, `shadowOpacity`, `background` — so this hand-written
    /// conformance changes validation, not the wire form. Same rule-8 reason as
    /// `StageRect.init(from:)` above.
    private enum CodingKeys: String, CodingKey {
        case insetFraction, cornerRadius, shadowRadius, shadowOpacity, background
        case borderOpacity
        case deviceModel, deviceFinish
        case backgroundBlur
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let insetFraction = try container.decode(Double.self, forKey: .insetFraction)
        let cornerRadius = try container.decode(Double.self, forKey: .cornerRadius)
        let shadowRadius = try container.decode(Double.self, forKey: .shadowRadius)
        let shadowOpacity = try container.decode(Double.self, forKey: .shadowOpacity)
        let background = try container.decode(StageBackground.self, forKey: .background)
        // **Absent is zero, not an error.** Every project written before the border existed has
        // no such key, and refusing them would make a cosmetic addition a file-format break.
        let borderOpacity = try container.decodeIfPresent(Double.self, forKey: .borderOpacity) ?? 0
        guard insetFraction >= 0 && insetFraction < 0.5 else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "insetFraction must be in [0, 0.5), got \(insetFraction)"))
        }
        self.insetFraction = insetFraction
        self.cornerRadius = cornerRadius
        self.shadowRadius = shadowRadius
        self.shadowOpacity = shadowOpacity
        self.background = background
        self.borderOpacity = min(max(borderOpacity, 0), 1)
        // Absent is zero, for the border's reason: every project written before this existed has
        // no such key, and a sharp wallpaper is what those projects were exported with.
        self.backgroundBlur = min(max(
            try container.decodeIfPresent(Double.self, forKey: .backgroundBlur) ?? 0, 0), 1)
        // **A model this build does not know decodes as no frame, not as a failure.** A project
        // written by a later version that has learned about another device must still open; the
        // body is the only thing lost. Same shape as `MobileScreen.Source`'s family, for the
        // same reason — the synthesised decoder for a raw-value enum throws on a value it does
        // not recognise.
        self.deviceModel = try? container.decodeIfPresent(DeviceFrame.Model.self,
                                                          forKey: .deviceModel)
        self.deviceFinish = (try? container.decodeIfPresent(DeviceFrame.Finish.self,
                                                            forKey: .deviceFinish)) ?? .graphite
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(insetFraction, forKey: .insetFraction)
        try container.encode(cornerRadius, forKey: .cornerRadius)
        try container.encode(shadowRadius, forKey: .shadowRadius)
        try container.encode(shadowOpacity, forKey: .shadowOpacity)
        try container.encode(background, forKey: .background)
        // Only when it is on: a zero written into every project would make the default look
        // like a decision somebody made.
        if borderOpacity > 0 { try container.encode(borderOpacity, forKey: .borderOpacity) }
        // Same rule, and the omission was caught by a round-trip test rather than by anybody
        // remembering: this encoder is hand-written, so a field added to the type and not to
        // THIS function is written nowhere and read back as its default — silently, and only in
        // somebody's saved project. It is the third time this shape of defect has appeared here,
        // after `StageStylePicker.apply` and `CameraOverlayStyle.changing`.
        if backgroundBlur > 0 { try container.encode(backgroundBlur, forKey: .backgroundBlur) }
        // The finish only when there is a body to finish, for the same reason: a project with no
        // device frame has nothing to say about what colour it is not.
        if let deviceModel {
            try container.encode(deviceModel, forKey: .deviceModel)
            try container.encode(deviceFinish, forKey: .deviceFinish)
        }
    }
}

/// **How much the content moved during this frame's exposure, in output pixels.** A frame
/// is not an instant; a camera panning at speed across a still recording shows a hard edge
/// every 16 ms that the eye reads as judder, and a real camera would have smeared it. This
/// is the smear, and it is a WHAT: a length along an axis, and a radial length about a
/// point, both already in pixels, so the renderer draws it without knowing a frame rate.
///
/// The compositor derives it from `CameraState`'s velocities and the composition's frame
/// duration; `Render` does not know either, which is why this carries pixels rather than
/// speeds. `nil` on a still frame, so a frame with no motion costs no filter.
public struct MotionBlur: Hashable, Sendable {
    /// Half the pan smear's length, in output pixels — the radius a directional blur takes.
    public let panRadius: Double
    /// The pan's direction, radians counter-clockwise from +x, in the bottom-left-origin
    /// space the renderer draws in.
    public let panAngle: Double
    /// The zoom smear at the card's edge, in output pixels, about `centreX`/`centreY`.
    public let zoomAmount: Double
    public let centreX: Double
    public let centreY: Double

    public init(panRadius: Double, panAngle: Double, zoomAmount: Double,
                centreX: Double, centreY: Double) {
        precondition(panRadius.isFinite && panAngle.isFinite && zoomAmount.isFinite
                     && centreX.isFinite && centreY.isFinite,
                     "MotionBlur requires finite components")
        self.panRadius = max(panRadius, 0)
        self.panAngle = panAngle
        self.zoomAmount = max(zoomAmount, 0)
        self.centreX = centreX
        self.centreY = centreY
    }
}

/// Everything a renderer needs to draw one frame, and nothing about HOW.
///
/// The pointer is optional because the track can be silent — see `PointerTrack.position(at:)`
/// and `BlindInterval`. A `nil` pointer means "draw none", never "draw the last one".
public struct RenderPlan: Hashable, Sendable {
    public let outputWidth: Int
    public let outputHeight: Int
    public let card: StageRect
    public let cornerRadius: Double
    public let style: StageStyle
    public let pointer: NormalizedPointerPlacement?

    /// **The camera, as two plain numbers rather than a type.** `CameraState` lives in
    /// `Framing`, and `Render` does not depend on it — nor should it: `Render` is the
    /// deterministic planning tier and `Framing` is a sibling, so a type here would be an
    /// edge in the wrong direction. `Compositing` depends on both and does the conversion.
    ///
    /// The zoom applies to the CONTENT inside the card, never to the card itself: the
    /// rounded window stays where the stage style put it and the recording inside it grows.
    /// Scaling the card would break the inset margin that style exists to keep.
    public let contentZoom: Double
    /// The point in normalised SOURCE coordinates the camera is centred on.
    public let contentCentre: NormalizedPoint

    /// The caption to burn into this frame, or `nil` for none. Resolved per frame rather than
    /// per clip because a caption changes several times a second and the plan is what a frame
    /// is drawn from.
    public let caption: CaptionOverlay?
    /// Text overlays on this frame, back to front. Several at once, unlike the caption: two
    /// captions on screen is a bug and a title over a lower third is a layout.
    public let texts: [TextOverlay]
    /// Parts of the SOURCE to hide, in the source's own normalised coordinates. Applied before
    /// the camera moves the picture — see `RedactionArt`.
    public let redactions: [RedactionRegion]
    /// How the drawn cursor looks. Carried on the plan rather than read from a static by the
    /// renderer, so a frame's appearance is a function of its plan — which is what makes a
    /// render reproducible from one.
    public let cursorStyle: CursorStyle
    /// The camera's placement, or `nil` when this recording has no camera or it is turned off.
    /// The PIXELS come from a second video track the compositor reads; this is only where they
    /// go and what shape they are.
    public let camera: CameraOverlay?
    /// The part of the recording used at all. `.whole` for an uncropped one — see `CropRect`.
    public let crop: CropRect
    /// The content's smear for this frame, or `nil` when the camera is still — see
    /// `MotionBlur`. Applies to the content inside the card only: the card, the stage and
    /// every overlay are not moving.
    public let motionBlur: MotionBlur?
    /// The shortcut badge on this frame, or `nil` — see `KeystrokeBadge`. Drawn above the
    /// caption and below the titles, like the caption a viewer reads alongside.
    public let keystroke: KeystrokeBadge?
    /// The arrows, lines, boxes and ellipses on this frame, with their points already mapped
    /// into OUTPUT pixels — see `AnnotationOverlay`, which explains why that mapping happens
    /// before the plan rather than inside the renderer.
    ///
    /// **Above the content and below the titles.** An annotation points at something in the
    /// recording, so it must sit over the picture; a title is about the whole frame, so it sits
    /// over everything. Drawing them the other way round hides an arrow under a lower third
    /// exactly when both are on screen, which is the moment they are both being used.
    public let annotations: [AnnotationOverlay]
    /// The device body drawn behind the card, when the style asks for one.
    ///
    /// **Carried as a placement rather than as a model.** Where the body goes depends on the
    /// output size, the inset and the recording's aspect — all of which `StagePlanner` already
    /// has and no renderer should have to re-derive. Two renderers computing it separately would
    /// be two chances to disagree about where a screen sits inside its bezel.
    public let deviceFrame: DeviceFrame.Placement?

    public init(outputWidth: Int, outputHeight: Int, card: StageRect, cornerRadius: Double,
                style: StageStyle, pointer: NormalizedPointerPlacement?,
                contentZoom: Double = 1.0,
                contentCentre: NormalizedPoint = NormalizedPoint(x: 0.5, y: 0.5),
                caption: CaptionOverlay? = nil,
                texts: [TextOverlay] = [],
                redactions: [RedactionRegion] = [],
                cursorStyle: CursorStyle = .default,
                camera: CameraOverlay? = nil,
                crop: CropRect = .whole,
                motionBlur: MotionBlur? = nil,
                keystroke: KeystrokeBadge? = nil,
                annotations: [AnnotationOverlay] = [],
                deviceFrame: DeviceFrame.Placement? = nil) {
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.card = card
        self.cornerRadius = cornerRadius
        self.style = style
        self.pointer = pointer
        self.contentZoom = contentZoom
        self.contentCentre = contentCentre
        self.caption = caption
        self.texts = texts
        self.redactions = redactions
        self.cursorStyle = cursorStyle
        self.camera = camera
        self.crop = crop
        self.motionBlur = motionBlur
        self.keystroke = keystroke
        self.annotations = annotations
        self.deviceFrame = deviceFrame
    }
}

/// Where the drawn pointer goes, in OUTPUT pixels, with the click state that decides the ripple.
public struct NormalizedPointerPlacement: Hashable, Sendable {
    public let x: Double
    public let y: Double
    /// 0 at the click instant, rising to 1 as the ripple finishes. `nil` when not clicking.
    public let ripplePhase: Double?
    /// How much smaller to draw the cursor because a button is down or has just come up — see
    /// `CursorPress`. `1` when nothing is pressed, so a caller multiplies unconditionally.
    public let pressScale: Double
    /// The classified system-cursor shape at the sample being drawn; `nil` is
    /// "unrecorded" and renders as the arrow, same as `.other` — see `PointerShape`.
    public let shape: PointerShape?
    /// Where inside the drawn art its own hotspot sits, 0…1 of the art's bounding box.
    /// `nil` falls back to the art's path origin, which is right for the arrow and wrong
    /// for everything else — see `PointerSample.hotspot`.
    public let hotspot: NormalizedPoint?
    /// 1 drawn fully, 0 not at all — the idle fade. Clamped on the way in.
    public let opacity: Double
    /// The lean, degrees, positive to the right — see `CursorTilt`.
    public let tiltDegrees: Double
    /// Half the cursor's own smear for this frame, in output pixels, and the direction it
    /// travelled. **A frame is one exposure**: the card smears under `MotionBlur` when the
    /// camera moves, and a cursor crossing that same frame smears under the same shutter.
    /// Zero when it is not moving far enough to be worth a filter.
    public let smearRadius: Double
    public let smearAngle: Double

    public init(x: Double, y: Double, ripplePhase: Double?, shape: PointerShape? = nil,
                hotspot: NormalizedPoint? = nil, opacity: Double = 1, tiltDegrees: Double = 0,
                smearRadius: Double = 0, smearAngle: Double = 0,
                pressScale: Double = 1) {
        self.x = x; self.y = y; self.ripplePhase = ripplePhase
        // Clamped to something a cursor can still be seen at. A decoded or miscomputed zero
        // would draw nothing and read as the cursor disappearing on click, which is worse than
        // a press that is too small.
        self.pressScale = pressScale.isFinite ? min(max(pressScale, 0.2), 2) : 1
        self.shape = shape; self.hotspot = hotspot
        self.opacity = opacity.isFinite ? min(max(opacity, 0), 1) : 1
        self.tiltDegrees = tiltDegrees.isFinite ? tiltDegrees : 0
        self.smearRadius = smearRadius.isFinite ? max(smearRadius, 0) : 0
        self.smearAngle = smearAngle.isFinite ? smearAngle : 0
    }
}


extension RenderPlan {
    /// Where a normalised source x lands in output pixels, under the camera. **One owner
    /// for the mapping**: the renderer transforms the image by this and `StagePlanner`
    /// places the pointer by it, so the two cannot drift into disagreeing about where a
    /// point is (`thePointerMovesWithTheZoomedContent`).
    ///
    /// At zoom `z` the content is `z`× the card and shifted so `contentCentre` sits at the
    /// card's centre.
    public func contentX(ofNormalised x: Double) -> Double {
        let scaledWidth = card.width * contentZoom
        let originX = card.x + card.width / 2 - contentCentre.x * scaledWidth
        return originX + x * scaledWidth
    }

    public func contentY(ofNormalised y: Double) -> Double {
        let scaledHeight = card.height * contentZoom
        let originY = card.y + card.height / 2 - contentCentre.y * scaledHeight
        return originY + y * scaledHeight
    }
}
