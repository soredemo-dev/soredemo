import Foundation
import Timeline

/// Which set of limits a line is judged against.
///
/// **Two, not one per language.** The figures below differ because a full-width character
/// carries roughly what two or three letters do, not because Chinese and Japanese are different
/// from each other — so the split that matters is whether the script has word gaps at all, which
/// is also the only thing this can tell by looking. A language list would be a third answer to a
/// question the text already answers.
public enum CaptionScript: Sendable, Equatable {
    /// Latin and everything else written with spaces between words.
    case spaced
    /// Chinese, Japanese, Korean — written without word gaps.
    case dense

    /// **A space anywhere means spaced.** Deliberately generous toward `.spaced`: a mixed line
    /// with one English word in it is still mostly dense, but judging it by the dense limits
    /// would fail a line nobody would call too fast. Being wrong in the lenient direction here
    /// costs a warning nobody sees; being wrong the other way costs a warning on a fine line,
    /// which is how people learn to ignore warnings.
    public static func of(_ text: String) -> CaptionScript {
        text.contains(" ") ? .spaced : .dense
    }

    /// The widest a line may be, in DISPLAY WIDTH — see `CaptionMeasurement.width(of:)`.
    ///
    /// 42 for Latin script and about 16 charactersToRead for CJK are the published figures; in width
    /// they are 42 and 32, because a full-width character occupies two columns. Two numbers
    /// rather than one because the guidelines really do differ here: a CJK line is held shorter
    /// than its width alone would allow.
    public var longestLine: Int {
        switch self {
        case .spaced: 42
        case .dense: 32
        }
    }
}

extension CaptionMeasurement {
    /// **One reading speed, in display width per second, and the two published figures are what
    /// it reproduces.**
    ///
    /// The guidelines give 17 charactersToRead a second for Latin script and 9 for CJK. Measured in
    /// DISPLAY WIDTH — a full-width character being two columns — those are 17 and 18: the same
    /// number within six per cent. They differ because they are quoted in different units, not
    /// because reading Chinese is a different act.
    ///
    /// **This is what closes the mixed-line hole.** `CaptionScript.of` calls a line spaced if it
    /// contains one space anywhere, so a Chinese caption with a single English word in it was
    /// held to the Latin limit — documented as a deliberately lenient failure and now simply
    /// gone, because width counts each character for what it occupies whatever its neighbours
    /// are.
    public static let widthPerSecond: Double = 17

    /// East-Asian display width: a full-width character is two columns, everything else is one.
    /// The ranges are the usual East_Asian_Width approximation rather than the full table, which
    /// is a property lookup this tier cannot make and would change nothing a caption contains.
    public static func width(of text: String) -> Int {
        text.unicodeScalars.reduce(0) { total, scalar in
            guard !CharacterSet.whitespacesAndNewlines.contains(scalar) else { return total }
            let v = scalar.value
            let wide = (v >= 0x1100 && v <= 0x115F)
                || (v >= 0x2E80 && v <= 0xA4CF)
                || (v >= 0xAC00 && v <= 0xD7A3)
                || (v >= 0xF900 && v <= 0xFAFF)
                || (v >= 0xFE30 && v <= 0xFE4F)
                || (v >= 0xFF00 && v <= 0xFF60)
                || (v >= 0xFFE0 && v <= 0xFFE6)
            return total + (wide ? 2 : 1)
        }
    }
}

/// What is measurably wrong with one caption, or nothing.
///
/// **A named case rather than a bool or a score.** A number tells somebody a line is bad without
/// telling them what to do about it, and the three things that go wrong have three different
/// fixes: too fast wants fewer words or more time, too brief wants more time, too long wants the
/// line split. `displayName` is what the panel shows beside the reading speed.
public enum CaptionFault: String, Sendable, Equatable, CaseIterable, Codable {
    /// More charactersToRead than a person can read in the time it is on screen.
    case tooFast
    /// On screen for less than the floor, whatever it says. A line nobody can start reading.
    case tooBrief
    /// On screen far longer than it needs, which reads as a caption that got stuck.
    case tooLong

    public var displayName: String {
        switch self {
        case .tooFast: "Too fast"
        case .tooBrief: "Too brief"
        case .tooLong: "Too long"
        }
    }
}

/// One caption's own numbers, and the verdict on them.
///
/// **Computed, never stored.** Every value here is arithmetic over a `CaptionCue`'s text and
/// span, so storing it would be a second copy to keep in step with the first — and it is the
/// second copy that goes stale after a retime.
public struct CaptionMeasurement: Sendable, Equatable {
    public let script: CaptionScript
    /// What a reader reads, in display width. Whitespace is excluded — a line is not harder to
    /// read for having spaces in it, which is also how reading-speed figures are defined.
    public let charactersToRead: Int
    public let seconds: Double
    /// Display width a second. `.infinity` for a zero-length cue, which is what `tooBrief` is
    /// for rather than a division that produces a number nobody can read.
    public let charactersPerSecond: Double
    public let fault: CaptionFault?

    /// The floor a caption stays on screen: **five-sixths of a second**, the figure subtitling
    /// guidelines give (twenty frames at 24 fps).
    ///
    /// One owner for the number. `CaptionBuilder.minimumDisplay` is this value: a builder that
    /// enforced 700 ms while a panel warned below 833 would be two answers to one question, and
    /// the warning would fire on lines the builder had just produced.
    public static let shortestDisplay = Nanoseconds(833_333_333)

    /// The ceiling. Seven seconds is the published maximum for one subtitle event; past it a
    /// line has stopped being a caption and started being a title.
    public static let longestDisplay = Nanoseconds(7_000_000_000)

    /// Counts what a reader reads, in display width. Whitespace is excluded because a line is
    /// not harder to read for having spaces in it, which is also how the figures are defined.
    public static func readableCharacters(in text: String) -> Int {
        width(of: text)
    }

    public init(text: String, duration: Nanoseconds) {
        let script = CaptionScript.of(text)
        self.script = script
        charactersToRead = Self.readableCharacters(in: text)
        seconds = Double(duration.rawValue) / 1_000_000_000
        charactersPerSecond = seconds > 0 ? Double(charactersToRead) / seconds : .infinity

        // **Order matters and is the point.** A 200 ms cue is also technically far too fast, and
        // reporting that would send somebody to shorten a line whose real problem is that it is
        // barely on screen. The floor is checked first so the fix named is the fix needed.
        if duration.rawValue < Self.shortestDisplay.rawValue {
            fault = .tooBrief
        } else if duration.rawValue > Self.longestDisplay.rawValue {
            fault = .tooLong
        } else if charactersPerSecond > Self.widthPerSecond {
            fault = .tooFast
        } else {
            fault = nil
        }
    }
}

extension CaptionCue {
    /// This cue's numbers. See `CaptionMeasurement`.
    public var measurement: CaptionMeasurement {
        CaptionMeasurement(text: text, duration: duration)
    }
}
