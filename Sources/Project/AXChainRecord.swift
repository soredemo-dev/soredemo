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

extension AXElementRecord {
    private enum CodingKeys: String, CodingKey {
        case role, title, frame, readInterval
    }

    /// Untrusted input, validated — the same stance `HostRange.init(from:)`
    /// and `DisplayGeometry.init(from:)` take, and here for a sharper reason
    /// than either.
    ///
    /// **`NormalizedPoint` and `NormalizedSize` `precondition` on finiteness
    /// in their memberwise initialisers and their synthesised `Decodable`
    /// conformances bypass it**, assigning the stored properties directly. So
    /// a `NaN` in a frame's origin cannot be constructed in memory and can be
    /// read off disk — and it does not look like corruption when it arrives:
    /// every comparison against `NaN` is `false`, so
    /// `AXChainRecord.clickContainment` would return `.doesNotContainTheClick`
    /// for it. That is the coordinate-fault verdict, reported confidently, for
    /// a file that is merely damaged, **in the one type whose job is telling
    /// faults apart**.
    ///
    /// Throwing rather than trapping, because this is document content: a
    /// `.soredemo` package's bytes are attacker-influenced by
    /// `agentic-threat-model`'s assumption, and killing the process on a
    /// malformed one is a worse answer than refusing the record.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let role = try container.decodeIfPresent(String.self, forKey: .role)
        let title = try container.decodeIfPresent(String.self, forKey: .title)
        let frame = try container.decodeIfPresent(NormalizedFrame.self, forKey: .frame)
        let readInterval = try container.decode(HostRange.self, forKey: .readInterval)
        if let frame {
            let fields = [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height]
            guard fields.allSatisfy({ $0.isFinite }) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "AXElementRecord.frame has a non-finite field: \(fields)"))
            }
            guard frame.size.width >= 0, frame.size.height >= 0 else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: """
                        AXElementRecord.frame has a negative dimension: \
                        \(frame.size.width)×\(frame.size.height)
                        """))
            }
        }
        self.init(role: role, title: title, frame: frame, readInterval: readInterval)
    }

    /// Matches the synthesised shape exactly, so this hand-written
    /// conformance changes validation and not the wire form. `encodeIfPresent`
    /// on the three optionals is what keeps `nil` as an **absent key** rather
    /// than `null` — the distinction `AXChainRecord.children` depends on one
    /// level up.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(role, forKey: .role)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(frame, forKey: .frame)
        try container.encode(readInterval, forKey: .readInterval)
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

    private enum CodingKeys: String, CodingKey {
        case kind, instant, clickPosition, clickRevision, hitTestGlobalX, hitTestGlobalY
        case hitTestInterval, hit, ancestors, children, truncation, axCalls
        case depthCap, walkBudgetNanos
    }

    /// Untrusted input, validated. See `AXElementRecord.init(from:)` for the
    /// full argument; the short version is that a `NaN` in `clickPosition`
    /// decodes cleanly through `NormalizedPoint`'s synthesised conformance and
    /// then makes `clickContainment` answer `.doesNotContainTheClick` — a
    /// confident coordinate-fault verdict produced by a damaged file.
    ///
    /// `hitTestGlobalX`/`Y` are checked for the same reason one level out:
    /// they are the record's statement of *where the question was asked*, and
    /// a non-finite one would make every after-the-fact comparison against the
    /// click's own position meaningless while looking like data.
    ///
    /// The three counts are checked for non-negativity because they are
    /// arithmetic a reader does subtraction and division on — `axCalls` per
    /// click, `ancestors.count` against `depthCap` — and a negative one is not
    /// a value this producer can emit.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try container.decode(String.self, forKey: .kind)
        self.instant = try container.decode(HostInstant.self, forKey: .instant)
        self.clickPosition = try container.decode(NormalizedPoint.self, forKey: .clickPosition)
        self.clickRevision = try container.decode(GeometryRevision.self, forKey: .clickRevision)
        self.hitTestGlobalX = try container.decode(Double.self, forKey: .hitTestGlobalX)
        self.hitTestGlobalY = try container.decode(Double.self, forKey: .hitTestGlobalY)
        self.hitTestInterval = try container.decode(HostRange.self, forKey: .hitTestInterval)
        self.hit = try container.decodeIfPresent(AXElementRecord.self, forKey: .hit)
        self.ancestors = try container.decode([AXElementRecord].self, forKey: .ancestors)
        self.children = try container.decodeIfPresent([AXElementRecord].self, forKey: .children)
        self.truncation = try container.decode(ChainTruncation.self, forKey: .truncation)
        self.axCalls = try container.decode(Int.self, forKey: .axCalls)
        self.depthCap = try container.decode(Int.self, forKey: .depthCap)
        self.walkBudgetNanos = try container.decode(Int64.self, forKey: .walkBudgetNanos)

        let coordinates = [clickPosition.x, clickPosition.y, hitTestGlobalX, hitTestGlobalY]
        guard coordinates.allSatisfy({ $0.isFinite }) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: """
                    AXChainRecord has a non-finite coordinate: clickPosition \
                    (\(clickPosition.x), \(clickPosition.y)), hit-test point \
                    (\(hitTestGlobalX), \(hitTestGlobalY)). Every comparison against NaN is false, \
                    so this record would report .doesNotContainTheClick — a coordinate fault — for \
                    what is a damaged file.
                    """))
        }
        guard axCalls >= 0, depthCap >= 0, walkBudgetNanos >= 0 else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: """
                    AXChainRecord has a negative count: axCalls \(axCalls), depthCap \(depthCap), \
                    walkBudgetNanos \(walkBudgetNanos)
                    """))
        }
    }

    /// Matches the synthesised shape exactly — validation changes, the wire
    /// form does not. `encodeIfPresent` on `hit` and `children` is what keeps
    /// "no children list was read" an absent key rather than `null`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(instant, forKey: .instant)
        try container.encode(clickPosition, forKey: .clickPosition)
        try container.encode(clickRevision, forKey: .clickRevision)
        try container.encode(hitTestGlobalX, forKey: .hitTestGlobalX)
        try container.encode(hitTestGlobalY, forKey: .hitTestGlobalY)
        try container.encode(hitTestInterval, forKey: .hitTestInterval)
        try container.encodeIfPresent(hit, forKey: .hit)
        try container.encode(ancestors, forKey: .ancestors)
        try container.encodeIfPresent(children, forKey: .children)
        try container.encode(truncation, forKey: .truncation)
        try container.encode(axCalls, forKey: .axCalls)
        try container.encode(depthCap, forKey: .depthCap)
        try container.encode(walkBudgetNanos, forKey: .walkBudgetNanos)
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

    /// How long the click waited **before anyone asked AX anything**: from the
    /// instant the window server stamped the button event to the instant the
    /// hit-test began.
    ///
    /// **This is the price of not doing AX work on the tap callback thread,
    /// and it is recorded rather than absorbed.** The observation is
    /// dispatched to another queue, which makes it later than the click by
    /// whatever this says.
    ///
    /// The reason for that dispatch is the asymmetry of what is lost when a
    /// target application hangs — AX on the callback thread risks the whole
    /// pointer track, AX behind a bounded queue risks the AX chains of the
    /// affected clicks, counted — and **not** a per-callback time budget. An
    /// earlier version of this comment cited a 10–50 ms budget that was an
    /// artefact of stalling every `mouseMoved`; 125 ms of stall on clicks
    /// alone was later measured to leave the tap enabled across 1928
    /// callbacks. `Soredemo/Capture/AXObserver.swift`'s header carries the
    /// argument and the correction.
    ///
    /// A stale hit-test is recorded staleness; a dead pointer track is
    /// silence. This field is what keeps the trade visible instead of turning
    /// it into an unexplained drift between the verb and the object.
    ///
    /// Together with `hitTestInterval.duration` it decomposes
    /// `clickToHitTestAnswerNanos` into the part this app chose (the queue)
    /// and the part the target application imposed (the IPC). A gate that
    /// wants to reject stale observations needs them apart: raising a budget
    /// fixes one and does nothing for the other.
    public var clickToHitTestStartNanos: Int64? {
        guard hitTestInterval.epoch == instant.epoch else { return nil }
        return hitTestInterval.start.rawValue - instant.hostTime.rawValue
    }

    /// How long the click waited for the hit-test to answer: from the instant
    /// the window server stamped the button event to the instant
    /// `AXUIElementCopyElementAtPosition` returned. The sum of
    /// `clickToHitTestStartNanos` (the queue) and `hitTestInterval.duration`
    /// (the IPC).
    ///
    /// `nil` across a boot-epoch mismatch rather than a wrong number — the two
    /// instants are then not on one clock, and subtracting them would produce
    /// a plausible-looking duration that means nothing.
    public var clickToHitTestAnswerNanos: Int64? {
        guard hitTestInterval.epoch == instant.epoch else { return nil }
        return hitTestInterval.end.rawValue - instant.hostTime.rawValue
    }
}
