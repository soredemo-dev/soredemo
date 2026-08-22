import Foundation

/// How a burnt-in caption looks. Fractions of the OUTPUT, never pixels.
///
/// **Everything is a fraction of the frame's height, and that is the whole point.** A caption
/// sized in points is right at one export size and wrong at every other, and this project
/// re-renders the same recording at 1920, at 640 for a GIF, and at whatever a portrait variant
/// works out to. A caption specified in fractions is the same caption in all of them.
///
/// Height rather than width, for the font: a line of text scaled by the frame's WIDTH gets
/// taller when a landscape recording is exported as portrait, which is backwards.
public struct CaptionStyle: Hashable, Codable, Sendable {
    /// Cap height of the type as a fraction of the frame's height. 0.045 is roughly what a
    /// broadcast caption occupies and what Screen Studio's default sits near.
    public let heightFraction: Double
    /// The gap between the caption's baseline box and the bottom of the frame.
    public let bottomInsetFraction: Double
    /// The widest a line may be before `CaptionBuilder` breaks it. 0.9 is a native editor's ratio.
    public let maximumWidthFraction: Double
    /// The plate behind the text. 0 draws none — legible over a dark recording, unreadable over
    /// a white one, which is why the default is not 0.
    public let backgroundOpacity: Double
    /// The plate's corner radius, as a fraction of the frame's height, so it scales too.
    public let backgroundCornerFraction: Double
    public let red: Double
    public let green: Double
    public let blue: Double

    public static let `default` = CaptionStyle(
        heightFraction: 0.045, bottomInsetFraction: 0.07, maximumWidthFraction: 0.9,
        backgroundOpacity: 0.55, backgroundCornerFraction: 0.012,
        red: 1, green: 1, blue: 1)

    public init(heightFraction: Double, bottomInsetFraction: Double,
                maximumWidthFraction: Double, backgroundOpacity: Double,
                backgroundCornerFraction: Double,
                red: Double, green: Double, blue: Double) {
        // Clamped rather than trapped: every one of these reaches here from a slider, and a
        // style is also decoded from a saved project — rule 8 says never `precondition` on an
        // untrusted input. Clamping is the same answer on both paths, so there is one path.
        self.heightFraction = min(max(heightFraction, 0.005), 0.5)
        self.bottomInsetFraction = min(max(bottomInsetFraction, 0), 0.9)
        self.maximumWidthFraction = min(max(maximumWidthFraction, 0.1), 1)
        self.backgroundOpacity = min(max(backgroundOpacity, 0), 1)
        self.backgroundCornerFraction = min(max(backgroundCornerFraction, 0), 0.5)
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    /// The type size in output pixels.
    public func pointSize(forOutputHeight height: Int) -> Double {
        Double(height) * heightFraction
    }

    /// The widest a line may be drawn, in output pixels.
    public func maximumWidth(forOutputWidth width: Int) -> Double {
        Double(width) * maximumWidthFraction
    }
}

/// The caption on this frame: what it says and how it should look.
///
/// **A `String`, not a `CaptionCue`.** `Captions` is a sibling of `Render` in the deterministic
/// tier, so a cue type here would be an edge in the wrong direction — the same reasoning
/// `RenderPlan.contentZoom` gives for taking two numbers rather than a `CameraState`.
/// `Compositing` depends on both and resolves the cue.
public struct CaptionOverlay: Hashable, Sendable {
    public let text: String
    public let style: CaptionStyle

    public init(text: String, style: CaptionStyle) {
        self.text = text
        self.style = style
    }
}
