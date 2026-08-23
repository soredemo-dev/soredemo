import AVFoundation
import Foundation

/// What an export is written as.
///
/// **H.264 was the only option and it is the oldest one here.** Every Mac this app runs on
/// encodes HEVC in hardware and has since 2017; a native editor offers H.264, H.265, ProRes and
/// HEVC 10-bit HDR, and the reason to offer more than one is that they are not ranked — HEVC is
/// the same picture at roughly half the size, ProRes is enormous and lossless enough to hand to
/// an editor, and H.264 is the one that plays everywhere without a question.
public enum ExportCodec: String, Hashable, Sendable, Codable, CaseIterable {
    /// Plays everywhere, including in places that have not been updated this decade.
    case h264
    /// **The same picture at about half the file.** Screen content is flat colour and repeated
    /// frames, which is what HEVC's larger prediction blocks are for; the gain is bigger here
    /// than it is on camera footage.
    case hevc
    /// **Intra-frame and nearly lossless, for handing to an editor.** No bit rate applies: every
    /// frame is complete, and the profile decides the size. Ten times an H.264 file, and that is
    /// what it is for.
    case proRes

    public var displayName: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .proRes: "ProRes 422"
        }
    }

    /// `.mov` for ProRes because MP4 has no business carrying it — QuickTime is where every tool
    /// that reads ProRes expects to find it.
    public var fileType: AVFileType {
        switch self {
        case .h264, .hevc: .mp4
        case .proRes: .mov
        }
    }

    public var fileExtension: String {
        switch self {
        case .h264, .hevc: "mp4"
        case .proRes: "mov"
        }
    }

    var videoCodec: AVVideoCodecType {
        switch self {
        case .h264: .h264
        case .hevc: .hevc
        case .proRes: .proRes422
        }
    }

    /// How much of H.264's bit rate this codec needs for the same picture.
    ///
    /// **0.55, not 0.5.** The usual claim for HEVC is "half the bitrate", which is measured on
    /// camera footage at broadcast rates; the margin narrows at the high rates screen content
    /// needs, and rounding the saving down is the direction that costs a file size rather than
    /// a person's text.
    var bitRateFactor: Double {
        switch self {
        case .h264: 1
        case .hevc: 0.55
        case .proRes: 1  // unused: ProRes takes no average bit rate
        }
    }

    /// Whether an average bit rate means anything for this codec.
    public var takesBitRate: Bool { self != .proRes }
}

/// How large the exported picture is.
///
/// **By SHORT side, which is a native editor's choice and the right one.** A ladder written as
/// "1920×1080" cannot describe a portrait output, and this app exports portrait and square
/// variants for the places people post them. The short side is the same number in every shape.
public enum ExportResolution: String, Hashable, Sendable, Codable, CaseIterable {
    case p720, p1080, p1440, p2160, matchRecording

    public var displayName: String {
        switch self {
        case .p720: "720p"
        case .p1080: "1080p"
        case .p1440: "1440p"
        case .p2160: "4K"
        case .matchRecording: "Match Recording"
        }
    }

    var shortSide: Int? {
        switch self {
        case .p720: 720
        case .p1080: 1080
        case .p1440: 1440
        case .p2160: 2160
        case .matchRecording: nil
        }
    }

    /// The output size for a shape, given what the recording itself has.
    ///
    /// **`matchRecording` is why this takes the recording's size at all.** The export was pinned
    /// to a 1920 longest edge — measured on a real recording, the capture was 3024×1964 and the
    /// file came out 1920×1080, so six in every ten pixels were thrown away with no way to ask
    /// for them. A person who recorded a Retina display and wants it at full size can have it.
    ///
    /// Even in both dimensions: an odd dimension is where a stray column of green comes from,
    /// which is the same rule `WindowTargets.evenFloor` and `CaptureSource` already apply.
    public func size(forAspect aspect: Double, recordingShortSide: Int)
    -> (width: Int, height: Int) {
        let target = shortSide ?? max(recordingShortSide, 2)
        let width: Double
        let height: Double
        if aspect >= 1 {
            height = Double(target)
            width = height * aspect
        } else {
            width = Double(target)
            height = width / max(aspect, 0.0001)
        }
        return (Self.even(width), Self.even(height))
    }

    static func even(_ value: Double) -> Int {
        let rounded = Int(value.rounded())
        return max(2, rounded - (rounded % 2))
    }
}
