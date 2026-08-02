import Foundation
import Geometry
import Timeline

/// One element in an AX observation. Each carries its **own** interval, not one
/// for the chain: the levels are read at different moments, and at p95 the UI
/// has three frames to move between the top and bottom of what is stored as a
/// single observation (F2-2). The interval's width is the uncertainty (D2-2a).
///
/// **Every field except `readInterval` is optional, and each `nil` means "the
/// AX call did not answer", never "the element has none".** An element with no
/// title and an element whose `kAXTitleAttribute` read failed are different
/// facts; both are recorded as `nil` here, and the *count* of the second is
/// carried by `AXObserver.Diagnostics` rather than being inferred from a log
/// full of nulls. `readInterval` is not optional because it is this process's
/// own measurement — the one thing about an element that cannot fail to be
/// known.
///
/// `frame` is a `NormalizedFrame`, so it carries the `GeometryRevision` of the
/// display the element's own origin routed to. That revision is what makes
/// `AXChainRecord.clickContainment` computable — and what makes it refuse to
/// compute when the element and the click were normalised against different
/// displays, rather than comparing two numbers from two coordinate spaces.
public struct AXElementRecord: Hashable, Codable, Sendable {
    public let role: String?
    public let title: String?
    public let frame: NormalizedFrame?
    /// From immediately before the first attribute read of this element to
    /// immediately after the last. Four AX calls wide in the live observer —
    /// role, position, size, title — because `kAXFrameAttribute` is not
    /// exposed to Swift and a frame therefore costs **two** IPC round trips,
    /// not one.
    public let readInterval: HostRange

    public init(role: String?, title: String?, frame: NormalizedFrame?, readInterval: HostRange) {
        self.role = role
        self.title = title
        self.frame = frame
        self.readInterval = readInterval
    }
}

/// Why the walk stopped. "There were no more ancestors" and "I stopped asking"
/// are otherwise the same bytes on disk (D2-2).
///
/// **A statement about the whole observation, not only the upward walk.** The
/// ancestor walk is what `.reachedRoot` and `.depthCapReached` are about, but
/// `.budgetExceeded` is also set when the wall-clock budget ran out while the
/// hit element's children were being read — see `AXChainRecord.children`. A
/// reader who needs to know whether the *upward* walk itself completed has
/// that from the chain's own top: F2-3 measured all 107 complete walks topping
/// out at `AXApplication`, against `AXGroup`/`AXWebArea`/`AXWindow` for the 11
/// truncated ones.
public enum ChainTruncation: String, Codable, Sendable {
    case reachedRoot, depthCapReached, budgetExceeded, hitTestReturnedNothing
}

/// Whether the click this observation is the object half of actually falls
/// inside the element the hit-test returned.
///
/// **Computed, never stored** (D2-1: capture records, it does not judge). The
/// inputs are all on disk — `clickPosition`, `clickRevision`, and the hit
/// element's own `frame` — so a reader recomputes this from the record rather
/// than trusting a verdict a producer wrote at capture time. Storing it would
/// make `producerVersion` meaningless for exactly this decision, which is the
/// argument D2-1 makes for element choice, one field over.
///
/// The five cases are five different findings, and collapsing any two of them
/// into `false` would hide the one that matters:
///
/// * `.doesNotContainTheClick` is the **coordinate** fault. Nothing about AX
///   staleness moves an element out from under the pointer *in the recorded
///   frame's own coordinate space* — a stale frame is where the element was a
///   frame or two ago, which still overlaps the click in almost every case
///   that matters, whereas a conversion that skipped a step is off by the
///   display's `scale` or by its global origin, every time, for every click.
/// * `.notComparable` is neither fault: the element's origin routed to a
///   different display than the click did. A window straddling two displays
///   does that legitimately.
/// * `.noFrameRecorded` and `.noHitElement` are absences, and they are
///   different absences — one means AX answered with an element it would not
///   describe, the other that it answered with nothing at all.
public enum ClickContainment: String, Hashable, Sendable {
    case containsTheClick
    case doesNotContainTheClick
    case notComparable
    case noFrameRecorded
    case noHitElement
}

