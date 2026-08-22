import Foundation

/// Which part of a recording a timeline strip is showing, and the conversion between a
/// position on that strip and a time in the recording.
///
/// **Its own type, and in the deterministic tier, because this is where an off-by-one becomes
/// invisible.** A strip that maps the whole recording to its width needs no state — the view
/// can divide — and that is what Soredemo's did. The moment it can be zoomed and scrolled,
/// the same conversion appears in the drag handler, the clip rectangles, the playhead, the
/// trim handles and the waveform, and five copies of one rule is the shape this project keeps
/// finding bugs in. There is one copy, and it is tested without a window.
///
/// Held in SOURCE time, not in a zoom factor plus an offset: a factor is a derived quantity
/// and two views computing it from different rounding disagree at the edges.
public struct TimelineWindow: Hashable, Sendable {
    /// The recording's full length. The window is always inside it.
    public let total: Nanoseconds
    /// The first instant on screen.
    public let start: Nanoseconds
    /// How much of the recording is on screen.
    public let visible: Nanoseconds

    /// **Clamped on construction rather than on use.** A window that could be out of bounds
    /// would have to be checked by every caller, and the one that forgot would scroll off the
    /// end of the recording.
    public init(total: Nanoseconds, start: Nanoseconds, visible: Nanoseconds) {
        precondition(total.rawValue >= 0, "a recording cannot have negative length")
        self.total = total
        let span = min(max(visible.rawValue, Self.minimumVisible), max(total.rawValue, 1))
        self.visible = Nanoseconds(span)
        self.start = Nanoseconds(min(max(start.rawValue, 0), max(total.rawValue - span, 0)))
    }

    /// The whole recording, which is where every strip starts.
    public static func whole(_ total: Nanoseconds) -> TimelineWindow {
        TimelineWindow(total: total, start: Nanoseconds(0), visible: total)
    }

    /// **A tenth of a second is the deepest zoom.** Past that a strip a few hundred points
    /// wide is showing under a millisecond per point, which is finer than a frame at any
    /// frame rate this records at — the extra depth would show the same frame across the
    /// whole strip.
    public static let minimumVisible: Int64 = 100_000_000

    public var end: Nanoseconds { Nanoseconds(start.rawValue + visible.rawValue) }

    /// How much of the recording is on screen, 1 when all of it is. For a zoom readout; never
    /// used as state, for the reason the header gives.
    public var magnification: Double {
        total.rawValue > 0 ? Double(total.rawValue) / Double(visible.rawValue) : 1
    }

    public var canZoomIn: Bool { visible.rawValue > Self.minimumVisible }
    public var canZoomOut: Bool { visible.rawValue < total.rawValue }

    // MARK: - conversion

    /// Where `time` falls across the strip, 0 at the left edge and 1 at the right.
    ///
    /// **Not clamped**, so a caller can tell that a clip starts before the window and draw it
    /// running off the edge rather than piled against it.
    public func fraction(of time: Nanoseconds) -> Double {
        guard visible.rawValue > 0 else { return 0 }
        return Double(time.rawValue - start.rawValue) / Double(visible.rawValue)
    }

    /// The instant at a fraction across the strip, clamped into the recording — a drag can
    /// leave the view's bounds, and a position outside the recording is not one anything can
    /// use.
    ///
    /// **Named `position`, not `time`.** `noAppSourceReadsAnAmbientValueAtAll` bans the
    /// spelling `time(` anywhere in the app, because that is how C's `time()` reads an ambient
    /// clock — the one thing `Minting` exists to be the sole owner of. The scan cannot tell a
    /// clock read from a coordinate conversion, and a ban a reader has to except by hand is a
    /// ban that stops being read.
    public func position(atFraction fraction: Double) -> Nanoseconds {
        let raw = Double(start.rawValue) + fraction * Double(visible.rawValue)
        return Nanoseconds(Int64(min(max(raw, 0), Double(total.rawValue))))
    }

    /// A screen distance as a span of the recording — what a snap tolerance in points, or a
    /// drag's translation, means in time at this zoom.
    public func duration(forFraction fraction: Double) -> Nanoseconds {
        Nanoseconds(Int64(abs(fraction) * Double(visible.rawValue)))
    }

    // MARK: - zooming

    /// Zoomed by `factor` about a fixed point on the strip.
    ///
    /// **The anchor is what makes zooming usable.** Zooming about the window's start walks the
    /// content out from under the cursor; anchoring on the pointer — or on the playhead for a
    /// keyboard zoom — keeps the thing a person is looking at where they are looking.
    public func zoomed(by factor: Double, anchoredAtFraction anchor: Double) -> TimelineWindow {
        guard factor > 0, total.rawValue > 0 else { return self }
        let anchorTime = Double(start.rawValue) + anchor * Double(visible.rawValue)
        let span = Double(visible.rawValue) / factor
        let clamped = min(max(span, Double(Self.minimumVisible)), Double(total.rawValue))
        return TimelineWindow(total: total,
                              start: Nanoseconds(Int64(anchorTime - anchor * clamped)),
                              visible: Nanoseconds(Int64(clamped)))
    }

    /// Scrolled by a fraction of the visible span — a two-finger swipe, or a drag past the edge.
    public func scrolled(byFraction fraction: Double) -> TimelineWindow {
        TimelineWindow(total: total,
                       start: Nanoseconds(start.rawValue
                                          + Int64(fraction * Double(visible.rawValue))),
                       visible: visible)
    }

    /// Scrolled so `time` is on screen, moving as little as possible.
    ///
    /// **Nothing happens when it already is**, which is what stops a playhead near the middle
    /// from dragging the view with it on every frame of playback.
    public func revealing(_ time: Nanoseconds) -> TimelineWindow {
        if time.rawValue >= start.rawValue && time.rawValue <= end.rawValue { return self }
        let target = time.rawValue < start.rawValue
            ? time.rawValue
            : time.rawValue - visible.rawValue
        return TimelineWindow(total: total, start: Nanoseconds(target), visible: visible)
    }
}
