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

/// When the default click was let go: 100 ms after it went down, inside the 83–113 ms the
/// fixture's three real clicks took. Every test that is not about the release uses this, so a
/// refusal below is never the release's doing by accident.
private let letGo = HostInstant(epoch: epoch, hostTime: Nanoseconds(1_000 + 100_000_000))

/// The gate, with the default release unless a test is about the release.
private func decide(_ record: AXChainRecord, releasedAt release: HostInstant? = letGo) -> FramingDecision {
    FramingGate.decide(for: record, releasedAt: release)
}

// MARK: - the accepting case

/// The default chain frames the HIT element, not an ancestor and not the click point.
@Test func aWellFormedChainFramesTheHitElement() throws {
    guard case .framed(let target) = decide(chain()) else {
        Issue.record("a chain designed to pass every gate was refused")
        return
    }
    #expect(target.frame.origin.x == 0.4 && target.frame.size.width == 0.1)
    #expect(target.role == "AXButton")
}

// MARK: - the refusals, in the order they fire

@Test func aHitTestThatReturnedNothingIsRefusedAsSuch() {
    let decision = decide(chain(hit: nil, truncation: .hitTestReturnedNothing))
    #expect(decision.rejection == .hitTestReturnedNothing)
}

/// AX answered with an element and no geometry. Distinct from a BAD frame: nothing was
/// measured, so nothing can be judged degenerate or offscreen.
@Test func anElementWithNoFrameIsRefusedForThatAndNotForGeometry() {
    let frameless = AXElementRecord(role: "AXButton", title: "Record", frame: nil,
                                    readInterval: range(1_000, 500_000))
    #expect(decide(chain(hit: frameless)).rejection == .noFrameRecorded)
}

/// **Slow is not stale.** The fixture's own first click took 36.6 ms to hit-test and was let
/// go 82.7 ms after it went down: the answer is about the moment the person was still holding
/// the button over what they chose. This was refused at the old 4 ms budget.
@Test func aSlowReadThatEndedBeforeTheReleaseIsNotStale() {
    let released = HostInstant(epoch: epoch, hostTime: Nanoseconds(1_000 + 82_700_000))
    #expect(decide(chain(hitTestDuration: 36_643_625), releasedAt: released).rejection == nil)
}

/// A read that ended after the release may describe what the click's action put there — a
/// page that navigated, a sheet that opened — so its frame is not trusted, however fast it was.
@Test func aReadThatEndedAfterTheReleaseIsStale() {
    let released = HostInstant(epoch: epoch, hostTime: Nanoseconds(1_000 + 1_000_000))
    #expect(decide(chain(hitTestDuration: 2_000_000), releasedAt: released).rejection
            == .staleObservation)
}

/// **The frame is read after the hit-test**, as part of the hit element, so the read ends when
/// that does. A hit-test over in 2 ms with the element read until 50 ms is a read that ended
/// at 50 ms — after a release at 10 ms.
@Test func theHitElementsOwnReadCountsNotOnlyTheHitTest() {
    let lateRead = AXElementRecord(role: "AXButton", title: "Record",
                                   frame: NormalizedFrame(origin: NormalizedPoint(x: 0.4, y: 0.4),
                                                          size: NormalizedSize(width: 0.1, height: 0.05),
                                                          revision: revision),
                                   readInterval: range(2_001_000, 48_000_000))
    let released = HostInstant(epoch: epoch, hostTime: Nanoseconds(1_000 + 10_000_000))
    #expect(decide(chain(hit: lateRead, hitTestDuration: 2_000_000), releasedAt: released).rejection
            == .staleObservation)
}

/// No release in the log — the take ended with the button held, or the release fell in a blind
/// interval. That is not evidence the read was in time, so it is refused, by its own name.
@Test func aClickWithNoReleaseIsRefusedByName() {
    #expect(decide(chain(), releasedAt: nil).rejection == .releaseNotObserved)
}

/// A release from another boot is on another clock, and comparing it is meaningless.
@Test func aReleaseFromAnotherBootIsNoRelease() {
    let otherBoot = BootEpoch(id: UUID(uuidString: "C0FFEE00-9999-4222-8333-444455556666")!)
    let released = HostInstant(epoch: otherBoot, hostTime: Nanoseconds(1_000 + 100_000_000))
    #expect(decide(chain(), releasedAt: released).rejection == .releaseNotObserved)
}

/// Two geometry revisions are two coordinate systems — the `1a98402` family, one domain
/// over. Refused rather than compared.
@Test func aFrameFromAnotherRevisionIsRefusedAsNotComparable() {
    #expect(decide(chain(hit: element(revision: otherRevision))).rejection
            == .notComparable)
}

/// A coordinate fault: AX returned an element the click is not inside. Fires BEFORE the
/// geometry gates, because "this is the wrong element" explains more than "its rectangle
/// is odd".
@Test func aClickOutsideTheHitFrameIsRefusedAsAFault() {
    #expect(decide(chain(clickX: 0.9, clickY: 0.9)).rejection
            == .doesNotContainTheClick)
}

