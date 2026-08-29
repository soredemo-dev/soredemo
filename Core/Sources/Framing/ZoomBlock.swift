import Foundation
import Geometry
import Timeline

/// One click that passed the gates: the instant it happened and what to frame.
public struct FramedClick: Hashable, Sendable {
    public let instant: HostInstant
    public let target: FramingTarget

    public init(instant: HostInstant, target: FramingTarget) {
        self.instant = instant
        self.target = target
    }
}

/// A span the camera is zoomed in for, and what it frames while it is.
public struct ZoomBlock: Hashable, Sendable {
    /// **The block's identity: the instant of the first click that produced it.**
    ///
    /// A block is derived, so it has no id of its own to store — re-deriving the plan builds
    /// new values. What survives is the click, which is an observation and does not move. A
    /// person who drags a zoom on the timeline is adjusting THAT click's zoom, and the
    /// adjustment has to still mean the same thing after the plan is rebuilt.
    ///
    /// Not the block's `start`: pre-roll moves it, so two derivations with different pre-roll
    /// would produce different identities for the same zoom.
    public let origin: HostInstant
    public let start: HostInstant
    public let end: HostInstant
    /// The union of every merged click's target — see `blocks(for:)`.
    public let target: FramingTarget
    /// `FramingDepth.zoom(for:)` of `target`, carried so a consumer does not recompute it
    /// and risk disagreeing.
    public let zoom: Double

    public init(origin: HostInstant, start: HostInstant, end: HostInstant,
                target: FramingTarget, zoom: Double) {
        self.origin = origin
        self.start = start
        self.end = end
        self.target = target
        self.zoom = zoom
    }
}

extension ZoomBlock {
    /// How early the camera arrives. A zoom that begins AT the click shows the aftermath
    /// rather than the action. **Uncalibrated**, like every other constant in this module.
    public static let preRoll = Nanoseconds(400_000_000)

    /// How long it stays after. Long enough to read the result of the click.
    /// **Uncalibrated.**
    public static let hold = Nanoseconds(1_000_000_000)

    /// **How close two blocks must be for the camera to PAN between them instead of zooming
    /// out and back in.**
    ///
    /// Merging is overlap-only, for the reason below, so two clicks 2.5 s apart leave a 1.1 s
    /// gap — long enough at ω = 10 for the camera to make most of its way back to zoom 1 and
    /// then go out again. That reads as a mistake even though every block is individually
    /// correct: the viewer sees the frame lurch out and back for no reason.
    ///
    /// The same thing is sometimes called a chained
    /// zoom and uses 1350 ms (`CHAINED_ZOOM_PAN_GAP_MS`); the value is theirs and is carried
    /// over rather than re-guessed. **It is not a merge**: the blocks stay separate, keep
    /// their own targets and their own depths, and only the camera's behaviour in the gap
    /// changes — which is why raising it does not chain the whole recording into one block
    /// the way a merge tolerance above 0.1 s does.
    public static let chainedPanGap = Nanoseconds(1_350_000_000)

