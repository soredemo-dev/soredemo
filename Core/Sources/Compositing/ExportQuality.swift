import AVFoundation
import Foundation
// For `kVTProfileLevel_HEVC_Main_AutoLevel`, which AVFoundation does not re-export.
import VideoToolbox

/// How many bits an export is allowed to spend, and the settings that spend them.
///
/// **Nothing here was being set, and AVFoundation's default is tuned for the wrong content.** The
/// writer was given a codec and a size and no compression properties at all, so the framework
/// chose. Measured against `AVOutputSettingsAssistant`, Apple's own recommendation for 1080p is
/// 10.5 Mbps — a number picked for camera footage, which is soft, noisy and full of gradients. A
/// screen recording is hard edges and text, which is exactly what H.264 spends its bits worst on,
/// and at half the rate it needs the text is the first thing to go.
///
/// **Three projects, three methods, one answer.** an Electron recorder's `getMp4ExportBitrate` and
/// an Electron recorder's `calculateBitrate` both step by pixel count — 10 Mbps to 720p, 20 to 1080p, 30
/// above — having arrived there separately. a Rust recorder computes bits-per-pixel instead, and its
/// `Maximum` preset works out at 18.7 Mbps for 1080p30. Two independent tables and one formula
/// agreeing within a tenth is the strongest evidence available for a number nobody can derive.
///
/// a Rust recorder's shape is the one carried over, because a table has to be re-guessed at every new
/// resolution and a bits-per-pixel figure does not.
public struct ExportQuality: Hashable, Sendable, Codable {
    /// Bits per pixel per frame. a Rust recorder's own values, unchanged — its `Maximum` 0.3, `Social` 0.15
    /// and `Web` 0.08, renamed here for what they are rather than for where they are posted.
    public let bitsPerPixel: Double
    /// The audio track's rate. 192 kbps is a Rust recorder's; 128 was here, which is a rate chosen for music,
    /// where a listener is not trying to make out consonants.
    public let audioBitRate: Int

    public init(bitsPerPixel: Double, audioBitRate: Int) {
        // Clamped rather than trapped: this arrives from a picker and from a decoder — rule 8.
        self.bitsPerPixel = min(max(bitsPerPixel, 0.01), 1)
        self.audioBitRate = min(max(audioBitRate, 32_000), 320_000)
    }

    /// Everything the picture has. What a recording being kept or re-edited later should be.
    public static let best = ExportQuality(bitsPerPixel: 0.3, audioBitRate: 192_000)
    /// Half the bits, for a file that has to be sent to somebody.
    public static let balanced = ExportQuality(bitsPerPixel: 0.15, audioBitRate: 128_000)
    /// Small enough to attach to a message, and it looks it.
    public static let small = ExportQuality(bitsPerPixel: 0.08, audioBitRate: 96_000)

    public static let choices: [ExportQuality] = [.best, .balanced, .small]

    public var displayName: String {
        switch bitsPerPixel {
        case ExportQuality.best.bitsPerPixel: "Best"
        case ExportQuality.balanced.bitsPerPixel: "Balanced"
        default: "Small"
        }
    }

    /// **A doubled frame rate does not need doubled bits.** Consecutive frames at 60 fps differ
    /// by half as much as at 30, so the second half of the frames cost the encoder far less than
    /// the first. a Rust recorder's H.264 encoder tapers everything above 30 by 0.6 and its size estimates
    /// come within 3% of the files it writes; that is the whole argument for the number.
    public static func effectiveFrameRate(_ frameRate: Int) -> Double {
        min(Double(frameRate), 30) + max(Double(frameRate) - 30, 0) * 0.6
    }

    /// The average video bit rate for a frame of this size at this rate.
    public func videoBitRate(outputWidth: Int, outputHeight: Int, frameRate: Int,
                             codec: ExportCodec = .h264) -> Int {
        let pixels = Double(outputWidth * outputHeight)
        let rate = pixels * bitsPerPixel * Self.effectiveFrameRate(frameRate)
            * codec.bitRateFactor
        // **A floor, because a small output still has to be legible.** an Electron recorder's is 2 Mbps and
        // it is there for the same reason: a 640-wide MP4 of a terminal is text, and
        // bits-per-pixel alone would give it almost nothing.
        return max(Int(rate.rounded()), 2_000_000)
    }

