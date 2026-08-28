import Foundation

/// **A phone or tablet's body drawn around its screen.**
///
/// A demo of an iPad app reads as an iPad app when it is inside an iPad. Screen Studio and
/// Motionik both ship this and it is the one thing they offer for a phone recording that this
/// app did not.
///
/// **Proportions, not artwork.** The body is a rounded rectangle a known fraction larger than
/// the screen, with a known corner radius — no bundled images, no per-model files to keep up
/// with, nothing to go stale in September. It scales to any resolution because it is described
/// as ratios, and it can be tested because it is arithmetic.
///
/// **No notch and no island, deliberately.** An iOS screen recording already contains whatever
/// the system drew in that area — the recording IS the display's content — so drawing one over
/// it would draw it twice. What is missing from a recording is the hardware around the screen,
/// and that is all this adds.
public enum DeviceFrame {
    /// Which body to draw.
    public enum Model: String, Hashable, Sendable, Codable, CaseIterable {
        case iPhone, iPad

        public var displayName: String {
            switch self {
            case .iPhone: "iPhone"
            case .iPad: "iPad"
            }
        }
    }

    /// The body's finish.
    ///
    /// **Four, not a colour well.** A device body is a real object with a small set of real
    /// finishes; a free colour would let somebody make a lime green iPad, which reads as a
    /// mistake rather than as a choice.
    public enum Finish: String, Hashable, Sendable, Codable, CaseIterable {
        case graphite, silver, gold, deepBlue

        public var displayName: String {
            switch self {
            case .graphite: "Graphite"
            case .silver: "Silver"
            case .gold: "Gold"
            case .deepBlue: "Deep Blue"
            }
        }

        /// Linear-light RGB, 0…1. **Two tones**: the body is lit from above in every product
        /// photograph anybody has seen, and a flat fill reads as a rectangle rather than as
        /// metal.
        public var top: (r: Double, g: Double, b: Double) {
            switch self {
            case .graphite: (0.28, 0.28, 0.30)
            case .silver: (0.82, 0.83, 0.85)
            case .gold: (0.85, 0.76, 0.62)
            case .deepBlue: (0.22, 0.28, 0.40)
            }
        }

        public var bottom: (r: Double, g: Double, b: Double) {
            switch self {
            case .graphite: (0.16, 0.16, 0.18)
            case .silver: (0.62, 0.63, 0.66)
            case .gold: (0.66, 0.57, 0.44)
            case .deepBlue: (0.13, 0.17, 0.26)
            }
        }
    }

    /// The proportions of one model, all as fractions of the SCREEN's shorter side.
    ///
    /// **Uncalibrated, and derived from published dimensions rather than measured.** For a
    /// recent iPhone Pro the body is about 71.5 mm across and the screen about 65.8, so the
    /// bezel is roughly 2.85 mm — 4.3% of the screen's shorter side. An 11-inch iPad Pro is
    /// about 178.5 mm across a 160 mm screen, so 5.8%. The screen's own corner radius is the
    /// number Apple publishes for the display: 55 pt on a 393 pt-wide iPhone is 14%, and about
    /// 2.3% on an iPad.
    ///
    /// They are ratios of the screen's short side rather than of its width so that a recording
    /// held either way gets the same body.
    public struct Metrics: Hashable, Sendable {
        public let bezel: Double
        public let screenCornerRadius: Double
        /// The body's radius is the screen's plus the bezel: a bezel of even thickness around a
        /// rounded screen produces exactly that, which is why real hardware looks the way it
        /// does and why this is not a separate number.
        public var bodyCornerRadius: Double { screenCornerRadius + bezel }
    }

    public static func metrics(for model: Model) -> Metrics {
        switch model {
        case .iPhone: Metrics(bezel: 0.043, screenCornerRadius: 0.140)
        case .iPad: Metrics(bezel: 0.058, screenCornerRadius: 0.023)
        }
    }

    /// Where the body and the screen go, in output pixels.
    public struct Placement: Hashable, Sendable {
        public let body: StageRect
        public let bodyCornerRadius: Double
        public let screen: StageRect
        public let screenCornerRadius: Double
        public let finish: Finish
    }

    /// Fits a body of `model` into `available` and returns where its parts land.
    ///
    /// **The BODY is what is fitted, not the screen.** The screen is what the recording fills,
    /// so the obvious order is to fit the screen and grow a body around it — which puts the body
    /// outside the space it was given, and on a stage with little padding, outside the frame.
    /// Fitting the body and insetting the screen keeps everything inside by construction.
    ///
    /// `sourceAspect` is the recording's own width ÷ height. Returns `nil` for a model whose
    /// body will not fit at all — a caller then draws the recording plain rather than a device
    /// too small to see.
    public static func placement(model: Model, finish: Finish,
                                 availableWidth: Double, availableHeight: Double,
                                 centreX: Double, centreY: Double,
                                 sourceAspect: Double) -> Placement? {
        guard availableWidth > 0, availableHeight > 0, sourceAspect > 0,
              sourceAspect.isFinite else { return nil }
        let metrics = metrics(for: model)

        // The body's aspect, from the screen's plus a bezel of even thickness on all four sides.
        // Working in units of the screen's shorter side: the screen is `s` by `1` (portrait) or
        // `1` by `1/s` (landscape), and the body is that plus `2 × bezel` each way.
        let portrait = sourceAspect <= 1
        let screenLong = portrait ? 1 / sourceAspect : sourceAspect
        let screenUnits = portrait ? (w: 1.0, h: screenLong) : (w: screenLong, h: 1.0)
        let bodyUnits = (w: screenUnits.w + 2 * metrics.bezel,
                         h: screenUnits.h + 2 * metrics.bezel)

        // Fit the body, never fill: a cropped device is a broken photograph.
        let bodyAspect = bodyUnits.w / bodyUnits.h
        let bodyWidth = min(availableWidth, availableHeight * bodyAspect)
        let bodyHeight = bodyWidth / bodyAspect
        guard bodyWidth >= 8, bodyHeight >= 8 else { return nil }

        // One unit of "screen short side" in output pixels, which every other length is in.
        let unit = bodyWidth / bodyUnits.w
        let bezel = metrics.bezel * unit

        let body = StageRect(x: (centreX - bodyWidth / 2).rounded(),
                             y: (centreY - bodyHeight / 2).rounded(),
                             width: bodyWidth.rounded(), height: bodyHeight.rounded())
        let screen = StageRect(x: (body.x + bezel).rounded(), y: (body.y + bezel).rounded(),
                               width: (body.width - 2 * bezel).rounded(),
                               height: (body.height - 2 * bezel).rounded())
        guard screen.width >= 2, screen.height >= 2 else { return nil }

        // Radii clamped to half the shorter side for `StagePlanner`'s reason: a larger radius is
        // not a rounder rectangle, it is an undefined one.
        let screenRadius = min(metrics.screenCornerRadius * unit,
                              min(screen.width, screen.height) / 2)
        let bodyRadius = min(metrics.bodyCornerRadius * unit,
                            min(body.width, body.height) / 2)
        return Placement(body: body, bodyCornerRadius: bodyRadius,
                         screen: screen, screenCornerRadius: screenRadius, finish: finish)
    }
}
