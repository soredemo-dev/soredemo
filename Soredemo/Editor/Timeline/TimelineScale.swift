import Foundation
import Timeline

/// Points across the strip and time in the recording, at one width and one window.
///
/// **Through the window, never by dividing here.** A second copy of this conversion is how a
/// zoomed strip ends up drawing clips in one space and the playhead in another, so every lane
/// asks `TimelineWindow` and this only supplies the width.
///
/// **Failable at no width.** The private methods this replaces answered the recording's start
/// for any point and a zero span for any distance when the strip had no width yet — legal
/// answers both, so a strip measured before layout read as a click at time zero. There is no
/// conversion to make, and a caller now has to say what it does instead.
struct TimelineScale: Equatable {
    let window: TimelineWindow
    let width: Double

    init?(window: TimelineWindow, width: Double) {
        guard width > 0 else { return nil }
        self.window = window
        self.width = width
    }

    /// How close a drag must come to an edge to snap, in POINTS. Converted to time against the
    /// strip's own width, so the tolerance is the same distance on screen at any recording
    /// length rather than the same number of nanoseconds.
    static let snapPoints: Double = 8

    /// Where `time` is drawn. Not clamped, for the reason `TimelineWindow.fraction(of:)` gives.
    func x(of time: Nanoseconds) -> Double {
        window.fraction(of: time) * width
    }

    /// How wide a span is drawn. **A difference of two positions**: the window's fraction
    /// measures from its start, so a length is not a position.
    func width(from start: Nanoseconds, to end: Nanoseconds) -> Double {
        x(of: end) - x(of: start)
    }

    /// The instant under a point, clamped into the recording.
    ///
    /// **Named `position`, not `time`** — `TimelineWindow.position(atFraction:)` says why.
    func position(atX x: Double) -> Nanoseconds {
        window.position(atFraction: x / width)
    }

    /// A distance on screen as a span of the recording. **Scaled by the WINDOW, not the
    /// recording**, so eight points is eight points of screen at every zoom rather than eight
    /// points of the whole file.
    func span(forPoints points: Double) -> Nanoseconds {
        window.duration(forFraction: points / width)
    }

    /// A drag's translation as a signed offset in the recording: left is earlier.
    ///
    /// **Signed, which `span(forPoints:)` is not.** `TimelineWindow.duration(forFraction:)`
    /// returns a magnitude, right for a snap tolerance and wrong for a drag. The trim handles
    /// were converted through it in `b7d9bbb` and from then on a handle dragged LEFT moved its
    /// edge right — the zoom lane, written the same day, put the sign back by hand and the trim
    /// handles never did. One function for both means neither can forget.
    func offset(forPoints points: Double) -> Int64 {
        let magnitude = span(forPoints: points).rawValue
        return points < 0 ? -magnitude : magnitude
    }

    /// How near counts as lining up: `snapPoints` of screen at this zoom, or nothing when
    /// `exact` — ⌘ held, the key editors use for "put it exactly where my hand is".
    func snapThreshold(exact: Bool) -> Nanoseconds {
        exact ? Nanoseconds(0) : span(forPoints: Self.snapPoints)
    }
}
