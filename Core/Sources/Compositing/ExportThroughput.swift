import Foundation

/// How fast this Mac exports, as pixels per second, and what that says about the next export.
///
/// **Pixels per second, because that is what was measured to be the limit.** An H.264 or HEVC
/// export runs at the media engine's pixel rate whatever the content, the codec or the pixel
/// format — `docs/design/2026-10-25-where-an-export-spends-its-time.md` — so a rate taken from
/// one export prices another of a different size and length. It is taken from THIS Mac's own
/// last export, never written in: the engines differ between Macs, and a constant measured on
/// one would be a confident wrong answer on the rest.
public enum ExportThroughput {
    /// The rate a finished export ran at, or `nil` when nothing was measured — no frames, no
    /// picture, or no time — rather than a number that would then price every later export.
    public static func pixelsPerSecond(frames: Int, width: Int, height: Int, seconds: Double) -> Double? {
        guard frames > 0, width > 0, height > 0, seconds.isFinite, seconds > 0 else { return nil }
        return Double(frames) * Double(width) * Double(height) / seconds
    }

    /// How long an export of this many frames at this size takes at `pixelsPerSecond`, or `nil`
    /// when the rate is not one.
    public static func seconds(frames: Int, width: Int, height: Int, pixelsPerSecond: Double) -> Double? {
        guard frames >= 0, width > 0, height > 0, pixelsPerSecond.isFinite, pixelsPerSecond > 0 else { return nil }
        return Double(frames) * Double(width) * Double(height) / pixelsPerSecond
    }
}
