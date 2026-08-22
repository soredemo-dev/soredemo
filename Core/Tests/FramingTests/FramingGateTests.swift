import Foundation
import Geometry
import Project
import Testing
import Timeline
@testable import Framing

// The gates, one test per refusal plus the acceptance. Every rejection is a VALUE with a
// stable code — `review-ui` shows which gate fired, and a `nil` would erase the reason the
// moment it was computed.

private let epoch = BootEpoch(id: UUID(uuidString: "C0FFEE00-1111-4222-8333-444455556666")!)
private let revision = GeometryRevision(id: 7)
private let otherRevision = GeometryRevision(id: 8)

private func range(_ start: Int64, _ duration: Int64) -> HostRange {
    HostRange(epoch: epoch, start: Nanoseconds(start), duration: Nanoseconds(duration))
}

private func element(role: String = "AXButton",
                     x: Double = 0.4, y: Double = 0.4,
                     width: Double = 0.1, height: Double = 0.05,
                     revision r: GeometryRevision = revision) -> AXElementRecord {
    AXElementRecord(role: role, title: "Record",
                    frame: NormalizedFrame(origin: NormalizedPoint(x: x, y: y),
                                           size: NormalizedSize(width: width, height: height),
                                           revision: r),
                    readInterval: range(1_000, 500_000))
}

/// A chain whose defaults all PASS, so each test below changes exactly one thing and the
/// failure it provokes is attributable. The click sits inside the default element.
private func chain(hit: AXElementRecord? = element(),
                   ancestors: [AXElementRecord] = [element(role: "AXWindow", x: 0.1, y: 0.1,
                                                           width: 0.8, height: 0.8)],
                   truncation: ChainTruncation = .reachedRoot,
                   clickX: Double = 0.45, clickY: Double = 0.42,
                   hitTestDuration: Int64 = 2_000_000) -> AXChainRecord {
    AXChainRecord(instant: HostInstant(epoch: epoch, hostTime: Nanoseconds(1_000)),
                  clickPosition: NormalizedPoint(x: clickX, y: clickY),
                  clickRevision: revision,
                  hitTestGlobalX: 100, hitTestGlobalY: 200,
                  hitTestInterval: range(1_000, hitTestDuration),
                  hit: hit, ancestors: ancestors, children: [],
                  truncation: truncation, axCalls: 5,
                  depthCap: 12, walkBudgetNanos: 8_000_000)
}

// MARK: - the accepting case

/// The default chain frames the HIT element, not an ancestor and not the click point.
@Test func aWellFormedChainFramesTheHitElement() throws {
    guard case .framed(let target) = FramingGate.decide(for: chain()) else {
        Issue.record("a chain designed to pass every gate was refused")
        return
    }
    #expect(target.frame.origin.x == 0.4 && target.frame.size.width == 0.1)
    #expect(target.role == "AXButton")
}

// MARK: - the nine refusals, in the order they fire

@Test func aHitTestThatReturnedNothingIsRefusedAsSuch() {
    let decision = FramingGate.decide(for: chain(hit: nil, truncation: .hitTestReturnedNothing))
    #expect(decision.rejection == .hitTestReturnedNothing)
}

/// AX answered with an element and no geometry. Distinct from a BAD frame: nothing was
/// measured, so nothing can be judged degenerate or offscreen.
@Test func anElementWithNoFrameIsRefusedForThatAndNotForGeometry() {
    let frameless = AXElementRecord(role: "AXButton", title: "Record", frame: nil,
                                    readInterval: range(1_000, 500_000))
    #expect(FramingGate.decide(for: chain(hit: frameless)).rejection == .noFrameRecorded)
}

/// The read took longer than the budget: the window may have moved between the click and
/// the frame being reported, so the rectangle describes a place that may no longer exist.
@Test func aSlowHitTestIsRefusedAsStale() {
    let slow = FramingGate.stalenessBudget.rawValue + 1
    #expect(FramingGate.decide(for: chain(hitTestDuration: slow)).rejection == .staleObservation)
}

