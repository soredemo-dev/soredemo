import Project
import Timeline

/// Proposes removing spans in which nothing happened.
///
/// **Quiet means all of them at once**: no press, no click, no shortcut, no pointer movement
/// beyond a tremble, no speech, and the observer watching. A pause filled by narration is not
/// dead air, and neither is a span the observer could not see — secure input emits nothing, which
/// is the absence of a measurement, not stillness.
///
/// **A breath is kept on each side**, so a removal shortens a pause rather than butting the next
/// press against the last; at the recording's own start and end nothing is kept, because nothing
/// is there to breathe around. A recording in which nothing happened at all proposes nothing.
///
/// **Every constant is uncalibrated**, like the rest of this module's: chosen, not yet measured
/// against real takes (`ARCHITECTURE.md` D4).
public struct DeadAirProposer: CutProposer {
    /// The shortest quiet span proposed.
    public static let minimumQuiet = Nanoseconds(2_000_000_000)
    /// Kept after the last thing that happened, and before the next.
    public static let breath = Nanoseconds(500_000_000)
    /// A pointer that moved less than this, in normalised display units from where it last came
    /// to rest, has not moved: a hand on a mouse trembles.
    public static let stillRadius = 0.005

    public init() {}

    public func proposals(for take: TakeActivity) -> [CutProposal] {
        let epoch = take.recording.epoch
        let start = take.recording.start.rawValue
        let end = take.recording.end.rawValue
        var proposals: [CutProposal] = []
        var coveredUntil = start
        var openedBy = CutProposal.Boundary.recordingStart

        let inside = Self.activities(in: take).filter { $0.start < end }
        for activity in inside + [Activity(start: end, end: end, boundary: .recordingEnd)] {
            if activity.start > coveredUntil, activity.start - coveredUntil >= Self.minimumQuiet.rawValue,
               !(openedBy == .recordingStart && activity.boundary == .recordingEnd) {
                let keepAfter = openedBy == .recordingStart ? 0 : Self.breath.rawValue
                let keepBefore = activity.boundary == .recordingEnd ? 0 : Self.breath.rawValue
                let quiet = HostRange(epoch: epoch, start: Nanoseconds(coveredUntil),
                                      duration: Nanoseconds(activity.start - coveredUntil))
                let removes = HostRange(epoch: epoch, start: Nanoseconds(coveredUntil + keepAfter),
                                        duration: Nanoseconds(activity.start - keepBefore - coveredUntil - keepAfter))
                proposals.append(CutProposal(reason: .deadAir, quiet: quiet, removes: removes,
                                             openedBy: openedBy, closedBy: activity.boundary,
                                             duringStep: Self.step(at: coveredUntil, in: take.steps)))
            }
            // Strictly later: at one instant the first-sorted activity keeps the name.
            if activity.end > coveredUntil {
                coveredUntil = activity.end
                openedBy = activity.boundary
            }
        }
        return proposals
    }

    /// Something that happened, from `start` to `end` in host nanoseconds; an instant has both equal.
    private struct Activity {
        let start: Int64
        let end: Int64
        let boundary: CutProposal.Boundary
    }

    /// Everything that happened, in time order. **At one instant a press sorts before a bare
    /// click**: the click under a step is that step's press, and the step's number is the more
    /// useful thing to name.
    private static func activities(in take: TakeActivity) -> [Activity] {
        var found: [(Activity, Int)] = []
        func instant(_ i: HostInstant, _ boundary: CutProposal.Boundary, _ rank: Int) {
            found.append((Activity(start: i.hostTime.rawValue, end: i.hostTime.rawValue, boundary: boundary), rank))
        }
        func span(_ r: HostRange, _ boundary: CutProposal.Boundary, _ rank: Int) {
            found.append((Activity(start: r.start.rawValue, end: r.end.rawValue, boundary: boundary), rank))
        }
        for step in take.steps { instant(step.origin, .press(step: step.number), 0) }
        for button in take.buttons { instant(button.instant, .click, 1) }
        for key in take.shortcuts { instant(key.instant, .shortcut, 2) }
        for moved in movements(in: take.pointer) { instant(moved, .pointerMoved, 3) }
        for spoken in take.speech { span(spoken, .speech, 4) }
        for hidden in take.unobserved { span(hidden, .unobserved, 5) }
        return found.sorted { ($0.0.start, $0.1) < ($1.0.start, $1.1) }.map(\.0)
    }

    /// The instants at which the pointer left where it had come to rest. **Measured from the rest
    /// position, not from the previous sample**, so a slow drift made of trembles still counts once
    /// it has gone far enough; a change of display arrangement always counts.
    private static func movements(in samples: [PointerSample]) -> [HostInstant] {
        let ordered = samples.sorted { $0.instant.hostTime < $1.instant.hostTime }
        guard var rest = ordered.first else { return [] }
        var moved: [HostInstant] = []
        for sample in ordered.dropFirst() {
            let dx = sample.position.x - rest.position.x
            let dy = sample.position.y - rest.position.y
            if sample.revision != rest.revision || (dx * dx + dy * dy).squareRoot() >= stillRadius {
                moved.append(sample.instant)
                rest = sample
            }
        }
        return moved
    }

    /// The number of the last step to begin at or before `time`.
    private static func step(at time: Int64, in steps: [RecordedStep]) -> Int? {
        steps.filter { $0.origin.hostTime.rawValue <= time }.max { $0.origin.hostTime < $1.origin.hostTime }?.number
    }
}
