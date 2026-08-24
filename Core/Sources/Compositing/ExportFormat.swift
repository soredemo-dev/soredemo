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
    /// **The only export that keeps a coloured edge, and that is a measured claim — remeasured
    /// on 2026-08-25, because the first measurement was wrong in a way that changed the
    /// story.**
    ///
    /// Encode 8-pixel red bars on black, decode them back, and read the last red column, which
    /// should be 255, and the worst error across the edge. With `ExportQuality.colourProperties`
    /// on the writer — Rec.709 primaries, transfer AND matrix, said explicitly:
    ///
    /// | | last red column | worst edge error |
    /// | --- | --- | --- |
    /// | H.264 High | 154 | 101 |
    /// | HEVC Main | 154 | 101 |
    /// | ProRes 422 | 155 | 101 |
    /// | **ProRes 4444** | **255** | **0** |
    ///
    /// Everything except 4444 smears the edge by a hundred levels, because everything except
    /// 4444 is 4:2:0 by the time the encoder sees it — including ProRes 422. That is the
    /// coloured fringing on red-on-black text, on a one-pixel border, on a thin diagonal, that
    /// everybody recognises from a screen recording, and it is the largest picture-quality
    /// difference available here — far larger than sRGB versus Display P3, and unlike the
    /// gamut question anybody can see it.
    ///
    /// **What the first measurement got wrong.** It read 234 / 21 for 4444 and 145 / 110 for
    /// the rest, and explained the 21 as "what a fully saturated red costs in 8-bit YCbCr at
    /// all" — reasoning from the fact that neutrals round-tripped exactly. The neutrals were
    /// a red herring: the writer had been given no colour properties, and a writer fed
    /// untagged BGRA infers a **601 matrix** under a 709 tag. Neutrals are identical under
    /// both matrices, which is exactly why they passed, and a saturated red is where the two
    /// differ most. Named, the matrix costs nothing, and 4444 is exact. The 4:2:0 figures
    /// moved by ten in the other direction for the same reason. The rule this is an
    /// instance of: a conclusion whose stated reason is false looks settled, and this one
    /// stood for a day.
    case proRes4444

    public var displayName: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .proRes: "ProRes 422"
        case .proRes4444: "ProRes 4444"
        }
    }

    /// `.mov` for ProRes because MP4 has no business carrying it — QuickTime is where every tool
    /// that reads ProRes expects to find it.
    public var fileType: AVFileType {
        switch self {
        case .h264, .hevc: .mp4
        case .proRes, .proRes4444: .mov
        }
    }

    public var fileExtension: String {
        switch self {
        case .h264, .hevc: "mp4"
        case .proRes, .proRes4444: "mov"
        }
    }

    var videoCodec: AVVideoCodecType {
        switch self {
        case .h264: .h264
        case .hevc: .hevc
        case .proRes: .proRes422
        case .proRes4444: .proRes4444
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
        case .proRes, .proRes4444: 1  // unused: ProRes takes no average bit rate
        }
    }

    /// Whether an average bit rate means anything for this codec.
    public var takesBitRate: Bool { self != .proRes && self != .proRes4444 }

    /// Bits per pixel per frame, for the intra codecs, from Apple's published data rates:
    /// 147 Mbps for ProRes 422 at 1080p29.97 and 330 for 4444. Both work out by dividing by
    /// `1920 × 1080 × 29.97`.
    var intraBitsPerPixel: Double {
        switch self {
        case .proRes: 2.37
        case .proRes4444: 5.31
        case .h264, .hevc: 0
        }
    }
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

    /// The rungs worth offering for a recording of this size.
    ///
    /// **Nothing above what was captured.** A ladder written as a fixed list offers 4K for a
    /// 720p recording, and upscaling adds no detail — it adds pixels, and a bit rate computed
    /// from pixels then spends four times as much on the same picture. The recording is the
    /// ceiling for the same reason a display is the ceiling on a capture rate.
    ///
    /// `matchRecording` is always first, because a capture's own size is the answer a person is
    /// most often after and the only rung that stays right on a display nobody has yet.
    public static func available(recordingShortSide: Int) -> [ExportResolution] {
        [.matchRecording] + allCases.filter { rung in
            guard let side = rung.shortSide else { return false }
            // Within a rung of the capture counts as reachable: a 1964-tall recording should
            // still offer 2160 rather than stopping at 1440, since the difference is a crop
            // away and refusing it would be pedantry a person cannot act on.
            return side <= recordingShortSide
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

/// How many frames a second the export writes.
///
/// **The export was writing 60 whatever the recording was.** Measured: the recorder offers 30,
/// 60 and 120, and every export resampled to 60 — so a 30 fps capture had every frame written
/// twice, at twice the bit rate the estimate then quoted, and a 120 fps capture lost half of
/// what it had. a Swift recorder's export sheet has this picker for the same reason, with a custom
/// field beside it.
public enum ExportFrameRate: String, Hashable, Sendable, Codable, CaseIterable {
    case matchRecording, fps24, fps30, fps60, fps120

    public var displayName: String {
        switch self {
        case .matchRecording: "Match Recording"
        case .fps24: "24 fps"
        case .fps30: "30 fps"
        case .fps60: "60 fps"
        case .fps120: "120 fps"
        }
    }

    /// The rungs worth offering for a recording at this rate. Nothing above it, for
    /// `ExportResolution.available`'s reason: writing each captured frame twice is a bigger file
    /// of the same video.
    public static func available(recording: Int) -> [ExportFrameRate] {
        [.matchRecording] + allCases.filter { rung in
            guard rung != .matchRecording else { return false }
            return rung.frames(recording: recording) == rung.frames(recording: .max)
        }
    }

    /// **Clamped to the recording's own rate, never above it.** Asking for 60 from a 30 fps
    /// capture is asking a resampler to invent thirty frames a second that were never captured:
    /// it writes each one twice, which is a bigger file of the same video. Down is a real
    /// choice — 60 to 30 halves the file and most screen recordings survive it — and up is not.
    public func frames(recording: Int) -> Int {
        let recorded = max(recording, 1)
        switch self {
        case .matchRecording: return recorded
        case .fps24: return min(24, recorded)
        case .fps30: return min(30, recorded)
        case .fps60: return min(60, recorded)
        case .fps120: return min(120, recorded)
        }
    }
}