/// Two geometry revisions are two coordinate systems — the `1a98402` family, one domain
/// over. Refused rather than compared.
@Test func aFrameFromAnotherRevisionIsRefusedAsNotComparable() {
    #expect(FramingGate.decide(for: chain(hit: element(revision: otherRevision))).rejection
            == .notComparable)
}

/// A coordinate fault: AX returned an element the click is not inside. Fires BEFORE the
/// geometry gates, because "this is the wrong element" explains more than "its rectangle
/// is odd".
@Test func aClickOutsideTheHitFrameIsRefusedAsAFault() {
    #expect(FramingGate.decide(for: chain(clickX: 0.9, clickY: 0.9)).rejection
            == .doesNotContainTheClick)
}

@Test func aZeroSizedFrameIsRefusedAsDegenerate() {
    let flat = element(width: 0, height: 0.05)
    #expect(FramingGate.decide(for: chain(hit: flat, clickX: 0.4, clickY: 0.42)).rejection
            == .degenerateRectangle)
}

/// Half the target is not on the recording, so framing it would zoom to empty space.
@Test func aFrameExtendingBeyondTheScreenIsRefused() {
    let overhanging = element(x: 0.95, y: 0.4, width: 0.2, height: 0.05)
    #expect(FramingGate.decide(for: chain(hit: overhanging, clickX: 0.97, clickY: 0.42)).rejection
            == .partlyOffscreen)
}

/// **A pane is not a control.** Zooming to something that already covers the screen is a
/// no-op that reads as a bug.
@Test func aFrameCoveringMostOfTheScreenIsRefusedAsTooLarge() {
    let pane = element(role: "AXScrollArea", x: 0.02, y: 0.02, width: 0.96, height: 0.96)
    #expect(FramingGate.decide(for: chain(hit: pane)).rejection == .tooLarge)
}

/// Phase 2's F2-3, measured at 7–8% of clicks: when the chain was CUT and the element
/// chosen is the outermost one recorded, it is indistinguishable on disk from one that was
/// genuinely outermost. Refusal is the honest answer; a guess here is a zoom to the wrong
/// thing with no way to tell afterwards.
@Test func anOutermostElementOfACutChainIsRefused() {
    // No ancestors recorded AND the walk was cut: the hit element is the boundary.
    let decision = FramingGate.decide(for: chain(ancestors: [], truncation: .depthCapReached))
    #expect(decision.rejection == .bestCandidateOnTheTruncationBoundary)
}

/// The same shape with the walk NOT cut is fine — an element that genuinely has no
/// ancestors is a root, not a truncation artefact. This is the pair that makes the gate
/// above about truncation rather than about ancestor count.
@Test func anOutermostElementOfACompleteChainIsAccepted() {
    let decision = FramingGate.decide(for: chain(ancestors: [], truncation: .reachedRoot))
    #expect(decision.rejection == nil)
}

// MARK: - ordering, which is a claim about which explanation is more useful

/// A chain that trips FOUR gates reports the earliest. Without a defined order the reported
/// reason would depend on evaluation accident, and `review-ui` would show a different cause
/// for the same recording between builds.
@Test func theEarliestApplicableGateIsTheReportedReason() {
    let bad = AXElementRecord(role: "AXButton", title: nil, frame: nil,
                              readInterval: range(1_000, 500_000))
    let decision = FramingGate.decide(for: chain(hit: bad,
                                                 truncation: .budgetExceeded,
                                                 hitTestDuration: FramingGate.stalenessBudget.rawValue + 1))
    // noFrameRecorded (2) precedes staleObservation (3) and the truncation gate (9).
    #expect(decision.rejection == .noFrameRecorded)
}

/// Every code has a distinct raw value: they persist, and two gates sharing a string would
/// make a report unreadable.
@Test func everyRejectionCodeIsDistinctAndStable() {
    let all = FramingRejection.allCases.map(\.rawValue)
    #expect(Set(all).count == all.count)
    #expect(all.contains("tooLarge"))
    #expect(all.contains("bestCandidateOnTheTruncationBoundary"))
}
