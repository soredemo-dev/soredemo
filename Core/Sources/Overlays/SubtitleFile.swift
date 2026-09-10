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

// MARK: - reading one back

/// Reading a sidecar somebody edited elsewhere.
///
/// **The escape hatch, and the reason it is worth having is everything this app cannot do.**
/// A dedicated subtitle editor has a waveform, a spellchecker and twenty years of shortcuts;
/// this has a list and four buttons. Writing a file and never reading one back makes the export
/// a one-way door — see `docs/design/what-a-caption-editor-is.md`.
extension SubtitleFile {
    /// Why one cue in a file was not used. **Named and counted rather than dropped**, because a
    /// file that quietly loses three lines is worse than one that refuses: the three are the
    /// ones somebody spent the most time on.
    public enum Refusal: Sendable, Equatable {
        /// A `-->` line neither format's timestamp grammar accepts.
        case unreadableTimestamp(line: Int)
        /// End at or before start. No player shows it and nothing here can guess which end moved.
        case endsBeforeItStarts(line: Int)
        /// A timestamp block with no text under it.
        case noText(line: Int)

        public var line: Int {
            switch self {
            case let .unreadableTimestamp(line), let .endsBeforeItStarts(line),
                 let .noText(line): line
            }
        }
    }

    /// What a file turned out to contain.
    public struct Reading: Sendable, Equatable {
        public let track: CaptionTrack
        public let format: Format
        /// Cues the file had and this could not use. Empty for a clean file.
        public let refused: [Refusal]
        /// Cues whose end was pulled back because the next cue started before it. A sidecar from
        /// elsewhere may legitimately overlap — several formats allow two cues at once — and
        /// this project's own invariant is that they do not, so the trim is reported rather than
        /// done silently.
        public let overlapsTrimmed: Int
    }

    public enum ReadError: Error, Sendable, Equatable {
        /// Nothing in the file looked like a cue. Distinct from a file of refusals: that one had
        /// cues and they were wrong, this one is a text file somebody picked by mistake.
        case noCues
    }

