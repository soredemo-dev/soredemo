import Foundation

/// How a region of the recording is hidden.
///
/// **A Gaussian blur is not offered, and that is a security decision.**
/// A normaliser that
/// takes a value and unconditionally returns `"mosaic"` — its blur type is a field nothing can
/// set. The reason it is right: a blur is a convolution, and a convolution with a known kernel
/// is invertible enough that text under a light one has been recovered from published video more
/// than once. A person hiding an API key does not want "harder to read", they want gone.
///
/// So the two choices are mosaic — destructive, and visibly so, which is also what makes a
/// reviewer trust it — and a solid fill, which is the only one with nothing left to recover.
public enum RedactionStyle: Hashable, Codable, Sendable {
    /// Averages each block to one colour. `blockFraction` is the block's size as a fraction of
    /// the SOURCE's shorter edge, so a mosaic looks the same at every export size.
    case mosaic(blockFraction: Double)
    /// A flat rectangle. Nothing survives it.
    case solid(red: Double, green: Double, blue: Double)

    public static let defaultMosaic = RedactionStyle.mosaic(blockFraction: 0.02)
    public static let black = RedactionStyle.solid(red: 0, green: 0, blue: 0)

    /// Clamped on the way in AND on the way out, because this is `Codable` with a synthesised
    /// decoder that never calls a validating initialiser — rule 8's case exactly.
    public var clamped: RedactionStyle {
        switch self {
        case .mosaic(let fraction):
            .mosaic(blockFraction: min(max(fraction, 0.002), 0.25))
        case .solid(let red, let green, let blue):
            .solid(red: min(max(red, 0), 1), green: min(max(green, 0), 1),
                   blue: min(max(blue, 0), 1))
        }
    }
}

/// A rectangle of the RECORDING to hide, and when.
///
/// **Normalised SOURCE coordinates, not output ones**, and the difference matters: the camera
/// zooms and pans, so a region pinned to the output would slide off whatever it was covering the
/// moment the camera moved. Pinned to the source, it covers the same pixels of the same window
/// however the frame is composed — which is what "hide this" means.
///
/// `y` runs from the TOP, unlike `TextOverlayStyle`'s, because a source rectangle is picked off a
/// picture and every picture coordinate a person can see runs downward. The conversion happens
/// once, where the image is composed.
public struct RedactionRegion: Hashable, Codable, Sendable, Identifiable {
    /// A counter minted by the track — `TextItem`'s reasoning: this is a deterministic tier and
    /// `UUID()` is ambient randomness.
    public let id: Int
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var style: RedactionStyle
    /// True hides an ellipse inscribed in the rectangle. A face is not a rectangle.
    public var isOval: Bool

    public init(id: Int, x: Double, y: Double, width: Double, height: Double,
                style: RedactionStyle = .defaultMosaic, isOval: Bool = false) {
        self.id = id
        // Clamped into the frame: a region dragged off the edge is a region a person meant to
        // put at the edge, and one stored outside it would silently cover nothing.
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
        self.width = min(max(width, 0), 1 - self.x)
        self.height = min(max(height, 0), 1 - self.y)
        self.style = style.clamped
        self.isOval = isOval
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try container.decode(Int.self, forKey: .id),
                  x: try container.decode(Double.self, forKey: .x),
                  y: try container.decode(Double.self, forKey: .y),
                  width: try container.decode(Double.self, forKey: .width),
                  height: try container.decode(Double.self, forKey: .height),
                  style: try container.decode(RedactionStyle.self, forKey: .style),
                  isOval: try container.decodeIfPresent(Bool.self, forKey: .isOval) ?? false)
    }

    private enum CodingKeys: String, CodingKey { case id, x, y, width, height, style, isOval }

    /// Nothing to draw. A zero-area region is what a click that did not become a drag produces.
    public var isEmpty: Bool { width <= 0 || height <= 0 }
}