@Test func aZeroSizedFrameIsRefusedAsDegenerate() {
    let flat = element(width: 0, height: 0.05)
    #expect(decide(chain(hit: flat, clickX: 0.4, clickY: 0.42)).rejection
            == .degenerateRectangle)
}

/// Half the target is not on the recording, so framing it would zoom to empty space.
@Test func aFrameExtendingBeyondTheScreenIsRefused() {
    let overhanging = element(x: 0.95, y: 0.4, width: 0.2, height: 0.05)
    #expect(decide(chain(hit: overhanging, clickX: 0.97, clickY: 0.42)).rejection
            == .partlyOffscreen)
}

/// **A pane is not a control.** Zooming to something that already covers the screen is a
/// no-op that reads as a bug.
@Test func aFrameCoveringMostOfTheScreenIsRefusedAsTooLarge() {
    let pane = element(role: "AXScrollArea", x: 0.02, y: 0.02, width: 0.96, height: 0.96)
    #expect(decide(chain(hit: pane)).rejection == .tooLarge)
}

/// Phase 2's F2-3, measured at 7–8% of clicks: when the chain was CUT and the element
/// chosen is the outermost one recorded, it is indistinguishable on disk from one that was
/// genuinely outermost. Refusal is the honest answer; a guess here is a zoom to the wrong
/// thing with no way to tell afterwards.
@Test func anOutermostElementOfACutChainIsRefused() {
    // No ancestors recorded AND the walk was cut: the hit element is the boundary.
    let decision = decide(chain(ancestors: [], truncation: .depthCapReached))
    #expect(decision.rejection == .bestCandidateOnTheTruncationBoundary)
}

/// The same shape with the walk NOT cut is fine — an element that genuinely has no
/// ancestors is a root, not a truncation artefact. This is the pair that makes the gate
/// above about truncation rather than about ancestor count.
@Test func anOutermostElementOfACompleteChainIsAccepted() {
    let decision = decide(chain(ancestors: [], truncation: .reachedRoot))
    #expect(decision.rejection == nil)
}

// MARK: - ordering, which is a claim about which explanation is more useful

/// A chain that trips FOUR gates reports the earliest. Without a defined order the reported
/// reason would depend on evaluation accident, and `review-ui` would show a different cause
/// for the same recording between builds.
@Test func theEarliestApplicableGateIsTheReportedReason() {
    let bad = AXElementRecord(role: "AXButton", title: nil, frame: nil,
                              readInterval: range(1_000, 500_000))
    let released = HostInstant(epoch: epoch, hostTime: Nanoseconds(1_000))
    let decision = decide(chain(hit: bad, truncation: .budgetExceeded), releasedAt: released)
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

// MARK: - a click on the recorder's own window

/// **The whole path, through the real gate and the real plan's pointer fallback.** A click on
/// the recording bar — Stop, most often — is recorded as `.overOwnWindow` with no hit. Before
/// this, the gate turned every missing hit into `.hitTestReturnedNothing`, and the plan's
/// fallback zooms to the pointer for exactly that, so every recording stopped from the bar
/// ended with the camera moving toward where the bar had been.
@Test func aClickOnTheRecordersOwnWindowIsNeverZoomedToNotEvenByTheFallback() {
    let record = chain(hit: nil, ancestors: [], truncation: .overOwnWindow)
    let decision = decide(record)
    #expect(decision.rejection == .overOwnWindow,
            "the refusal must name the recorder's own window, got \(String(describing: decision))")

    let plan = FramingPlan(entries: [FramingPlan.Entry(instant: record.instant,
                                                       decision: decision,
                                                       clickPosition: record.clickPosition,
                                                       clickRevision: record.clickRevision)])
    let resolved = plan.resolvedWithPointerFallback(overrides: [], revision: revision)
    #expect(resolved.count == 1)
    #expect(resolved.allSatisfy { $0.target == nil },
            "the pointer fallback zoomed to a click on the recorder's own window")
}

/// The positive control: a click where the hit-test genuinely found nothing still gets the
/// pointer fallback. Without it, a plan that stopped falling back for EVERY refusal would pass
/// the test above — and would bring back the eleven identical frames the fallback exists for.
@Test func aClickOverNothingStillFallsBackToThePointer() {
    let record = chain(hit: nil, ancestors: [], truncation: .hitTestReturnedNothing)
    let plan = FramingPlan(entries: [FramingPlan.Entry(instant: record.instant,
                                                       decision: decide(record),
                                                       clickPosition: record.clickPosition,
                                                       clickRevision: record.clickRevision)])
    let resolved = plan.resolvedWithPointerFallback(overrides: [], revision: revision)
    #expect(resolved.first?.target != nil, "a click over nothing lost its pointer fallback")
}