/// The AX observation for one click: the whole chain, with **no element
/// chosen** (D2-1).
///
/// The preference `ROADMAP.md` states for well-bounded descendants is a gate,
/// and `ARCHITECTURE.md` D4 requires a gate's thresholds to be fitted to
/// measured distributions that do not exist yet. Choosing here would discard
/// the alternatives, and a `Derived` value whose evidence structurally cannot
/// support any other answer is not evidence.
///
/// **The four fields that let a wrong element be attributed to the right
/// layer.** If the coordinates were wrong, the symptom is "the hit-test
/// returned the wrong element" — and that symptom has a ready, credible
/// alternative explanation in F2-2's numbers (AX is stale during animation,
/// 12% of clicks by more than one 60 fps frame). A coordinate bug hides behind
/// that prior perfectly. So every record carries, without re-running anything:
///
/// | field | question it answers |
/// | --- | --- |
/// | `hitTestGlobalX`/`Y` | what point was the hit-test actually performed at |
/// | `instant` | when was the button event stamped |
/// | `hitTestInterval` | when did the hit-test start, and when did it answer |
/// | `hit?.frame` | where did the element it returned say it was |
///
/// `clickContainment` is the arithmetic over those: a click outside the
/// returned element's own frame is a **coordinate** fault, and no amount of AX
/// staleness explains it. `hitTestInterval.end - instant.hostTime` is the
/// **timing** exposure, and `hit?.readInterval` says how much later the frame
/// itself was read. The two questions are separable after the fact, from the
/// record alone, which is the whole reason both are stored.
public struct AXChainRecord: Hashable, Codable, Sendable {
    public let kind: String            // "axChain"
    /// The instant the **button event** was stamped by the window server —
    /// `ButtonEvent.instant`, copied unchanged. This is the join key: the verb
    /// half of "click the Save button" is the `ButtonEvent` at this instant,
    /// the object half is this record.
    public let instant: HostInstant
    /// The click's position as `input-observation` recorded it, and the
    /// revision it was normalised against. Stored rather than re-derived so a
    /// reader can check this record against the `ButtonEvent` it claims to
    /// pair with, byte for byte.
    public let clickPosition: NormalizedPoint
    public let clickRevision: GeometryRevision
    /// The **global, top-left, points** coordinate handed to
    /// `AXUIElementCopyElementAtPosition` — the input the answer below is an
    /// answer to.
    ///
    /// **Bare scalars, and this is the same call the bridge already made.**
    /// There is no package type for an un-normalised point: `NormalizedPoint`
    /// is 0…1 bottom-left and would be a lie at this end of the pipeline, and
    /// `PointRect` is a rectangle (`DisplayArrangement`'s documentation
    /// rejects a zero-size rect as a spelling for a point). See
    /// `CGGeometryBridge.location(from:)`, which returns the same shape for
    /// the same reason.
    ///
    /// **Stored even though it is derivable from `clickPosition` and
    /// `clickRevision`.** Derivable *given the arrangement at the time*, which
    /// is extrinsic, is not digested, and is gone by the time anyone reads
    /// this file. Without it, "the hit-test was performed at the wrong point"
    /// and "the hit-test was performed at the right point and answered wrongly"
    /// are the same record.
    public let hitTestGlobalX: Double
    public let hitTestGlobalY: Double
    /// Before and after the single `AXUIElementCopyElementAtPosition` call.
    /// The API returns no timestamp of its own, so its width is the
    /// uncertainty and never a single instant (D2-2a). F2-2: p50 1.05 ms,
    /// p90 21.25 ms, max 125.47 ms over 118 clicks.
    public let hitTestInterval: HostRange
    /// `nil` exactly when `truncation == .hitTestReturnedNothing`.
    public let hit: AXElementRecord?
    /// Innermost first — the hit element's parent, then its parent, and so on
    /// up. Truncation therefore drops the **outermost** ancestors, which are
    /// the ones least likely to be the camera's target (F2-3).
    public let ancestors: [AXElementRecord]
    /// One level down from the hit element (D2-3), or `nil`.
    ///
    /// **`nil` and `[]` are different facts and that is the point of the
    /// optional.** `[]` means the children attribute was read and the element
    /// has none. `nil` means no list was recorded at all — the budget was gone
    /// before the call could be made, or `kAXChildrenAttribute` did not
    /// answer. Without the distinction, "this element is a leaf" and "I never
    /// asked" are byte-identical on disk, which is `JSONLReader`'s
    /// truncated-tail rule and D2-2's truncation rule for the third time.
    ///
    /// One level, not a search. The downward direction is a tree search, an
    /// order of magnitude more expensive and considerably more judgement-laden,
    /// so it must not happen at capture time (D2-1) — but it also cannot happen
    /// later unless this one call was made, because a derivation cannot search
    /// a tree that was never captured.
    public let children: [AXElementRecord]?
    public let truncation: ChainTruncation
    /// Every AX IPC round trip this observation made, including the hit-test
    /// and including the two that a single frame costs. F2-2: p50 41, p90 106,
    /// max 131.
    public let axCalls: Int
    /// The bounds that were in force for this observation.
    ///
    /// Recorded per record, not left to a constant in a source file, because
    /// the budget is a **D4 placeholder awaiting calibration** and will move —
    /// on a slower machine, and once there are recorded demos to fit it to. A
    /// log written under a 35 ms budget and one written under a recalibrated
    /// one are not the same measurement, and nothing else on disk would say so.
    public let depthCap: Int
    public let walkBudgetNanos: Int64

