import Foundation

/// A point in the output's own coordinates, y from the BOTTOM as everything in a `RenderPlan` is.
/// Plain `Double`s because rule 2 forbids `CGPoint` in this package; the renderer converts.
public struct StagePoint: Hashable, Codable, Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// The four corners a tilted card occupies. Not a `StageRect`, because a turned rectangle is not
/// one — which is the whole reason this type exists.
public struct StageQuad: Hashable, Codable, Sendable {
    public let topLeft: StagePoint
    public let topRight: StagePoint
    public let bottomRight: StagePoint
    public let bottomLeft: StagePoint

    public init(topLeft: StagePoint, topRight: StagePoint,
                bottomRight: StagePoint, bottomLeft: StagePoint) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }
}

/// How far the card is turned away from the viewer.
///
/// **A static tilt, and motion is deliberately a different row** — a tilt that changes over a clip
/// needs a track, keyframes and a retiming story, and building it here would make this type's name
/// a lie. See `docs/design/2026-09-25-tilting-the-card.md`.
///
/// **Clamped at construction, so the projection can never fail.** With the angles held to
/// `steepestAngle` and the camera never nearer than `nearestDistance` card-widths, the deepest a
/// corner can reach is half the card's diagonal — at most 0.708 x the longer edge — against a
/// camera at 1.2 or more. `d - z` is therefore always positive, which is why `quad(for:)` answers
/// with a value rather than an optional. The same arrangement `CropRect` makes, for the same
/// reason: sliders and decoders both arrive here.
public struct StageTilt: Hashable, Codable, Sendable {
    /// Degrees about the horizontal axis. Positive turns the top away.
    public let pitch: Double
    /// Degrees about the vertical axis. Positive turns the right edge away.
    public let yaw: Double
    /// The pinhole's distance, in multiples of the card's longer edge. **A ratio, so the same
    /// tilt looks the same on a 1080p card and a 4K one** — the strength of a perspective is not
    /// a number of pixels.
    public let distance: Double

    /// Generous enough for the effect, tight enough to keep the projection well-conditioned. Not
    /// watched by anybody at the limit yet; see the design doc's open questions.
    public static let steepestAngle: Double = 60
    /// Nearer than this and the foreshortening is a fish-eye rather than a turn.
    public static let nearestDistance: Double = 1.2
    /// A mild wide-angle, and the default.
    public static let comfortableDistance: Double = 2.5

    /// No turn at all — the card as it was before this type existed. Compared against rather than
    /// against `nil`, the way `CropRect.whole` is.
    public static let flat = StageTilt(pitch: 0, yaw: 0, distance: comfortableDistance)

    public init(pitch: Double, yaw: Double, distance: Double) {
        self.pitch = Self.clampedAngle(pitch)
        self.yaw = Self.clampedAngle(yaw)
        self.distance = Self.clampedDistance(distance)
    }

    /// A non-finite angle is not a rotation; it becomes no rotation rather than a NaN travelling
    /// into every corner of the frame.
    static func clampedAngle(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, -steepestAngle), steepestAngle)
    }

    static func clampedDistance(_ value: Double) -> Double {
        guard value.isFinite else { return comfortableDistance }
        return max(value, nearestDistance)
    }

    private enum CodingKeys: String, CodingKey { case pitch, yaw, distance }

    /// Rule 8: the synthesised decode assigns stored properties directly, so a document could
    /// otherwise carry an angle this initialiser exists to refuse — and a NaN reaching
    /// `CIPerspectiveTransform` is a frame that does not draw.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(pitch: try container.decode(Double.self, forKey: .pitch),
                  yaw: try container.decode(Double.self, forKey: .yaw),
                  distance: try container.decode(Double.self, forKey: .distance))
    }

    /// Whether there is anything to draw differently. Checked before the filter is built, so a
    /// project that never touches the control pays nothing — `CropRect.isWhole`'s arrangement.
    public var isFlat: Bool { pitch == 0 && yaw == 0 }

    /// Where the card's four corners land once it is turned.
    ///
    /// The card is a plane at z = 0 centred on the origin; yaw turns it about the vertical axis,
    /// pitch about the horizontal one, and a pinhole at `d` on +z projects it. Written out rather
    /// than composed from matrices because it is nine lines either way and this way the design
    /// doc's four lines of algebra are the four lines of code.
    public func quad(for card: StageRect) -> StageQuad {
        let halfWidth = card.width / 2
        let halfHeight = card.height / 2
        let centreX = card.x + halfWidth
        let centreY = card.y + halfHeight
        guard !isFlat else {
            return StageQuad(
                topLeft: StagePoint(x: card.x, y: card.y + card.height),
                topRight: StagePoint(x: card.x + card.width, y: card.y + card.height),
                bottomRight: StagePoint(x: card.x + card.width, y: card.y),
                bottomLeft: StagePoint(x: card.x, y: card.y))
        }
        let yawRadians = yaw * .pi / 180
        let pitchRadians = pitch * .pi / 180
        let camera = distance * max(card.width, card.height)

        func project(_ x: Double, _ y: Double) -> StagePoint {
            let x1 = x * cos(yawRadians)
            let z1 = -x * sin(yawRadians)
            let y2 = y * cos(pitchRadians) - z1 * sin(pitchRadians)
            let z2 = y * sin(pitchRadians) + z1 * cos(pitchRadians)
            // Positive by construction — see the type's own note on the clamps.
            let scale = camera / (camera - z2)
            return StagePoint(x: centreX + x1 * scale, y: centreY + y2 * scale)
        }
        return StageQuad(topLeft: project(-halfWidth, halfHeight),
                         topRight: project(halfWidth, halfHeight),
                         bottomRight: project(halfWidth, -halfHeight),
                         bottomLeft: project(-halfWidth, -halfHeight))
    }
}
