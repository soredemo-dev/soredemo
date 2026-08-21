import Foundation
import Geometry
import Project
import Testing
import Timeline
@testable import Framing

private let epoch = BootEpoch(id: UUID(uuidString: "9B1DE104-6C3E-4E2A-8B3C-2B6A6F1F9C07")!)
private let otherEpoch = BootEpoch(id: UUID(uuidString: "0BADC0DE-0000-4000-8000-000000000001")!)
private let revision = GeometryRevision(id: 1)

private func at(_ ns: Int64) -> HostInstant {
    HostInstant(epoch: epoch, hostTime: Nanoseconds(ns))
}

private func frame(x: Double, y: Double, width: Double = 0.2, height: Double = 0.1) -> NormalizedFrame {
    NormalizedFrame(origin: NormalizedPoint(x: x, y: y),
                    size: NormalizedSize(width: width, height: height),
                    revision: revision)
}

private func framed(_ ns: Int64, role: String = "AXButton") -> FramingPlan.Entry {
    FramingPlan.Entry(instant: at(ns),
                      decision: .framed(FramingTarget(frame: frame(x: 0.1, y: 0.1), role: role)))
}

private func rejected(_ ns: Int64, _ reason: FramingRejection) -> FramingPlan.Entry {
    FramingPlan.Entry(instant: at(ns), decision: .rejected(reason))
}

/// **The reasons used to be computed and then thrown away.** `StageCompositor` kept the
/// accepted targets and discarded every refusal one call after the gate named it, so a
/// recording that zoomed nowhere could not say why. A plan keeps both.
@Suite struct FramingPlanTests {
    @Test func aPlanKeepsRefusalsAndCountsThemByReason() {
        let plan = FramingPlan(entries: [
            framed(1_000), rejected(2_000, .tooLarge), rejected(3_000, .tooLarge),
            rejected(4_000, .staleObservation),
        ])
        #expect(plan.framedCount == 1)
        #expect(plan.rejectionCounts[.tooLarge] == 2)
        #expect(plan.rejectionCounts[.staleObservation] == 1)
        #expect(plan.rejectionCounts[.hitTestReturnedNothing] == nil,
                "a reason that never fired must be absent, not zero — they are different facts")
    }

    /// Entries arrive in log order, which is not guaranteed to be time order once a log has
    /// been merged or a segment re-read. Everything downstream reads them as a timeline.
    @Test func entriesAreOrderedByInstant() {
        let plan = FramingPlan(entries: [framed(3_000), framed(1_000), framed(2_000)])
        #expect(plan.entries.map { $0.instant.hostTime.rawValue } == [1_000, 2_000, 3_000])
    }
}

/// **The producer-value rule, tested the way the README asks for it**: by supplying a value
/// the producer could not have derived. An override frame at coordinates no AX element
/// reported cannot have come from the gate, so a resolution that returns it can only have
/// come from the author.
@Suite struct FramingOverrideTests {
    @Test func anAuthoredFrameWinsOverARefusal() {
        let plan = FramingPlan(entries: [rejected(1_000, .tooLarge)])
        let authored = frame(x: 0.77, y: 0.31, width: 0.05, height: 0.05)
        let resolved = plan.resolved(with: [
            FramingOverride(epoch: epoch, instant: Nanoseconds(1_000), action: .frame(authored)),
        ])

        #expect(resolved.count == 1)
        #expect(resolved[0].target?.frame == authored)
        #expect(resolved[0].wasOverridden)
    }

    /// The gate's reason survives the override. A reviewer who forced a zoom past
    /// `tooLarge` must still be able to see that `tooLarge` is what they overrode —
    /// otherwise the override erases the very reason it was a judgement call.
    @Test func anOverrideDoesNotEraseTheReasonItOverrode() {
        let plan = FramingPlan(entries: [rejected(1_000, .tooLarge)])
        let resolved = plan.resolved(with: [
            FramingOverride(epoch: epoch, instant: Nanoseconds(1_000),
                            action: .frame(frame(x: 0.4, y: 0.4))),
        ])
        #expect(resolved[0].rejection == .tooLarge)
    }