    /// **Blocks merge only when they genuinely OVERLAP — no tolerance, and that is the
    /// decision this type exists to get right.**
    ///
    /// `zoom-blocks`' ROADMAP row warns that demo clicks are 1–3 s apart and an over-eager
    /// merge collapses a whole demo into one zoom. Measured on a realistic six-click
    /// sequence (paced, a rapid trio, a pause) before this was written: overlap-only and a
    /// 0.1 s tolerance both give four blocks; 0.25 s gives three; **0.5 s gives two**,
    /// because each merged block's end reaches the next block's start and the merge chains
    /// down the whole recording. A block is `preRoll + hold` = 1.4 s long, so consecutive
    /// clicks 1.5 s apart leave a 0.1 s gap — any tolerance above that starts the chain.
    ///
    /// Overlap-only still merges what should merge: three clicks inside 1.2 s become one
    /// block rather than a camera twitching three times
    /// (`clicksInsideOneAnothersBlocksBecomeOneZoom`).
    ///
    /// **Deterministic**: clicks are grouped by boot epoch, sorted within it, and swept
    /// once. The row asks for a deterministic merge, and a sweep that depended on arrival
    /// order would produce different footage from one recording between runs.
    ///
    /// **Epochs never share a block.** Two boot sessions produce overlapping host times, so
    /// a block spanning both would be a duration computed across two clocks — the
    /// `1a98402` family. Grouped, not interleaved.
    /// `coverage` is the share of the OUTPUT frame the recording occupies — 1 in the
    /// recording's own shape — and it reaches `FramingDepth.zoom(for:coverage:)` unchanged.
    /// Carried here rather than applied by a consumer because `ZoomBlock.zoom` exists so
    /// that a consumer does NOT recompute the depth and risk disagreeing; a per-variant
    /// correction applied downstream would reintroduce exactly that second answer.
    public static func blocks(for clicks: [FramedClick], coverage: Double,
                              intensity: Double) -> [ZoomBlock] {
        let byEpoch = Dictionary(grouping: clicks) { $0.instant.epoch }
        // Epoch groups are emitted in a stable order — `BootEpoch` is a UUID and carries no
        // ordering of its own, so sorting by its string form is what makes the RESULT
        // deterministic rather than merely each group's contents.
        return byEpoch.keys.sorted { $0.id.uuidString < $1.id.uuidString }.flatMap { epoch in
            merge(byEpoch[epoch] ?? [], in: epoch, coverage: coverage, intensity: intensity)
        }
    }

    private static func merge(_ clicks: [FramedClick], in epoch: BootEpoch,
                              coverage: Double, intensity: Double) -> [ZoomBlock] {
        let sorted = clicks.sorted { $0.instant.hostTime.rawValue < $1.instant.hostTime.rawValue }
        var groups: [[FramedClick]] = []
        var openEnd: Int64 = .min

        for click in sorted {
            let time = click.instant.hostTime.rawValue
            // A negative start is not an instant this project can hold; the recording began
            // at zero, so a click inside the pre-roll window clamps rather than going under.
            let start = max(0, time - preRoll.rawValue)
            let end = time + hold.rawValue
            if !groups.isEmpty, start < openEnd {
                groups[groups.count - 1].append(click)
                openEnd = max(openEnd, end)
            } else {
                groups.append([click])
                openEnd = end
            }
        }

        return groups.map { group in
            let first = group.first!.instant.hostTime.rawValue
            let last = group.last!.instant.hostTime.rawValue
            let union = unionTarget(of: group)
            return ZoomBlock(
                origin: group.first!.instant,
                start: HostInstant(epoch: epoch,
                                   hostTime: Nanoseconds(max(0, first - preRoll.rawValue))),
                end: HostInstant(epoch: epoch, hostTime: Nanoseconds(last + hold.rawValue)),
                target: union,
                zoom: FramingDepth.zoom(for: union, coverage: coverage,
                                        intensity: intensity))
        }
    }

    /// The smallest frame covering every merged click's target. **The union, not a winner**:
    /// a camera framing one of two merged clicks would leave the other action off-screen
    /// while it happened. The union is wider than either, so its depth comes out shallower —
    /// the zoom pulls back to cover both, which is the honest consequence of merging.
    ///
    /// The role is the first click's when they agree and `nil` when they do not: a merged
    /// block did not frame one control, and naming one of them would read as though it had.
    private static func unionTarget(of group: [FramedClick]) -> FramingTarget {
        guard let first = group.first else {
            preconditionFailure("a merged group is never empty — it is built from at least one click")
        }
        guard group.count > 1 else { return first.target }

        let frames = group.map(\.target.frame)
        let minX = frames.map(\.minX).min()!
        let minY = frames.map(\.minY).min()!
        let maxX = frames.map(\.maxX).max()!
        let maxY = frames.map(\.maxY).max()!
        let roles = Set(group.map(\.target.role))
        return FramingTarget(
            frame: NormalizedFrame(origin: NormalizedPoint(x: minX, y: minY),
                                   size: NormalizedSize(width: maxX - minX, height: maxY - minY),
                                   revision: first.target.frame.revision),
            role: roles.count == 1 ? first.target.role : nil)
    }
}