    /// The writer settings for the video track.
    ///
    /// **Everything Apple's own assistant sets, which this was setting none of.** Measured:
    /// `AVOutputSettingsAssistant` fills in `ProfileLevel`, `ExpectedFrameRate`,
    /// `MaxKeyFrameInterval`, `AllowFrameReordering` and `H264EntropyMode` beside the bit rate.
    public func videoSettings(outputWidth: Int, outputHeight: Int, frameRate: Int,
                              codec: ExportCodec = .h264) -> [String: any Sendable] {
        // **ProRes takes no bit rate and no profile level.** Every frame is complete and the
        // profile decides the size; handing it an average bit rate is handing it a setting it
        // has no use for, and a profile level from H.264's vocabulary would be refused.
        guard codec.takesBitRate else {
            return [
                AVVideoCodecKey: codec.videoCodec,
                AVVideoWidthKey: outputWidth,
                AVVideoHeightKey: outputHeight,
            ]
        }
        var properties: [String: any Sendable] = [
            AVVideoAverageBitRateKey: videoBitRate(outputWidth: outputWidth,
                                                   outputHeight: outputHeight,
                                                   frameRate: frameRate, codec: codec),
            AVVideoExpectedSourceFrameRateKey: frameRate,
            // **Two seconds of GOP.** A keyframe every frame is a file nobody can afford and
            // one keyframe per file is a file nobody can scrub; two seconds is what every
            // player is built for.
            AVVideoMaxKeyFrameIntervalKey: max(frameRate * 2, 2),
            AVVideoAllowFrameReorderingKey: true,
        ]
        // The profile vocabularies are per-codec and not interchangeable; H.264's entropy mode
        // has no HEVC equivalent because HEVC has only CABAC.
        switch codec {
        case .h264:
            properties[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            properties[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
        case .hevc:
            properties[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
        case .proRes:
            break
        }
        return [
            AVVideoCodecKey: codec.videoCodec,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight,
            AVVideoCompressionPropertiesKey: properties,
        ]
    }

    public func audioSettings() -> [String: any Sendable] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 48_000,
            AVEncoderBitRateKey: audioBitRate,
        ]
    }

    /// Roughly how large the file will be, in bytes, before it is written.
    ///
    /// **Said before the export, because the answer changes what somebody picks.** a Rust recorder shows this
    /// and calibrated it against real recordings to an average error of 3%; `encoderEfficiency`
    /// below is that calibration — H.264 beats the theoretical bits-per-pixel figure by about
    /// half on screen content, which is flat colour and repeated frames far more than detail.
    ///
    /// An estimate, and named as one. The true size depends on what is on the screen, and a
    /// recording of a video playing full-screen will beat it.
    public func estimatedBytes(outputWidth: Int, outputHeight: Int, frameRate: Int,
                               seconds: Double, codec: ExportCodec = .h264) -> Int {
        // **ProRes is not estimated from a bit rate**, because it has none. Apple publishes 147
        // Mbps for ProRes 422 at 1080p29.97, and 147e6 / (1920 × 1080 × 29.97) is 2.37 bits per
        // pixel per frame — a figure that scales with pixels and frames, which is what an intra
        // codec's size does. No encoder-efficiency factor either: an intra codec's size IS its
        // data rate, not a guess about how well it predicts.
        guard codec.takesBitRate else {
            let pixels = Double(outputWidth * outputHeight)
            let bits = pixels * 2.37 * Double(frameRate)
            return Int((bits * max(seconds, 0) / 8).rounded())
        }
        let encoderEfficiency = 0.5
        let bits = Double(videoBitRate(outputWidth: outputWidth, outputHeight: outputHeight,
                                       frameRate: frameRate, codec: codec) + audioBitRate)
        return Int((bits * encoderEfficiency * max(seconds, 0) / 8).rounded())
    }
}