    @Test func anAuthoredSuppressionWinsOverAnAcceptedTarget() {
        let plan = FramingPlan(entries: [framed(1_000)])
        let resolved = plan.resolved(with: [
            FramingOverride(epoch: epoch, instant: Nanoseconds(1_000), action: .suppress),
        ])
        #expect(resolved[0].target == nil)
        #expect(resolved[0].wasOverridden)
        #expect(plan.framedClicks(with: [
            FramingOverride(epoch: epoch, instant: Nanoseconds(1_000), action: .suppress),
        ]).isEmpty, "a suppressed click must not reach the camera")
    }

    /// An override at an instant the gate never saw is still honoured. Making the authored
    /// value conditional on the producer having had an opinion is the opposite of the rule.
    @Test func anOverrideAtAnInstantWithNoDecisionIsStillHonoured() {
        let plan = FramingPlan(entries: [framed(1_000)])
        let authored = frame(x: 0.6, y: 0.6)
        let resolved = plan.resolved(with: [
            FramingOverride(epoch: epoch, instant: Nanoseconds(9_000), action: .frame(authored)),
        ])
        #expect(resolved.count == 2)
        #expect(resolved.last?.target?.frame == authored)
        #expect(resolved.last?.origin == .authored(over: nil))
    }

    /// Two boots produce overlapping host times. An override recorded in one session must
    /// not silently take effect in another — the same fault `CursorOverride.epoch` closed.
    @Test func anOverrideFromAnotherEpochDoesNotApply() {
        let plan = FramingPlan(entries: [framed(1_000)])
        let resolved = plan.resolved(with: [
            FramingOverride(epoch: otherEpoch, instant: Nanoseconds(1_000), action: .suppress),
        ])
        // The click keeps the gate's target…
        #expect(resolved.first(where: { $0.instant.epoch == epoch })?.target != nil)
        #expect(resolved.first(where: { $0.instant.epoch == epoch })?.wasOverridden == false)
        // …and the foreign override lands as its own entry rather than vanishing.
        #expect(resolved.contains { $0.instant.epoch == otherEpoch })
    }

    /// An override that only moves the rectangle should not also erase what the element was.
    @Test func anOverriddenFrameKeepsTheRoleTheGateIdentified() {
        let plan = FramingPlan(entries: [framed(1_000, role: "AXTextField")])
        let resolved = plan.resolved(with: [
            FramingOverride(epoch: epoch, instant: Nanoseconds(1_000),
                            action: .frame(frame(x: 0.5, y: 0.5))),
        ])
        #expect(resolved[0].target?.role == "AXTextField")
    }

    /// A project that contradicts itself resolves deterministically rather than by whichever
    /// write reached a dictionary last.
    @Test func twoOverridesAtOneInstantResolveToTheFirst() {
        let plan = FramingPlan(entries: [framed(1_000)])
        let first = frame(x: 0.11, y: 0.11)
        let resolved = plan.resolved(with: [
            FramingOverride(epoch: epoch, instant: Nanoseconds(1_000), action: .frame(first)),
            FramingOverride(epoch: epoch, instant: Nanoseconds(1_000), action: .suppress),
        ])
        #expect(resolved.count == 1)
        #expect(resolved[0].target?.frame == first)
    }

    /// Re-deriving must not quietly replace an authored value. The plan is what changes when
    /// a recording is re-analysed; the overrides are project state and survive it.
    @Test func rederivingThePlanDoesNotReplaceAnAuthoredValue() {
        let overrides = [FramingOverride(epoch: epoch, instant: Nanoseconds(1_000),
                                         action: .frame(frame(x: 0.9, y: 0.9)))]
        let before = FramingPlan(entries: [rejected(1_000, .tooLarge)])
        // The gate changes its mind — a newer analysis now accepts the click.
        let after = FramingPlan(entries: [framed(1_000)])

        #expect(before.resolved(with: overrides)[0].target?.frame
                == after.resolved(with: overrides)[0].target?.frame,
                "the authored rectangle must survive the producer changing its answer")
        #expect(after.resolved(with: overrides)[0].wasOverridden)
    }

    @Test func withNoOverridesEveryEntryIsDerived() {
        let plan = FramingPlan(entries: [framed(1_000), rejected(2_000, .partlyOffscreen)])
        let resolved = plan.resolved(with: [])
        #expect(resolved.allSatisfy { $0.origin == .derived })
        #expect(resolved.allSatisfy { !$0.wasOverridden })
        #expect(plan.framedClicks(with: []).count == 1)
    }
}

/// **The clause `framing-targets` had left unbuilt, and a real recording found it.** Eleven
/// frames of a user's export measured with the card identical in every one — the camera never
/// moved, because every accessibility chain came back `hitTestReturnedNothing` on a machine
/// that had not granted Accessibility. Nine gates working correctly and a video that zooms
/// nowhere is still a video that zooms nowhere.
@Suite struct PointerFallbackTests {
    private let click = NormalizedPoint(x: 0.5, y: 0.5)

    private func rejectedWithClick(_ ns: Int64, _ reason: FramingRejection,
                                   at position: NormalizedPoint) -> FramingPlan.Entry {
        FramingPlan.Entry(instant: at(ns), decision: .rejected(reason), clickPosition: position)
    }

