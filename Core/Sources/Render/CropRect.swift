import Foundation

/// The part of the recording that is used at all.
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
}
