import Foundation
import Geometry
import Testing
import Timeline
@testable import Project

private let ep = BootEpoch(id: UUID(uuidString: "1A0C9D5C-2F31-4E77-9A5B-2C3E7F0B1D44")!)
private let otherEp = BootEpoch(id: UUID(uuidString: "9F71B0A2-7C43-4E10-8D2F-55A1C6E90B33")!)
private let rev = GeometryRevision(id: 0x0123_4567_89ab_cdef)
private let otherRev = GeometryRevision(id: 0xfedc_ba98_7654_3210)

private func at(_ ns: Int64) -> HostInstant { HostInstant(epoch: ep, hostTime: Nanoseconds(ns)) }
private func span(_ start: Int64, _ duration: Int64, epoch: BootEpoch = ep) -> HostRange {
    HostRange(epoch: epoch, start: Nanoseconds(start), duration: Nanoseconds(duration))
}

/// A frame occupying the middle of a normalised display: x 0.4…0.6, y 0.4…0.6.
private func middleFrame(revision: GeometryRevision = rev) -> NormalizedFrame {
    NormalizedFrame(origin: NormalizedPoint(x: 0.4, y: 0.4),
                    size: NormalizedSize(width: 0.2, height: 0.2),
                    revision: revision)
}

private func element(role: String? = "AXButton",
                     title: String? = "Save",
                     frame: NormalizedFrame? = middleFrame(),
                     readInterval: HostRange = span(1_000, 400_000)) -> AXElementRecord {
    AXElementRecord(role: role, title: title, frame: frame, readInterval: readInterval)
}

private func record(clickAt click: NormalizedPoint = NormalizedPoint(x: 0.5, y: 0.5),
                    clickRevision: GeometryRevision = rev,
                    instant: HostInstant = at(1_000_000),
                    hitTestInterval: HostRange = span(1_000_100, 1_050_000),
                    hit: AXElementRecord? = element(),
                    ancestors: [AXElementRecord] = [],
                    children: [AXElementRecord]? = nil,
                    truncation: ChainTruncation = .reachedRoot,
                    axCalls: Int = 5) -> AXChainRecord {
    AXChainRecord(instant: instant,
                  clickPosition: click,
                  clickRevision: clickRevision,
                  hitTestGlobalX: 1200.5,
                  hitTestGlobalY: 400.25,
                  hitTestInterval: hitTestInterval,
                  hit: hit,
                  ancestors: ancestors,
                  children: children,
                  truncation: truncation,
                  axCalls: axCalls,
                  depthCap: 30,
                  walkBudgetNanos: 35_000_000)
}

private func roundTrip(_ value: AXChainRecord) throws -> AXChainRecord {
    try ObservationLog.decode(ObservationLog.encode(value))
}

// MARK: - the three distinctions the type exists for

@Test func everyTruncationReasonSurvivesARoundTrip() throws {
    for reason in [ChainTruncation.reachedRoot, .depthCapReached, .budgetExceeded, .hitTestReturnedNothing] {
        let decoded = try roundTrip(record(truncation: reason))
        #expect(decoded.truncation == reason)
    }
}

/// "No more ancestors" and "I stopped asking" must not be the same bytes.
/// Both fixtures are empty on purpose, so `truncation` alone carries it.
@Test func anEmptyChainThatHitTheDepthCapIsNotAnEmptyChainThatReachedTheRoot() throws {
    let complete = record(ancestors: [], truncation: .reachedRoot)
    let truncated = record(ancestors: [], truncation: .depthCapReached)

    #expect(complete != truncated)
    #expect(try ObservationLog.encode(complete) != ObservationLog.encode(truncated))

    let decodedComplete = try roundTrip(complete)
    let decodedTruncated = try roundTrip(truncated)
    #expect(decodedComplete.truncation == .reachedRoot)
    #expect(decodedTruncated.truncation == .depthCapReached)
    #expect(decodedComplete.ancestors.isEmpty && decodedTruncated.ancestors.isEmpty,
            "both are empty — the difference is carried by truncation alone, which is the point")
}

