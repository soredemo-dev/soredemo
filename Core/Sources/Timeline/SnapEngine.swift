import Foundation

/// Snapping a dragged timeline position to the edges near it.
///
/// **Written here, from the behaviour the tests below pin.** An earlier version of this file was
/// the standard shape for this — a threshold in points, a
/// variable roles, same two phases — and said so. That made this tree a derivative of a GPL-3.0
/// work and fixed its licence to copyleft. This is a re-expression: the BEHAVIOUR is unchanged
/// and `SnapEngineTests` is what proves it, but nothing here is written from their code.
///
/// The idea is not the point of dispute and is not claimed to be original: sticky snapping with
/// a hold threshold, an easier threshold for the playhead, and one probe per edge of the thing
/// being dragged. Ideas are not what a licence attaches to. Their expression was, and it is gone.
/// See `NOTICE.md`.
///
/// **Why sticky matters, which is the part worth taking.** A plain "snap to the nearest target
/// within N pixels" rule makes a drag near an edge oscillate: one pixel of movement flips
/// between snapped and free, and the clip jitters under the cursor. Holding a snap until the
/// pointer has moved 1.5× the threshold away turns that into one deliberate release.
public enum SnapEngine {
    /// Something a drag can land on.
    public struct Target: Hashable, Sendable {
        /// The kind decides the threshold, not the priority: a nearer clip edge still beats a
        /// far playhead. `playhead` is merely easier to hit.
        public enum Kind: Hashable, Sendable { case playhead, clipEdge }

        public let time: Nanoseconds
        public let kind: Kind

        public init(time: Nanoseconds, kind: Kind) {
            self.time = time
            self.kind = kind
        }
    }

    public struct Result: Hashable, Sendable {
        /// The target's time — where the drag should land.
        public let time: Nanoseconds
        /// Which probe snapped, as an offset from the dragged position. Zero for a plain
        /// playhead drag; a clip's duration when its END is what found the target.
        public let probeOffset: Nanoseconds
    }

    /// Carried across the events of one drag. A caller keeps one per gesture and throws it
    /// away at the end; snapping is stateful precisely because stickiness is.
    public struct State: Hashable, Sendable {
        public var snappedTo: Nanoseconds?
        public var probeOffset: Nanoseconds = Nanoseconds(0)

        public init() {}
    }

    /// How far past the threshold a drag must travel before an existing snap lets go.
    ///
    /// **Half again.** Below about 1.2 the release is still twitchy at the boundary; past about
    /// 2 the snap feels stuck and a person fights it to get a clip near an edge but not on it.
    /// 1.5 sits in the middle of that — a number, not an
    /// expression, and it is here because it is right rather than because it was theirs.
    public static let stickyMultiplier: Double = 1.5

    /// The playhead's threshold relative to a clip edge's.
    ///
    /// **Reach, not priority.** A nearer clip edge still wins; the playhead is merely easier to
    /// hit, because it is the one target a person aims at deliberately rather than one that
    /// happens to be under the cursor.
    public static let playheadMultiplier: Double = 1.5

    /// The target `position` should snap to, or `nil` to leave it where it is.
    ///
    /// `threshold` is in nanoseconds — the caller converts from whatever pixel distance its
    /// zoom level makes reasonable, so this function has no opinion about screens.
    ///
    /// `probeOffsets` are the points on the dragged thing that look for targets. `[0]` for a
    /// playhead; `[0, duration]` for a clip, so either edge can find one.
    public static func snap(position: Nanoseconds,
                            probeOffsets: [Nanoseconds] = [Nanoseconds(0)],
                            targets: [Target],
                            state: inout State,
                            threshold: Nanoseconds) -> Result? {
        guard threshold.rawValue > 0 else { return nil }

        if let held = heldSnap(position: position, targets: targets, state: state,
                               threshold: threshold) {
            return held
        }
        // The hold has broken, or there was none. Either way nothing is snapped now.
        state.snappedTo = nil
        state.probeOffset = Nanoseconds(0)

        guard let found = nearestReachable(position: position, probeOffsets: probeOffsets,
                                           targets: targets, threshold: threshold)
        else { return nil }
        state.snappedTo = found.time
        state.probeOffset = found.probeOffset
        return found
    }

    /// The snap already in force, if the drag has not yet travelled far enough to break it.
    ///
    /// **Stickiness is why this is stateful.** A plain "nearest target within N" rule oscillates
    /// at the boundary — one pixel of movement flips between snapped and free and the clip
    /// jitters under the cursor. Holding until the drag is `stickyMultiplier` past the threshold
    /// turns that into one deliberate release.
    ///
    /// The target must still exist: a clip deleted mid-drag would otherwise hold a snap to an
    /// edge that is no longer on the timeline.
    private static func heldSnap(position: Nanoseconds, targets: [Target], state: State,
                                 threshold: Nanoseconds) -> Result? {
        guard let snapped = state.snappedTo,
              targets.contains(where: { $0.time == snapped }) else { return nil }
        let probe = position.rawValue + state.probeOffset.rawValue
        let hold = Int64(Double(threshold.rawValue) * stickyMultiplier)
        guard abs(probe - snapped.rawValue) <= hold else { return nil }
        return Result(time: snapped, probeOffset: state.probeOffset)
    }

    /// The closest target any probe can reach, or `nil` when none is within reach of any.
    ///
    /// **Every probe against every target, and the smallest distance wins.** A dragged clip
    /// looks for a target with both its edges, so the pair — which edge found which target — is
    /// the answer rather than the target alone; the caller needs the offset to know where to put
    /// the clip.
    private static func nearestReachable(position: Nanoseconds, probeOffsets: [Nanoseconds],
                                         targets: [Target],
                                         threshold: Nanoseconds) -> Result? {
        var nearest: Result?
        var shortest = Int64.max
        for offset in probeOffsets {
            let probe = position.rawValue + offset.rawValue
            for target in targets {
                let distance = abs(probe - target.time.rawValue)
                guard distance <= reach(of: target.kind, threshold: threshold),
                      distance < shortest else { continue }
                shortest = distance
                nearest = Result(time: target.time, probeOffset: offset)
            }
        }
        return nearest
    }

    /// How far a target of this kind can be hit from.
    private static func reach(of kind: Target.Kind, threshold: Nanoseconds) -> Int64 {
        switch kind {
        case .playhead: Int64(Double(threshold.rawValue) * playheadMultiplier)
        case .clipEdge: threshold.rawValue
        }
    }

    /// Every clip boundary in `timeline`, in SOURCE time, plus the playhead when it is not the
    /// thing being dragged.
    ///
    /// Source time and not output time: the timeline a person drags on is drawn from the
    /// recording, so the edges they see are source positions. A caller dragging in output
    /// space converts first — the two are equal only until the first cut.
    public static func targets(in timeline: EditTimeline,
                               playhead: Nanoseconds? = nil) -> [Target] {
        var targets: [Target] = []
        if let playhead { targets.append(Target(time: playhead, kind: .playhead)) }
        for clip in timeline.clips {
            targets.append(Target(time: clip.sourceStart, kind: .clipEdge))
            targets.append(Target(time: clip.sourceEnd, kind: .clipEdge))
        }
        return targets
    }
}
