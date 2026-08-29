import Foundation

/// **A destination, as the four settings it implies.**
///
/// Resolution, codec, frame rate and quality are each individually sensible and collectively a
/// small research project: a person who wants to put a demo in a Slack thread should not have
/// to know that H.264 is the one every client decodes, that 720p is what keeps a two-minute
/// recording under an attachment limit, or that ProRes is the thing an editor actually wants.
/// Three destinations, because a file goes to a page, to a person, or to another editor.
///
/// **Three, and they have to be genuinely different.** Offering a list whose entries produce
/// nearly the same file is worse than offering none: it asks a person to choose between things
/// that do not differ, and `theThreePresetsAreActuallyDifferent` is what stops that happening
/// as the constants drift.
///
/// **A preset is a starting point, not a mode.** Choosing one sets the four controls and then
/// gets out of the way; changing any of them afterwards leaves the settings alone and the
/// picker reads `nil` — `matching(...)` is how a UI asks "is this still one of them", and the
/// honest answer for a hand-tuned export is that it is not.
public struct ExportPreset: Hashable, Sendable {
    public let name: String
    /// What the choice actually buys, in the words of the thing a person is trying to do.
    public let detail: String
    public let resolution: ExportResolution
    public let codec: ExportCodec
    public let frameRate: ExportFrameRate
    public let quality: ExportQuality

    public init(name: String, detail: String, resolution: ExportResolution,
                codec: ExportCodec, frameRate: ExportFrameRate, quality: ExportQuality) {
        self.name = name
        self.detail = detail
        self.resolution = resolution
        self.codec = codec
        self.frameRate = frameRate
        self.quality = quality
    }

    /// **1080p H.264 at whatever was recorded, balanced.**
    ///
    /// The frame rate is deliberately `matchRecording` rather than pinned at 30: the cursor
    /// smoothing and the camera springs in this app are motion, and halving the rate of a 60 fps
    /// capture throws away the thing it spent its effort on. H.264 because it is the one every
    /// browser and every embed decodes without asking.
    public static let web = ExportPreset(
        name: "Web",
        detail: "1080p H.264. Plays in every browser and embed, at the rate you recorded.",
        resolution: .p1080, codec: .h264, frameRate: .matchRecording, quality: .balanced)

    /// **720p H.264 at 30 fps, small.**
    ///
    /// Sized by an attachment limit rather than by taste: mail and chat clients bounce large
    /// files, and a demo that will not send is worse than one that is soft. This is the only
    /// preset that lowers the frame rate, and it does it for bytes rather than because 30 looks
    /// better.
    public static let message = ExportPreset(
        name: "Email and chat",
        detail: "720p H.264 at 30 fps. Small enough to attach and send.",
        resolution: .p720, codec: .h264, frameRate: .fps30, quality: .small)

    /// **The recording's own size, ProRes 422, at its own rate.**
    ///
    /// For handing to Final Cut or Premiere, where a long-GOP H.264 is the wrong thing to cut
    /// and re-encode. `quality` is carried but has no effect: `ExportCodec.takesBitRate` is
    /// false for ProRes, which encodes to its own profile — stated here rather than left for
    /// somebody to discover from an unchanged file size.
    public static let editing = ExportPreset(
        name: "Further editing",
        detail: "The recording's own size, ProRes 422. Large, and what an editor wants to cut.",
        resolution: .matchRecording, codec: .proRes, frameRate: .matchRecording, quality: .best)

    public static let all: [ExportPreset] = [.web, .message, .editing]

    /// The preset these settings ARE, or `nil` for a combination nobody offered.
    ///
    /// **Quality is compared only where it can matter.** A ProRes export ignores the bit rate,
    /// so two ProRes settings that differ only in `quality` produce the same file, and reporting
    /// them as different presets would show "Custom" beside an export identical to `editing`.
    public static func matching(resolution: ExportResolution, codec: ExportCodec,
                                frameRate: ExportFrameRate, quality: ExportQuality) -> ExportPreset? {
        all.first { preset in
            preset.resolution == resolution && preset.codec == codec
                && preset.frameRate == frameRate
                && (!codec.takesBitRate || preset.quality == quality)
        }
    }
}
