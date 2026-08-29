import AVFoundation
import Foundation

/// How many bits the MASTER is allowed to spend — the recording every export is made from.
///
/// **Nothing was being set, and the master is the bottleneck.** `CaptureSession` handed the
/// writer a codec, a size and colour tags, and AVFoundation chose the rate: Apple's own
/// assistant picks ~10.5 Mbps for 1080p, a figure for camera footage, and the master is
/// the ceiling on every export — `ExportQuality`'s argument for the export's rate applies
/// one step earlier and with more force, because a bit the master did not keep is a bit no
/// export can ask for. The colour-pipeline note (2026-08-24) said this in words and left the
/// setting alone.
///
/// **The same arithmetic as `ExportQuality.best`, restated here because `Capture` cannot
/// import `Compositing`.** 0.3 bits per pixel per frame, tapered above 30 fps by 0.6
/// since a doubled frame rate does not need doubled bits, with a 2 Mbps floor for a small
/// window. `theMasterSpendsWhatTheBestExportSpends` in `CaptureTests` pins the 1080p60
/// figure to the number `ExportQuality.best` produces, so the two cannot drift apart
/// silently; a change to one is a red in the other.
///
/// H.264 High with CABAC and a two-second GOP, for the reasons `ExportQuality.videoSettings`
/// gives; the codec itself stays H.264 because the master is read by every tool this
/// project tests with and hardware encodes it in real time at any size a display has.
public enum MasterQuality {
    /// The same figure `ExportQuality.best` uses.
    public static let bitsPerPixel: Double = 0.3
    /// `ExportQuality.effectiveFrameRate`'s taper, verbatim.
    public static func effectiveFrameRate(_ frameRate: Int) -> Double {
        min(Double(frameRate), 30) + max(Double(frameRate) - 30, 0) * 0.6
    }

    public static func videoBitRate(pixelWidth: Int, pixelHeight: Int, frameRate: Int) -> Int {
        let pixels = Double(pixelWidth * pixelHeight)
        let rate = pixels * bitsPerPixel * effectiveFrameRate(frameRate)
        return max(Int(rate.rounded()), 2_000_000)
    }

    /// The compression properties for the master's writer input.
    public static func compressionProperties(pixelWidth: Int, pixelHeight: Int,
                                             frameRate: Int) -> [String: any Sendable] {
        [
            AVVideoAverageBitRateKey: videoBitRate(pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                                                   frameRate: frameRate),
            AVVideoExpectedSourceFrameRateKey: frameRate,
            AVVideoMaxKeyFrameIntervalKey: max(frameRate * 2, 2),
            AVVideoAllowFrameReorderingKey: true,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
        ]
    }
}
