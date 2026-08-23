import CoreMedia
import Foundation

/// How often the capture is allowed to deliver a frame.
///
/// **A ceiling, not a cadence.** ScreenCaptureKit emits a frame when the screen changes and not
/// otherwise, so this is the shortest interval it may use — a still screen still produces
/// nothing, and `MP4Exporter`'s resampler is what turns whatever arrives into a constant rate.
/// The name is what a person means by "60 fps" even though the file is variable until it is
/// exported.
///
/// **Why it is worth choosing.** ScreenKite's picker card shows `1512×982 · 120FPS` with the
/// recorded rate beside it, and the two ends of the range are genuinely different products: 30
/// halves the file and the encode cost of a long tutorial where nothing moves fast, and 120 is
/// what makes a scroll or a drag look like the machine rather than like a slideshow.
public enum CaptureFrameRate: Int, CaseIterable, Sendable, Codable {
    case thirty = 30
    case sixty = 60
    case oneHundredTwenty = 120

    public var minimumFrameInterval: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(rawValue))
    }

    public var displayName: String { "\(rawValue) fps" }

    /// What choosing it costs or buys, said where the choice is made.
    public var detail: String {
        switch self {
        case .thirty: "Smaller files. Enough for a tutorial."
        case .sixty: "The default. Smooth scrolling."
        case .oneHundredTwenty: "For fast motion. Larger files."
        }
    }

    /// The rates a display can actually deliver.
    ///
    /// **Offering 120 on a 60 Hz display would be offering nothing**: `minimumFrameInterval` is
    /// a ceiling and the panel is the floor, so the recording would be 60 either way and the
    /// choice would be a control that changes no observable thing.
    public static func available(upTo displayRefreshRate: Double) -> [CaptureFrameRate] {
        allCases.filter { Double($0.rawValue) <= displayRefreshRate + 1 }
    }
}
