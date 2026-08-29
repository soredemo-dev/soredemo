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
/// **Why it is worth choosing.** A picker card that reads `1512×982 · 120FPS` puts the
/// recorded rate beside it, and the two ends of the range are genuinely different products: 30
/// halves the file and the encode cost of a long tutorial where nothing moves fast, and the
/// panel's own rate is what makes a scroll or a drag look like the machine rather than like a
/// slideshow.
///
/// **A value, not a fixed ladder, and that is the point.** This was an `enum` of 30, 60 and 120,
/// so a 144 Hz monitor was offered 120 — a third of the frames it can produce, thrown away by a
/// list written before anybody owned that display. The rates come from the hardware now; the
/// three names below are conveniences for the call sites that need a default.
public struct CaptureFrameRate: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: Int

    /// **Failable, and it refuses a non-positive rate.** `rawValue` becomes a `CMTime` timescale
    /// and a division; this arrives from `UserDefaults` and from a decoder, where a zero is a
    /// value somebody else wrote — rule 8's case.
    public init?(rawValue: Int) {
        guard rawValue > 0, rawValue <= 1000 else { return nil }
        self.rawValue = rawValue
    }

    /// **Hand-written, because the synthesised one never calls the initialiser above.** It
    /// assigns the stored property directly, so a `0` in a project file would arrive as a
    /// `CMTime` timescale of zero and a division. Validated here and CLAMPED rather than thrown:
    /// a rate is a preference, and refusing to open a recording over one is a worse answer than
    /// opening it at 60. Rule 8's other half — a precondition on decoded input turns a corrupt
    /// file into a crash.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let decoded = try container.decode(Int.self)
        self = CaptureFrameRate(rawValue: decoded) ?? .sixty
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let thirty = CaptureFrameRate(rawValue: 30)!
    public static let sixty = CaptureFrameRate(rawValue: 60)!
    public static let oneHundredTwenty = CaptureFrameRate(rawValue: 120)!

    public var minimumFrameInterval: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(rawValue))
    }

    public var displayName: String { "\(rawValue) fps" }

    /// What choosing it costs or buys, said where the choice is made.
    ///
    /// Written against the boundaries rather than the three old cases, because the rates are the
    /// display's now and a 144 needs a sentence as much as a 120 does.
    public var detail: String {
        switch rawValue {
        case ..<45: "Smaller files. Enough for a tutorial."
        case ..<75: "Smooth scrolling."
        default: "Every frame this display can show. Larger files."
        }
    }

    /// The rates worth offering, given what the attached displays can do.
    ///
    /// **Two fixed rungs and then the hardware's own.** 30 and 60 are worth offering everywhere:
    /// 30 is a deliberate halving for a long tutorial, and 60 is what most people mean by smooth
    /// and what most players and sites are happiest with. Above that there is no ladder worth
    /// inventing — a display does what it does, and 120 on a 144 Hz panel is a sixth of its
    /// frames discarded to match a number somebody typed into an enum.
    ///
    /// **Offering more than a display can do would be offering nothing**: `minimumFrameInterval`
    /// is a ceiling and the panel is the floor, so the recording would be the panel's rate either
    /// way and the choice would change no observable thing.
    ///
    /// An empty list of display rates is a system that reported nothing — several built-in panels
    /// answer 0 for `CGDisplayMode.refreshRate` — and the answer is the two fixed rungs plus 120,
    /// which is what a Mac made this decade is.
    public static func available(forDisplayRates displayRates: [Double]) -> [CaptureFrameRate] {
        let usable = displayRates.filter { $0 > 0 }
        guard !usable.isEmpty else { return [.thirty, .sixty, .oneHundredTwenty] }
        let fastest = usable.max() ?? 60
        var rates: Set<Int> = []
        for fixed in [30, 60] where Double(fixed) <= fastest + 1 { rates.insert(fixed) }
        // Rounded, because a panel reports 59.999 and a rate of 59 is not what anybody means.
        for rate in usable { rates.insert(Int(rate.rounded())) }
        // A display slower than 30 leaves the set empty; its own rate is then the only answer.
        if rates.isEmpty { rates.insert(max(Int(fastest.rounded()), 1)) }
        return rates.sorted().compactMap { CaptureFrameRate(rawValue: $0) }
    }
}
