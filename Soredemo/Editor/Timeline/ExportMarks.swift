import Timeline

/// Where an export of part of the video begins and ends, in OUTPUT time. **Both `nil` is the
/// ordinary case** — most exports are the whole video, and a range that defaulted to something
/// would make every export a decision.
///
/// Without it the workaround is: duplicate the project, trim the copy, export, repeat. Once per
/// section, with a fresh chance to trim the wrong edge each time.
///
/// **Output time, and the caller converts.** These are points in the video a person is
/// watching; `TimelineEditorModel.markIn()` turns its source-time playhead into one before it
/// gets here. See `docs/design/2026-10-23-the-timeline-model-and-its-two-clocks.md`.
struct ExportMarks: Equatable {
    private(set) var inPoint: Nanoseconds?
    private(set) var outPoint: Nanoseconds?

    /// Sets the in point, or clears it if it is already there.
    ///
    /// **Pressing the key again cancels**, which is how a person undoes a mark without reaching
    /// for a menu. Clearing an out point that now sits before the in point too: leaving a pair
    /// that selects nothing would make the export silently fall back to the whole video.
    mutating func markIn(at time: Nanoseconds) {
        if inPoint == time { inPoint = nil; return }
        inPoint = time
        if let out = outPoint, out.rawValue <= time.rawValue { outPoint = nil }
    }

    mutating func markOut(at time: Nanoseconds) {
        if outPoint == time { outPoint = nil; return }
        outPoint = time
        if let into = inPoint, into.rawValue >= time.rawValue { inPoint = nil }
    }

    mutating func clear() {
        inPoint = nil
        outPoint = nil
    }

    /// The range an export should cover, or `nil` for the whole video.
    ///
    /// **One end is enough.** An in point alone means "from here to the end" and an out point
    /// alone means "from the start to here", which is what those gestures mean in every editor
    /// that has them — requiring both would make the first keystroke do nothing.
    func range(outputDuration: Nanoseconds) -> Range<Int64>? {
        let total = outputDuration.rawValue
        guard total > 0, inPoint != nil || outPoint != nil else { return nil }
        let lower = max(inPoint?.rawValue ?? 0, 0)
        let upper = min(outPoint?.rawValue ?? total, total)
        guard lower < upper else { return nil }
        // The whole video is not a range: an in point dragged back to zero has been cancelled,
        // and reporting a range there would put "1 of 1 sections" in the export sheet forever.
        guard lower > 0 || upper < total else { return nil }
        return lower..<upper
    }
}