    public init(instant: HostInstant,
                clickPosition: NormalizedPoint,
                clickRevision: GeometryRevision,
                hitTestGlobalX: Double,
                hitTestGlobalY: Double,
                hitTestInterval: HostRange,
                hit: AXElementRecord?,
                ancestors: [AXElementRecord],
                children: [AXElementRecord]?,
                truncation: ChainTruncation,
                axCalls: Int,
                depthCap: Int,
                walkBudgetNanos: Int64) {
        self.kind = "axChain"
        self.instant = instant
        self.clickPosition = clickPosition
        self.clickRevision = clickRevision
        self.hitTestGlobalX = hitTestGlobalX
        self.hitTestGlobalY = hitTestGlobalY
        self.hitTestInterval = hitTestInterval
        self.hit = hit
        self.ancestors = ancestors
        self.children = children
        self.truncation = truncation
        self.axCalls = axCalls
        self.depthCap = depthCap
        self.walkBudgetNanos = walkBudgetNanos
    }

    /// Whether `clickPosition` falls inside the hit element's own recorded
    /// frame — the check that separates a coordinate fault from an AX timing
    /// fault, computed from this record and nothing else.
    ///
    /// **Revisions are compared first, and a mismatch is `.notComparable`
    /// rather than a trap.** `NormalizedFrame.contains` preconditions on
    /// revision equality, which is right for a caller that has already
    /// established the two frames describe one display; here the mismatch is
    /// one of the answers, and killing the process while reading a log file is
    /// not.
    ///
    /// **Inclusive on all four edges, and no epsilon.** Inclusive so that a
    /// click landing exactly on a control's boundary is not reported as a
    /// coordinate fault — this predicate should over-report containment, since
    /// its `false` is the loud direction. No tolerance, because a tolerance is
    /// a threshold and D4 requires thresholds to be fitted to measured
    /// distributions; both sides of this comparison come out of the same
    /// normalisation arithmetic, so there is no accumulated error for an
    /// epsilon to absorb.
    public var clickContainment: ClickContainment {
        guard let hit else { return .noHitElement }
        guard let frame = hit.frame else { return .noFrameRecorded }
        guard frame.revision == clickRevision else { return .notComparable }
        let inside = clickPosition.x >= frame.minX && clickPosition.x <= frame.maxX
            && clickPosition.y >= frame.minY && clickPosition.y <= frame.maxY
        return inside ? .containsTheClick : .doesNotContainTheClick
    }

    /// How long the click waited for the hit-test to answer: from the instant
    /// the window server stamped the button event to the instant
    /// `AXUIElementCopyElementAtPosition` returned.
    ///
    /// `nil` across a boot-epoch mismatch rather than a wrong number — the two
    /// instants are then not on one clock, and subtracting them would produce
    /// a plausible-looking duration that means nothing.
    public var clickToHitTestAnswerNanos: Int64? {
        guard hitTestInterval.epoch == instant.epoch else { return nil }
        return hitTestInterval.end.rawValue - instant.hostTime.rawValue
    }
}
