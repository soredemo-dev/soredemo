import Foundation
import Render
import Timeline

/// **The shortcuts a person pressed, as badges that appear and fade.** `cursor-render`'s
/// ROADMAP row has claimed "shortcut badges" since Phase 3 and nothing ever read a `key`
/// record; this is the reader. The recorder only ever writes approved shortcuts
/// (`InputObserver.approvedShortcuts`), so every press here is one a viewer is meant to see —
/// ⌘C, ⇧⌘Z — and never a character somebody typed.
///
/// **A press replaces the badge, it does not stack.** Two shortcuts a second apart are two
/// badges in turn; a second press inside the first's hold restarts the hold with the new
/// text. A list of concurrent segments, each fading, is the alternative; a single
/// badge is what published footage shows, and one thing to read at a
/// time is the point of a badge.
///
/// **Absolute host time, like every observation.** A press is stamped by the recorder's clock
/// and looked up through the compositor's anchor, the way the pointer is — not retimed
/// through the edit, which is the caption track's job and its own answer.
public struct KeystrokeTrack: Sendable, Equatable {
    public struct Press: Hashable, Sendable {
        public let instant: HostInstant
        public let shortcut: String

        public init(instant: HostInstant, shortcut: String) {
            self.instant = instant
            self.shortcut = shortcut
        }
    }

    /// How long a badge stays fully visible after the press. Long enough to read a
    /// three-glyph shortcut twice; a viewer who missed it the first time has a second look.
    /// **Uncalibrated.**
    public static let hold = Nanoseconds(900_000_000)
    /// The rise and the fall. Short in, so a badge lands with the press; longer out, so it
    /// leaves rather than blinks. **Uncalibrated.**
    public static let fadeIn = Nanoseconds(120_000_000)
    public static let fadeOut = Nanoseconds(280_000_000)

    private let presses: [Press]     // sorted by host time

    public init(presses: [Press] = []) {
        self.presses = presses.sorted { $0.instant.hostTime.rawValue < $1.instant.hostTime.rawValue }
    }

    public var isEmpty: Bool { presses.isEmpty }
    public var count: Int { presses.count }

    /// The badge on screen at `instant` — the most recent press in this epoch whose hold and
    /// fade have not run out — with its opacity, or `nil` for none.
    ///
    /// The fade-in reaches back BEFORE the press by `fadeIn`, so the badge is at full opacity
    /// at the instant the key went down rather than starting to appear then: a badge that
    /// lands late reads as a reaction to the press instead of the press itself.
    public func badge(at instant: HostInstant) -> KeystrokeBadge? {
        let time = instant.hostTime.rawValue
        // Epoch first, for the reason every other track gives: overlapping host times.
        // The most recent press at or before `time + fadeIn` is the one being shown.
        var latest: Press?
        for press in presses
        where press.instant.epoch == instant.epoch
            && press.instant.hostTime.rawValue <= time + Self.fadeIn.rawValue {
            latest = press
        }
        guard let latest else { return nil }
        let pressed = latest.instant.hostTime.rawValue
        let rise = Double(Self.fadeIn.rawValue)
        let holdEnd = pressed + Self.hold.rawValue
        let fallEnd = holdEnd + Self.fadeOut.rawValue
        let opacity: Double
        if time < pressed {
            opacity = 1 - Double(pressed - time) / rise
        } else if time <= holdEnd {
            opacity = 1
        } else if time < fallEnd {
            opacity = 1 - Double(time - holdEnd) / Double(Self.fadeOut.rawValue)
        } else {
            return nil
        }
        return KeystrokeBadge(text: latest.shortcut, opacity: min(max(opacity, 0), 1))
    }
}
