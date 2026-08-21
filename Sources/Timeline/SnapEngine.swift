import Foundation

/// Snapping a dragged timeline position to the edges near it.
///
/// **Ported from `a native editor`'s `Timeline/SnapEngine.swift` (GPL-3.0).** The algorithm is
/// theirs: sticky snapping with a hold threshold, per-target-kind thresholds so the playhead
/// wins ties, and multiple probes so a dragged clip's start AND end both look for a target.
/// Reimplemented against this project's types — nanoseconds rather than frame indices, and no
/// haptic call, which is an app-tier concern this deterministic module cannot reach. Their
/// multipliers are carried over as measured values rather than re-guessed; see `NOTICE.md`.
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
    /// a native editor's value, kept rather than re-guessed.
    public static let stickyMultiplier: Double = 1.5
    /// The playhead's threshold relative to a clip edge's. Same source, same reasoning: the
    /// playhead is the one target a person aims at deliberately.
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

        // Sticky first: an existing snap holds until the drag has travelled past the wider
        // hold threshold, so a pixel of movement near an edge cannot flip it.
        if let snapped = state.snappedTo {
            let hold = Int64(Double(threshold.rawValue) * stickyMultiplier)
            let probe = position.rawValue + state.probeOffset.rawValue
            if abs(probe - snapped.rawValue) <= hold,
               targets.contains(where: { $0.time == snapped }) {
                return Result(time: snapped, probeOffset: state.probeOffset)
            }
            state.snappedTo = nil
            state.probeOffset = Nanoseconds(0)
        }

        var best: (offset: Nanoseconds, target: Target, distance: Int64)?
        for offset in probeOffsets {
            let probe = position.rawValue + offset.rawValue
            for target in targets {
                let limit: Int64 = switch target.kind {
                case .playhead: Int64(Double(threshold.rawValue) * playheadMultiplier)
                case .clipEdge: threshold.rawValue
                }
                let distance = abs(probe - target.time.rawValue)
                guard distance <= limit, distance < (best?.distance ?? Int64.max) else { continue }
                best = (offset, target, distance)
            }
        }

        guard let best else { return nil }
        state.snappedTo = best.target.time
        state.probeOffset = best.offset
        return Result(time: best.target.time, probeOffset: best.offset)
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
