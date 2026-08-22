import Foundation
import Geometry
import Timeline

/// One element in an AX observation; `readInterval`'s width is the uncertainty.
/// A `nil` field means "the AX call did not answer", never "the element has none".
/// `frame` carries the `GeometryRevision` of the display its origin routed to.
public struct AXElementRecord: Hashable, Codable, Sendable {
    public let role: String?
    public let title: String?
    public let frame: NormalizedFrame?
    /// From immediately before the first attribute read of this element to
    /// immediately after the last.
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

    /// Untrusted input, validated: `NormalizedPoint`/`NormalizedSize` synthesised
    /// `Decodable` conformances bypass their finiteness preconditions, and a `NaN`
    /// frame would make `clickContainment` report `.doesNotContainTheClick`.
    /// Throws rather than traps — this is document content, not programmer error.
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

    /// Matches the synthesised wire shape exactly; only validation is hand-written.
    /// `encodeIfPresent` keeps `nil` an absent key rather than `null`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(role, forKey: .role)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(frame, forKey: .frame)
        try container.encode(readInterval, forKey: .readInterval)
    }
}

/// Why the walk stopped; distinguishes "no more ancestors" from "stopped asking".
/// Covers the whole observation, not only the upward walk: `.budgetExceeded` is
/// also set when the budget ran out while reading the hit element's children.
public enum ChainTruncation: String, Codable, Sendable {
    case reachedRoot, depthCapReached, budgetExceeded, hitTestReturnedNothing
}

/// Whether the click falls inside the element the hit-test returned. Computed
/// from the record, never stored. `.doesNotContainTheClick` is a coordinate
/// fault; `.notComparable` means the element and click routed to different
/// displays; the two absences are distinct and must not collapse into one.
public enum ClickContainment: String, Hashable, Sendable {
    case containsTheClick
    case doesNotContainTheClick
    case notComparable
    case noFrameRecorded
    case noHitElement
}

/// The AX observation for one click: the whole chain, with no element chosen.
/// `hitTestGlobalX`/`Y`, `instant`, `hitTestInterval` and `hit?.frame` are all
/// stored so a coordinate fault and an AX timing fault stay separable from the
/// record alone, without re-running anything.
public struct AXChainRecord: Hashable, Codable, Sendable {
    public let kind: String            // "axChain"
    /// `ButtonEvent.instant` copied unchanged — the join key pairing this record
    /// with its button event.
    public let instant: HostInstant
    /// The click's recorded position and the revision it was normalised against,
    /// stored so a reader can check this record against its `ButtonEvent`.
    public let clickPosition: NormalizedPoint
    public let clickRevision: GeometryRevision
    /// The global, top-left, points coordinate handed to
    /// `AXUIElementCopyElementAtPosition`. Bare scalars: no package type spells an
    /// un-normalised point. Stored because re-deriving it needs the arrangement at
    /// capture time, which is extrinsic and gone by the time this file is read.
    public let hitTestGlobalX: Double
    public let hitTestGlobalY: Double
    /// Before and after the single `AXUIElementCopyElementAtPosition` call. The API
    /// returns no timestamp, so this is an interval whose width is the uncertainty.
    public let hitTestInterval: HostRange
    /// `nil` exactly when `truncation == .hitTestReturnedNothing`.
    public let hit: AXElementRecord?
    /// Innermost first — parent, then its parent, and so on up. Truncation
    /// therefore drops the outermost ancestors.
    public let ancestors: [AXElementRecord]
    /// One level down from the hit element, never a deeper search. `[]` means the
    /// children attribute was read and the element has none; `nil` means no list
    /// was recorded at all (budget exhausted, or the attribute did not answer).
    public let children: [AXElementRecord]?
    public let truncation: ChainTruncation
    /// Every AX IPC round trip this observation made, including the hit-test.
    public let axCalls: Int
    /// The bounds in force for this observation, recorded per record rather than
    /// left to a source constant: they are uncalibrated and will move, and logs
    /// written under different bounds are not the same measurement.
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

    /// Untrusted input, validated. Throws on a non-finite `clickPosition` or
    /// hit-test coordinate (a `NaN` decodes cleanly and would make
    /// `clickContainment` report a coordinate fault) and on a negative count.
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

    /// Matches the synthesised wire shape exactly. `encodeIfPresent` on `hit` and
    /// `children` keeps "no children list was read" an absent key, not `null`.
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

    /// Whether `clickPosition` falls inside the hit element's recorded frame,
    /// computed from this record alone. Revisions are compared first and a mismatch
    /// answers `.notComparable` rather than tripping `NormalizedFrame.contains`'s
    /// precondition. Inclusive on all four edges, with no epsilon.
    public var clickContainment: ClickContainment {
        guard let hit else { return .noHitElement }
        guard let frame = hit.frame else { return .noFrameRecorded }
        guard frame.revision == clickRevision else { return .notComparable }
        let inside = clickPosition.x >= frame.minX && clickPosition.x <= frame.maxX
            && clickPosition.y >= frame.minY && clickPosition.y <= frame.maxY
        return inside ? .containsTheClick : .doesNotContainTheClick
    }

    /// From the button event's instant to the start of the hit-test: the queue
    /// delay from dispatching AX work off the tap callback thread. With
    /// `hitTestInterval.duration` it decomposes `clickToHitTestAnswerNanos` into
    /// the queue's share and the target application's IPC. `nil` across epochs.
    public var clickToHitTestStartNanos: Int64? {
        guard hitTestInterval.epoch == instant.epoch else { return nil }
        return hitTestInterval.start.rawValue - instant.hostTime.rawValue
    }

    /// From the button event's instant to the hit-test's answer — the sum of
    /// `clickToHitTestStartNanos` and `hitTestInterval.duration`. `nil` across a
    /// boot-epoch mismatch, where the two instants are not on one clock.
    public var clickToHitTestAnswerNanos: Int64? {
        guard hitTestInterval.epoch == instant.epoch else { return nil }
        return hitTestInterval.end.rawValue - instant.hostTime.rawValue
    }
}

extension AXElementRecord {
    /// Not an `ObservationRecord` — never a line of its own — but it carries an
    /// instant, so a chain's epochs include one per element.
    public var epochs: [BootEpoch] { [readInterval.epoch] }
}

extension AXChainRecord: ObservationRecord {
    /// The click's epoch, the hit-test's, and one per element read interval — all
    /// of them, so the writer refuses a chain whose element reads landed in
    /// another boot session instead of letting derived fields go silently `nil`.
    public var epochs: [BootEpoch] {
        var all = [instant.epoch, hitTestInterval.epoch]
        if let hit { all.append(contentsOf: hit.epochs) }
        for ancestor in ancestors { all.append(contentsOf: ancestor.epochs) }
        for child in children ?? [] { all.append(contentsOf: child.epochs) }
        return all
    }
}
