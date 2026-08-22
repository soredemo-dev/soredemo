import Foundation
import Timeline

/// Captions as a sidecar file — SubRip (`.srt`) or WebVTT (`.vtt`).
///
/// **A sidecar rather than only burnt-in pixels, and the difference is who can use it.** A
/// burnt-in caption is part of the picture: it cannot be turned off, translated, searched, or
/// read by a screen reader, and it is wrong at every size but the one it was rendered for. A
/// sidecar is what YouTube, Vimeo, and every video tag accept. Both are worth having and this
/// project should ship both; this file is the half that costs almost nothing.
///
/// Timestamps are formatted from integer nanoseconds with no floating-point step, because both
/// formats are millisecond-precise and a `Double` seconds round-trip is exactly where a cue ends
/// up one millisecond before the frame it belongs to.
public enum SubtitleFile {
    public enum Format: String, Sendable, CaseIterable, Codable {
        case subRip = "srt"
        case webVTT = "vtt"

        public var fileExtension: String { rawValue }

        public var displayName: String {
            switch self {
            case .subRip: "SubRip (.srt)"
            case .webVTT: "WebVTT (.vtt)"
            }
        }
    }

    /// The file's text. `\n` throughout: both specifications allow it, and CRLF is a Windows
    /// convention that survives only until something rewrites the file.
    public static func text(for track: CaptionTrack, format: Format) -> String {
        switch format {
        case .subRip: subRip(track)
        case .webVTT: webVTT(track)
        }
    }

    private static func subRip(_ track: CaptionTrack) -> String {
        // SubRip cues are numbered from 1 and the number is not optional — players use it to
        // report a malformed file, and several refuse a file that starts at 0.
        track.cues.enumerated().map { index, cue in
            "\(index + 1)\n"
            + "\(timestamp(cue.start, separator: ",")) --> \(timestamp(cue.end, separator: ","))\n"
            + "\(cue.text)\n"
        }.joined(separator: "\n")
    }

    private static func webVTT(_ track: CaptionTrack) -> String {
        // The header is mandatory and a file without it is rejected outright by browsers.
        "WEBVTT\n\n" + track.cues.map { cue in
            "\(timestamp(cue.start, separator: ".")) --> \(timestamp(cue.end, separator: "."))\n"
            + "\(cue.text)\n"
        }.joined(separator: "\n")
    }

    /// `HH:MM:SS,mmm` or `HH:MM:SS.mmm`. The only difference between the two formats' timestamps
    /// is that separator, which is why one function writes both.
    ///
    /// Negative times are clamped to zero rather than written with a minus sign: no player
    /// accepts a negative cue, and a caption track retimed through an edit is the kind of thing
    /// that can produce one.
    static func timestamp(_ time: Nanoseconds, separator: String) -> String {
        let total = max(0, time.rawValue)
        let milliseconds = total / 1_000_000
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let seconds = (milliseconds / 1_000) % 60
        let remainder = milliseconds % 1_000
        return pad(hours, 2) + ":" + pad(minutes, 2) + ":" + pad(seconds, 2)
            + separator + pad(remainder, 3)
    }

    private static func pad(_ value: Int64, _ width: Int) -> String {
        let digits = String(value)
        return digits.count >= width
            ? digits
            : String(repeating: "0", count: width - digits.count) + digits
    }
}
