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

// MARK: - the three distinctions the type exists for (task brief, step 2)

@Test func everyTruncationReasonSurvivesARoundTrip() throws {
    for reason in [ChainTruncation.reachedRoot, .depthCapReached, .budgetExceeded, .hitTestReturnedNothing] {
        let decoded = try roundTrip(record(truncation: reason))
        #expect(decoded.truncation == reason)
    }
}

/// **"There were no more ancestors" and "I stopped asking" must not be the same
/// bytes on disk** (D2-2). Both records below have an empty `ancestors`, which
/// is the case where the distinction is carried entirely by `truncation` — if
/// the field were dropped from the encoding, or defaulted on decode, these two
/// would become one record and a derivation could no longer tell a chain that
/// ended from a chain that was cut off.
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

/// **An element with no children is not an element whose children were never
/// read.** `[]` is a measurement; `nil` is an absence of one.
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

/// **The positive direction: a click inside the element the hit-test returned.**
///
/// This is the assertion the whole coordinate/timing split rests on, so it is
/// also the one that had to be observed failing. Feeding it a click point
/// outside the same element's frame — the mutation in the task report — turns
/// it red with `.doesNotContainTheClick`; the check is not satisfiable by any
/// point on the display.
@Test func aClickInsideTheReturnedElementsFrameIsRecordedAsContained() {
    let inside = record(clickAt: NormalizedPoint(x: 0.5, y: 0.5))
    #expect(inside.clickContainment == .containsTheClick)
}

/// **The negative direction, in all four axes.** A click outside the returned
/// element's own frame is a *coordinate* fault: AX staleness moves an element
/// by a frame or two of animation, it does not move it out of the coordinate
/// space it reported itself in. Each of these four is a conversion that
/// dropped a step — the pixel step, the routing step, or the Y flip — and none
/// of them produces an out-of-range value that would be caught any other way.
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

/// Inclusive on the boundary, deliberately: `false` is this predicate's loud
/// direction, so a click exactly on a control's edge must not be reported as a
/// coordinate fault.
@Test func aClickExactlyOnTheFramesEdgeCounts() {
    for corner in [NormalizedPoint(x: 0.4, y: 0.4), NormalizedPoint(x: 0.6, y: 0.6),
                   NormalizedPoint(x: 0.4, y: 0.6), NormalizedPoint(x: 0.6, y: 0.4)] {
        #expect(record(clickAt: corner).clickContainment == .containsTheClick)
    }
}

/// Two frames normalised against different displays are not comparable, and
/// the record says so rather than trapping the way `NormalizedFrame.contains`
/// would — a window straddling two displays produces this legitimately, and it
/// is neither a coordinate fault nor a timing one.
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
/// F2-2 measured this to 125.47 ms at worst, which is 7.5 frames at 60 fps.
@Test func theTimingExposureIsReadableFromTheRecordAlone() {
    let click = at(1_000_000)
    let answered = record(instant: click, hitTestInterval: span(1_020_000, 4_000_000))
    #expect(answered.clickToHitTestAnswerNanos == 4_020_000)
}

/// Across a boot epoch the two instants are not on one clock, so there is no
/// duration to report — and a plausible-looking number would be worse than
/// none.
@Test func theTimingExposureIsAbsentRatherThanWrongAcrossEpochs() {
    let mismatched = record(instant: at(1_000_000),
                            hitTestInterval: span(1_020_000, 4_000_000, epoch: otherEp))
    #expect(mismatched.clickToHitTestAnswerNanos == nil)
}

// MARK: - a damaged file must not read as a coordinate fault

/// **The failure this guards against is silent and it lands in the one type
/// whose job is telling faults apart.** `NormalizedPoint` and `NormalizedSize`
/// `precondition` on finiteness, and their *synthesised* `Decodable`
/// conformances bypass it — so a non-finite coordinate cannot be built in
/// memory but could be read off disk, and every comparison against `NaN` is
/// `false`, which makes `clickContainment` answer `.doesNotContainTheClick`:
/// a confident coordinate-fault verdict for a file that is merely damaged.
///
/// **Measured, and it changes what this test can claim.** Foundation's
/// `JSONDecoder` refuses every route to a non-finite `Double` before this
/// type's own validation runs — checked against this SDK with four payloads,
/// `1e400`, `-1e400`, a bare `NaN` token and the string `"NaN"`, all four
/// `DecodingError`. So through `ObservationLog`, which is a plain
/// `JSONDecoder`, the hole is already closed one layer down and a JSON-based
/// test here would pass for Foundation's reason, not this type's.
///
/// This test therefore uses a property list, which **does** carry infinity
/// through (measured: encode `.infinity`, decode, `isFinite == false`). That
/// makes the guard's own behaviour observable instead of shadowed, which is
/// the difference between a check and a check-shaped statement.
@Test func aNonFiniteClickPositionIsRefusedByThisTypeAndNotOnlyByFoundation() throws {
    let valid = try PropertyListEncoder().encode(record())
    var object = try #require(PropertyListSerialization.propertyList(
        from: valid, options: [], format: nil) as? [String: Any])
    object["clickPosition"] = ["x": Double.infinity, "y": 0.5]
    let damaged = try PropertyListSerialization.data(fromPropertyList: object,
                                                     format: .binary, options: 0)

    // The property-list layer really does deliver it — without this the test
    // below could pass because the payload never got that far.
    struct JustThePoint: Decodable { let clickPosition: NormalizedPoint }
    let delivered = try PropertyListDecoder().decode(JustThePoint.self, from: damaged)
    #expect(!delivered.clickPosition.x.isFinite,
            "the fixture must actually carry a non-finite value, or the refusal below means nothing")

    #expect(throws: DecodingError.self) {
        _ = try PropertyListDecoder().decode(AXChainRecord.self, from: damaged)
    }
}

/// A negative dimension is ordinary, legal JSON — Foundation has no opinion on
/// it — so this one is reachable through the real path and the refusal can
/// only be this type's own.
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

/// `axCalls` is arithmetic a reader divides and compares — against F2-2's
/// distribution, against the depth cap. A negative one is not a value this
/// producer can emit, and it is legal JSON.
@Test func aNegativeCallCountIsRefused() throws {
    let valid = try ObservationLog.encode(record())
    var object = try #require(try JSONSerialization.jsonObject(with: valid) as? [String: Any])
    object["axCalls"] = -1
    let damaged = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: DecodingError.self) {
        _ = try ObservationLog.decode(damaged) as AXChainRecord
    }
}

/// The hand-written conformance must not have changed the wire form — the
/// same guarantee `HostRange` and `DisplayGeometry` state for theirs.
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
