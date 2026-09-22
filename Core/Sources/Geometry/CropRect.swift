import Foundation

/// The part of the recording that is used at all.
///
/// **Lives in `Geometry`, not `Render`, since the window-resize repair (2026-09-18).** A second
/// producer appeared that is not a person: ScreenCaptureKit reports, per frame, which part of a
/// fixed buffer the source actually drew into, and that is a crop in every sense this type
/// means. `Capture` writes it and `Project` carries it, and neither may name `Render` — so the
/// type moved down to the module both already depend on rather than being duplicated into one
/// that would then drift.
///
/// **Not the camera's zoom, and the difference is what each one is for.** `RenderPlan.contentZoom`
/// moves a window over the recording while it plays, and every frame still has the whole
/// recording behind it. A crop decides what the recording IS: the parts outside it are gone from
/// the output, the card is fitted to what remains, and nothing can pan back to them. The case
/// it exists for is a person who recorded a 16:9 display
/// to show one panel of an application.
///
/// **Normalised source coordinates with `y` from the TOP**, matching `RedactionRegion` and for
/// the same reason: this is a rectangle picked off a picture, and every picture coordinate a
/// person can see runs downward.
public struct CropRect: Hashable, Codable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    /// The whole recording — what "no crop" is, kept as a value so a caller can compare against
    /// it rather than against `nil` in one place and a rectangle in another.
    public static let whole = CropRect(x: 0, y: 0, width: 1, height: 1)

    public init(x: Double, y: Double, width: Double, height: Double) {
        // Clamped into the frame and never smaller than a hundredth: sliders and decoders both
        // reach here, and a crop of zero area is a video with no picture in it.
        self.x = min(max(x, 0), 0.99)
        self.y = min(max(y, 0), 0.99)
        self.width = min(max(width, 0.01), 1 - self.x)
        self.height = min(max(height, 0.01), 1 - self.y)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(x: try container.decode(Double.self, forKey: .x),
                  y: try container.decode(Double.self, forKey: .y),
                  width: try container.decode(Double.self, forKey: .width),
                  height: try container.decode(Double.self, forKey: .height))
    }

    private enum CodingKeys: String, CodingKey { case x, y, width, height }

    public var isWhole: Bool { self == .whole }

    /// The cropped size in pixels, given the recording's own.
    ///
    /// **Even on both edges**, for the reason every buffer dimension in this project is: an odd
    /// one is where a stray column of green comes from.
    public func size(ofSourceWidth sourceWidth: Int, sourceHeight: Int) -> (width: Int, height: Int) {
        (Self.evenFloor(Int((Double(sourceWidth) * width).rounded())),
         Self.evenFloor(Int((Double(sourceHeight) * height).rounded())))
    }

    static func evenFloor(_ value: Int) -> Int { max(2, value - (value % 2)) }

    public func changing(x: Double? = nil, y: Double? = nil,
                         width: Double? = nil, height: Double? = nil) -> CropRect {
        CropRect(x: x ?? self.x, y: y ?? self.y,
                 width: width ?? self.width, height: height ?? self.height)
    }

    /// This crop read as a fraction of `outer` instead of of the whole recording.
    ///
    /// The two crops in play are not siblings and composing them the other way round is the
    /// bug this method exists to make unwritable. A person draws their crop on the picture
    /// they can SEE, and what they can see is already the window's own rectangle — so their
    /// `0.5` means half of the window, not half of the buffer the window was drawn into.
    /// `user.within(content)` is that sentence; `content.within(user)` is a different
    /// rectangle and is never what anybody meant.
    ///
    /// `.whole.within(outer) == outer` and `self.within(.whole) == self`, which is what makes
    /// the uncropped cases cost nothing rather than needing a branch at each call site.
    public func within(_ outer: CropRect) -> CropRect {
        CropRect(x: outer.x + x * outer.width,
                 y: outer.y + y * outer.height,
                 width: width * outer.width,
                 height: height * outer.height)
    }

    /// Where the source actually drew inside a fixed capture buffer, from the
    /// `SCStreamFrameInfoContentRect` attachment — `nil` when the inputs cannot describe a
    /// rectangle at all.
    ///
    /// **`contentRect × scaleFactor`, and that factor was measured, not reasoned about**, as was
    /// `y` running from the TOP. Three conversions are in circulation and the other two are
    /// wrong by 161 and 1018 pixels on the same frames; the measurement table, the window sizes
    /// it was taken at and what a wrong one looks like are in
    /// `docs/design/2026-09-18-a-window-resized-while-the-recording-runs.md`.
    public static func ofContent(inPoints contentRect: PointRect, scaleFactor: Double,
                                 bufferWidth: Int, bufferHeight: Int) -> CropRect? {
        guard bufferWidth > 0, bufferHeight > 0,
              scaleFactor.isFinite, scaleFactor > 0,
              contentRect.x.isFinite, contentRect.y.isFinite,
              contentRect.width.isFinite, contentRect.height.isFinite,
              contentRect.width > 0, contentRect.height > 0 else { return nil }
        let width = Double(bufferWidth)
        let height = Double(bufferHeight)
        return CropRect(x: contentRect.x * scaleFactor / width,
                        y: contentRect.y * scaleFactor / height,
                        width: contentRect.width * scaleFactor / width,
                        height: contentRect.height * scaleFactor / height)
    }

    /// Whether `other` describes a different rectangle than this one by as much as half a pixel
    /// on any edge, given the buffer both are fractions of.
    ///
    /// **The writer's whole cost control.** The content rect arrives on EVERY frame and is
    /// identical on almost all of them, so a record per frame would be tens of thousands of
    /// lines saying nothing. Half a pixel rather than exact equality because the attachment
    /// carries floating-point noise in its low digits — measured at 709.333324432373 for a
    /// rectangle that was not moving — and exact comparison would turn that noise into a
    /// record.
    public func differs(from other: CropRect, byHalfAPixelIn bufferWidth: Int,
                        bufferHeight: Int) -> Bool {
        guard bufferWidth > 0, bufferHeight > 0 else { return self != other }
        let horizontal = 0.5 / Double(bufferWidth)
        let vertical = 0.5 / Double(bufferHeight)
        return abs(x - other.x) >= horizontal || abs(width - other.width) >= horizontal
            || abs(y - other.y) >= vertical || abs(height - other.height) >= vertical
    }
}