    /// Parses `.srt` or `.vtt`. **Detected from the content, not the extension**, because a file
    /// that has been through a converter or a rename is exactly the file somebody is importing.
    ///
    /// Deliberately tolerant of what real files carry: a byte-order mark, CRLF, WebVTT `NOTE`
    /// blocks, a cue identifier on its own line before the timestamps, cue settings after them
    /// (`align:start position:10%`), several lines of text per cue, and a missing final newline.
    ///
    /// **Imported cues carry no word runs**, and nothing invents them: a sidecar has no per-word
    /// times, so word-by-word highlighting is off for what comes in this way until the recording
    /// is transcribed again. Stated here because a silently unhighlighted caption looks like the
    /// style not working.
    public static func read(_ text: String) throws -> Reading {
        let body = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        let lines = body.components(separatedBy: "\n")
        let format: Format = body.hasPrefix("WEBVTT") ? .webVTT : .subRip

        var cues: [CaptionCue] = []
        var refused: [Refusal] = []
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard line.contains("-->") else { index += 1; continue }

            guard let span = times(in: line) else {
                refused.append(.unreadableTimestamp(line: index + 1))
                index += 1
                continue
            }
            // Text runs to the next blank line. A cue identifier or a `NOTE` above the timestamp
            // line is skipped by the search above rather than parsed: nothing here needs it, and
            // a format's optional metadata is not this project's to reinterpret.
            var collected: [String] = []
            index += 1
            while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                collected.append(lines[index])
                index += 1
            }
            let content = collected.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if span.end.rawValue <= span.start.rawValue {
                refused.append(.endsBeforeItStarts(line: index))
            } else if content.isEmpty {
                refused.append(.noText(line: index))
            } else {
                cues.append(CaptionCue(text: content, start: span.start, end: span.end))
            }
        }
        guard !cues.isEmpty else { throw ReadError.noCues }

        // `CaptionTrack` sorts on the way in, so the trim below walks a list already in order.
        var track = CaptionTrack(cues: cues)
        var trimmed = 0
        var adjusted = track.cues
        for position in adjusted.indices.dropLast()
        where adjusted[position].end.rawValue > adjusted[position + 1].start.rawValue {
            adjusted[position].end = adjusted[position + 1].start
            trimmed += 1
        }
        // A trim can take a cue below the floor. Left that way rather than pushed back out: the
        // panel reports `tooBrief` on it, which tells the truth about the file, where silently
        // moving a boundary would tell the truth about nothing.
        track = CaptionTrack(cues: adjusted)
        return Reading(track: track, format: format, refused: refused, overlapsTrimmed: trimmed)
    }

    /// The two times on a `-->` line, or `nil`. Both separators are accepted whatever the file
    /// claimed to be, because a converter that wrote SubRip commas into a WebVTT file is common
    /// and the alternative is refusing a file every player reads.
    static func times(in line: String) -> (start: Nanoseconds, end: Nanoseconds)? {
        let halves = line.components(separatedBy: "-->")
        guard halves.count == 2 else { return nil }
        // Anything after the end time is a WebVTT cue setting: `align`, `position`, `line`.
        // Dropped rather than parsed — this project has one caption layout and it is the style's.
        let tail = halves[1].trimmingCharacters(in: .whitespaces)
            .components(separatedBy: " ").first ?? ""
        guard let start = nanoseconds(halves[0].trimmingCharacters(in: .whitespaces)),
              let end = nanoseconds(tail) else { return nil }
        return (start, end)
    }

    /// `HH:MM:SS,mmm`, `HH:MM:SS.mmm`, or WebVTT's two-field `MM:SS.mmm`.
    static func nanoseconds(_ text: String) -> Nanoseconds? {
        let normalised = text.replacingOccurrences(of: ",", with: ".")
        let parts = normalised.components(separatedBy: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let secondsField = parts[parts.count - 1].components(separatedBy: ".")
        guard secondsField.count <= 2 else { return nil }

        var whole: [Int64] = []
        for field in parts.dropLast() + [secondsField[0]] {
            guard !field.isEmpty, field.allSatisfy(\.isNumber), let value = Int64(field)
            else { return nil }
            whole.append(value)
        }
        let hours = whole.count == 3 ? whole[0] : 0
        let minutes = whole[whole.count - 2]
        let seconds = whole[whole.count - 1]

        var milliseconds: Int64 = 0
        if secondsField.count == 2 {
            let digits = secondsField[1]
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let value = Int64(digits)
            else { return nil }
            // A two-digit fraction is hundredths and a four-digit one is over-precise; both
            // appear in the wild, and scaling is what makes them mean what they say.
            milliseconds = digits.count >= 3
                ? value / Int64(pow(10, Double(digits.count - 3)))
                : value * Int64(pow(10, Double(3 - digits.count)))
        }
        // **Every step reports overflow, and this is a file somebody else wrote.**
        //
        // `Int64(field)` accepts anything up to 9.2 × 10^18, so `00000000999999999999999999:00:00`
        // is a timecode as far as the parse above is concerned — and `hours * 60` then traps,
        // which is a crash on opening a subtitle file rather than a refusal to read one. Checked
        // rather than reasoned about: the multiplication really does overflow at that value.
        //
        // Refused, not clamped. A clamp would turn a corrupt line into a cue at some plausible
        // time, which is worse than saying the line could not be read — `times(in:)` reports
        // every line it refused with its number, so the person can see which one.
        func step(_ value: Int64, times factor: Int64, plus addend: Int64) -> Int64? {
            let (scaled, scaleOverflowed) = value.multipliedReportingOverflow(by: factor)
            guard !scaleOverflowed else { return nil }
            let (sum, sumOverflowed) = scaled.addingReportingOverflow(addend)
            return sumOverflowed ? nil : sum
        }
        guard let inMinutes = step(hours, times: 60, plus: minutes),
              let inSeconds = step(inMinutes, times: 60, plus: seconds),
              let inMilliseconds = step(inSeconds, times: 1_000, plus: milliseconds),
              let inNanoseconds = step(inMilliseconds, times: 1_000_000, plus: 0)
        else { return nil }
        return Nanoseconds(inNanoseconds)
    }
}