/// `[]` is a measurement; `nil` is the absence of one.
@Test func noChildrenAndNoChildrenListAreDifferentRecords() throws {
    let leaf = record(children: [])
    let notAsked = record(children: nil)

    #expect(leaf != notAsked)

    let leafJSON = try String(decoding: ObservationLog.encode(leaf), as: UTF8.self)
    let notAskedJSON = try String(decoding: ObservationLog.encode(notAsked), as: UTF8.self)
    #expect(leafJSON.contains("\"children\":[]"),
            "an element read and found to have no children encodes the empty list: \(leafJSON)")
    #expect(!notAskedJSON.contains("\"children\""),
            "a children list that was never read encodes no key at all: \(notAskedJSON)")

    #expect(try roundTrip(leaf).children == [])
    #expect(try roundTrip(notAsked).children == nil)
}

@Test func childrenSurviveARoundTripWithTheirOwnIntervals() throws {
    let kids = [element(role: "AXStaticText", title: nil, readInterval: span(2_000, 300)),
                element(role: "AXImage", title: nil, frame: nil, readInterval: span(2_400, 700))]
    let decoded = try roundTrip(record(children: kids))
    #expect(decoded.children == kids)
    #expect(decoded.children?[1].frame == nil, "an element whose frame did not answer stays nil")
}

// MARK: - a wrong element must not be attributable to the wrong layer

/// The positive direction: a click inside the element the hit-test returned.
@Test func aClickInsideTheReturnedElementsFrameIsRecordedAsContained() {
    let inside = record(clickAt: NormalizedPoint(x: 0.5, y: 0.5))
    #expect(inside.clickContainment == .containsTheClick)
}

/// The negative direction, in all four axes: a click outside the returned
/// element's frame is a coordinate fault, not AX staleness.
@Test func aClickOutsideTheReturnedElementsFrameIsACoordinateFault() {
    let outside: [(String, NormalizedPoint)] = [
        ("left of it",   NormalizedPoint(x: 0.30, y: 0.50)),
        ("right of it",  NormalizedPoint(x: 0.75, y: 0.50)),
        ("below it",     NormalizedPoint(x: 0.50, y: 0.10)),
        ("above it",     NormalizedPoint(x: 0.50, y: 0.95)),
    ]
    for (where_, point) in outside {
        #expect(record(clickAt: point).clickContainment == .doesNotContainTheClick,
                "a click \(where_) the element's frame is not inside it")
    }
}

/// Inclusive on the boundary: a click on a control's edge is not a fault.
@Test func aClickExactlyOnTheFramesEdgeCounts() {
    for corner in [NormalizedPoint(x: 0.4, y: 0.4), NormalizedPoint(x: 0.6, y: 0.6),
                   NormalizedPoint(x: 0.4, y: 0.6), NormalizedPoint(x: 0.6, y: 0.4)] {
        #expect(record(clickAt: corner).clickContainment == .containsTheClick)
    }
}

/// Frames from different displays are not comparable, and say so rather than trapping.
@Test func containmentRefusesAcrossDisplayRevisions() {
    let straddling = record(clickAt: NormalizedPoint(x: 0.5, y: 0.5),
                            clickRevision: otherRev,
                            hit: element(frame: middleFrame(revision: rev)))
    #expect(straddling.clickContainment == .notComparable)
}

/// The two absences are different absences, and neither is `false`.
@Test func containmentNamesTheTwoAbsencesSeparately() {
    #expect(record(hit: element(frame: nil)).clickContainment == .noFrameRecorded)
    #expect(record(hit: nil, truncation: .hitTestReturnedNothing).clickContainment == .noHitElement)
}

/// The timing half of the same split: how long the click waited for the answer.
@Test func theTimingExposureIsReadableFromTheRecordAlone() {
    let click = at(1_000_000)
    let answered = record(instant: click, hitTestInterval: span(1_020_000, 4_000_000))
    #expect(answered.clickToHitTestAnswerNanos == 4_020_000)
}