    @Test func aRefusedClickWithAPositionFramesThePointer() {
        let plan = FramingPlan(entries: [rejectedWithClick(1_000, .hitTestReturnedNothing, at: click)])
        let resolved = plan.resolvedWithPointerFallback(overrides: [], revision: revision)

        let target = resolved[0].target
        #expect(target != nil, "the fallback did not produce a target")
        #expect(target?.frame.size.width == FramingPlan.pointerFallbackExtent)
        // Centred on the click.
        #expect(abs((target!.frame.origin.x + target!.frame.size.width / 2) - 0.5) < 1e-12)
    }

    /// **The reason survives.** `FramingGate` refuses to fall back internally precisely so the
    /// refusal it just computed is not erased; a fallback one layer out that dropped it would
    /// have made that refusal pointless. `review-ui` shows both.
    @Test func theFallbackCarriesTheRefusalItReplaced() {
        let plan = FramingPlan(entries: [rejectedWithClick(1_000, .tooLarge, at: click)])
        let resolved = plan.resolvedWithPointerFallback(overrides: [], revision: revision)
        #expect(resolved[0].origin == .pointerFallback(over: .tooLarge))
        #expect(resolved[0].rejection == .tooLarge)
    }

    /// A fallback names no role. Nothing identified the element — that is why it is a fallback
    /// — and a fabricated role would read as an identification the recorder never made.
    @Test func aFallbackTargetNamesNoRole() {
        let plan = FramingPlan(entries: [rejectedWithClick(1_000, .noFrameRecorded, at: click)])
        #expect(plan.resolvedWithPointerFallback(overrides: [], revision: revision)[0]
                    .target?.role == nil)
    }

    /// A click near an edge must not frame space outside the recording.
    /// `FramingGate.partlyOffscreen` refuses exactly that for a real target, and the fallback
    /// does not get to sneak it back in.
    @Test func aFallbackNearAnEdgeStaysInsideTheFrame() {
        for position in [NormalizedPoint(x: 0.01, y: 0.99), NormalizedPoint(x: 0.99, y: 0.01)] {
            let plan = FramingPlan(entries: [
                rejectedWithClick(1_000, .hitTestReturnedNothing, at: position),
            ])
            let frame = plan.resolvedWithPointerFallback(overrides: [], revision: revision)[0]
                .target!.frame
            #expect(frame.origin.x >= 0 && frame.origin.x + frame.size.width <= 1.0 + 1e-12)
            #expect(frame.origin.y >= 0 && frame.origin.y + frame.size.height <= 1.0 + 1e-12)
        }
    }

    /// An accepted click keeps the gate's rectangle. The fallback is for refusals only, and
    /// one that also replaced accepted targets would throw away the accessibility work.
    @Test func anAcceptedClickIsNotReplacedByTheFallback() {
        let plan = FramingPlan(entries: [framed(1_000, role: "AXButton")])
        let resolved = plan.resolvedWithPointerFallback(overrides: [], revision: revision)
        #expect(resolved[0].origin == .derived)
        #expect(resolved[0].target?.role == "AXButton")
    }

    /// **Precedence: authored, then the gate, then the pointer.** A fallback that overrode a
    /// reviewer's suppression would be the producer-value rule backwards — the reviewer said
    /// "no zoom here" and would get one anyway.
    @Test func anAuthoredSuppressionSurvivesTheFallback() {
        let plan = FramingPlan(entries: [rejectedWithClick(1_000, .tooLarge, at: click)])
        let resolved = plan.resolvedWithPointerFallback(
            overrides: [FramingOverride(epoch: epoch, instant: Nanoseconds(1_000),
                                        action: .suppress)],
            revision: revision)
        #expect(resolved[0].target == nil, "the reviewer said no zoom and got one")
        #expect(resolved[0].wasOverridden)
    }

    /// A refusal with no recorded click position has nothing to fall back to, and says so by
    /// staying refused rather than framing the centre of the screen.
    @Test func aRefusalWithNoClickPositionStaysRefused() {
        let plan = FramingPlan(entries: [rejected(1_000, .hitTestReturnedNothing)])
        #expect(plan.resolvedWithPointerFallback(overrides: [], revision: revision)[0]
                    .target == nil)
    }

    /// The camera's own call: with the fallback on, a plan of nothing but refusals still
    /// produces zooms — which is the whole point.
    @Test func aPlanOfOnlyRefusalsStillFramesSomethingWithTheFallbackOn() {
        let plan = FramingPlan(entries: [
            rejectedWithClick(1_000, .hitTestReturnedNothing, at: click),
            rejectedWithClick(2_000, .hitTestReturnedNothing, at: click),
        ])
        #expect(plan.framedClicks(with: [], pointerFallbackRevision: nil).isEmpty,
                "with the fallback off this plan frames nothing — the behaviour that shipped")
        #expect(plan.framedClicks(with: [], pointerFallbackRevision: revision).count == 2)
    }
}