/// Across a boot epoch there is no duration to report, and none beats a guess.
@Test func theTimingExposureIsAbsentRatherThanWrongAcrossEpochs() {
    let mismatched = record(instant: at(1_000_000),
                            hitTestInterval: span(1_020_000, 4_000_000, epoch: otherEp))
    #expect(mismatched.clickToHitTestAnswerNanos == nil)
}

// MARK: - a damaged file must not read as a coordinate fault

/// A non-finite coordinate off disk would read as a coordinate fault rather
/// than a damaged file. Property list, not JSON, on purpose: `JSONDecoder`
/// refuses non-finite doubles itself, so JSON would pass for its reason.
@Test func aNonFiniteClickPositionIsRefusedByThisTypeAndNotOnlyByFoundation() throws {
    let valid = try PropertyListEncoder().encode(record())
    var object = try #require(PropertyListSerialization.propertyList(
        from: valid, options: [], format: nil) as? [String: Any])
    object["clickPosition"] = ["x": Double.infinity, "y": 0.5]
    let damaged = try PropertyListSerialization.data(fromPropertyList: object,
                                                     format: .binary, options: 0)

    struct JustThePoint: Decodable { let clickPosition: NormalizedPoint }
    let delivered = try PropertyListDecoder().decode(JustThePoint.self, from: damaged)
    #expect(!delivered.clickPosition.x.isFinite,
            "the fixture must actually carry a non-finite value, or the refusal below means nothing")

    #expect(throws: DecodingError.self) {
        _ = try PropertyListDecoder().decode(AXChainRecord.self, from: damaged)
    }
}

/// A negative dimension is legal JSON, so the refusal is this type's own.
@Test func aFrameWithANegativeDimensionIsRefused() throws {
    let valid = try ObservationLog.encode(record(hit: element()))
    var object = try #require(try JSONSerialization.jsonObject(with: valid) as? [String: Any])
    var hit = try #require(object["hit"] as? [String: Any])
    hit["frame"] = ["origin": ["x": 0.4, "y": 0.4],
                    "size": ["width": 0.2, "height": -1.0],
                    "revision": ["id": rev.id]]
    object["hit"] = hit
    let damaged = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: DecodingError.self) {
        _ = try ObservationLog.decode(damaged) as AXChainRecord
    }
}

/// A negative `axCalls` is legal JSON but not a value this producer can emit.
@Test func aNegativeCallCountIsRefused() throws {
    let valid = try ObservationLog.encode(record())
    var object = try #require(try JSONSerialization.jsonObject(with: valid) as? [String: Any])
    object["axCalls"] = -1
    let damaged = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: DecodingError.self) {
        _ = try ObservationLog.decode(damaged) as AXChainRecord
    }
}

/// The hand-written conformance must not have changed the wire form.
@Test func validationDidNotChangeTheEncodedShape() throws {
    let full = record(hit: element(), ancestors: [element(role: "AXGroup", title: nil)],
                      children: [element(role: "AXStaticText", title: nil)])
    #expect(try roundTrip(full) == full)

    let keys = try #require(try JSONSerialization.jsonObject(
        with: ObservationLog.encode(full)) as? [String: Any]).keys.sorted()
    #expect(keys == ["ancestors", "axCalls", "children", "clickPosition", "clickRevision",
                     "depthCap", "hit", "hitTestGlobalX", "hitTestGlobalY", "hitTestInterval",
                     "instant", "kind", "truncation", "walkBudgetNanos"],
            "the encoded key set is the synthesised one: \(keys)")
}

// MARK: - the log can route it without decoding it

@Test func theRecordAnnouncesItsKindToTheLogReader() throws {
    let line = try ObservationLog.encode(record())
    #expect(try ObservationLog.kind(of: line) == "axChain")
}
