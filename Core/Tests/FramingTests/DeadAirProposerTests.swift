import Foundation
import Geometry
import Project
import Testing
import Timeline
@testable import Framing

// Dead air: a span where nothing was pressed, clicked, typed, said or moved, proposed for removal
// with a breath kept on each side. `docs/design/2026-11-08-evidence-cut-and-the-agent-surface.md`.
//
// **The recording starts at 100 s**, so a span measured from zero rather than from the recording
// would show, and every expected bound below is a literal worked out from the fixture's own
// numbers — 0.5 s kept after the last thing that happened and 0.5 s before the next.

private let epoch = BootEpoch(id: UUID(uuidString: "D3ADA100-0000-4000-8000-000000000001")!)
private let otherBoot = BootEpoch(id: UUID(uuidString: "0BADB007-0000-4000-8000-000000000002")!)
private let revision = GeometryRevision(id: 4)

private func at(_ seconds: Double, in boot: BootEpoch = epoch) -> HostInstant {
    HostInstant(epoch: boot, hostTime: Nanoseconds(Int64((seconds * 1_000_000_000).rounded())))
}

private func range(_ from: Double, _ to: Double) -> HostRange {
    HostRange(epoch: epoch, start: at(from).hostTime, duration: Nanoseconds(at(to).hostTime.rawValue - at(from).hostTime.rawValue))
}

private func step(_ number: Int, _ seconds: Double, until end: Double) -> RecordedStep {
    RecordedStep(origin: at(seconds), end: at(end), number: number, label: "Step \(number)",
                 role: "AXButton", application: "Finder", frame: nil)
}

private func pointer(_ seconds: Double, x: Double, y: Double = 0.5) -> PointerSample {
    PointerSample(instant: at(seconds), position: NormalizedPoint(x: x, y: y), revision: revision)
}

private func click(_ seconds: Double) -> ButtonEvent {
    ButtonEvent(instant: at(seconds), position: NormalizedPoint(x: 0.3, y: 0.3), revision: revision,
                button: .left, phase: .down)
}

/// Two presses, at 104 s and 115 s, in a recording from 100 s to 120 s; the pointer is still
/// throughout. Its quiet spans are 100–104, 104–115 and 115–120.
private func take(pointer samples: [PointerSample] = [],
                  clicks: [ButtonEvent] = [],
                  shortcuts: [KeySample] = [],
                  speech: [HostRange] = [],
                  unobserved: [HostRange] = []) throws -> TakeActivity {
    try TakeActivity(recording: range(100, 120),
                     steps: [step(1, 104, until: 115), step(2, 115, until: 120)],
                     pointer: samples, buttons: clicks, shortcuts: shortcuts,
                     speech: speech, unobserved: unobserved)
}

private func proposals(_ take: TakeActivity) -> [CutProposal] {
    DeadAirProposer().proposals(for: take)
}

@Suite struct DeadAirProposerTests {
    @Test func aQuietSpanBetweenTwoStepsKeepsABreathOnEachSide() throws {
        let found = proposals(try take()).filter { $0.openedBy == .press(step: 1) }
        try #require(found.count == 1)
        #expect(found[0].reason == .deadAir)
        #expect(found[0].quiet == range(104, 115), "the whole quiet span is the evidence")
        #expect(found[0].removes == range(104.5, 114.5), "half a second kept after step 1 and before step 2")
        #expect(found[0].closedBy == .press(step: 2))
        #expect(found[0].duringStep == 1)
    }

    @Test func theQuietBeforeTheFirstStepIsRemovedFromTheRecordingsStart() throws {
        let found = proposals(try take()).filter { $0.openedBy == .recordingStart }
        try #require(found.count == 1)
        #expect(found[0].removes == range(100, 103.5), "nothing came before it, so nothing is kept before it")
        #expect(found[0].closedBy == .press(step: 1))
        #expect(found[0].duringStep == nil, "no step had begun")
    }

    @Test func theQuietAfterTheLastStepIsRemovedToTheRecordingsEnd() throws {
        let found = proposals(try take()).filter { $0.closedBy == .recordingEnd }
        try #require(found.count == 1)
        #expect(found[0].removes == range(115.5, 120))
        #expect(found[0].openedBy == .press(step: 2))
        #expect(found[0].duringStep == 2)
    }

    @Test func proposalsComeInTimeOrder() throws {
        let starts = proposals(try take()).map(\.removes.start.rawValue)
        #expect(starts.count == 3)
        #expect(starts == starts.sorted())
    }

    @Test func aPauseShorterThanTheMinimumIsNotDeadAir() throws {
        // Steps at 104 and 105.9: a 1.9 s pause, under the 2 s minimum.
        let take = try TakeActivity(recording: range(100, 107),
                                    steps: [step(1, 104, until: 105.9), step(2, 105.9, until: 107)],
                                    pointer: [], buttons: [], shortcuts: [], speech: [], unobserved: [])
        #expect(proposals(take).allSatisfy { $0.openedBy != .press(step: 1) })
    }

    @Test func aPauseOfExactlyTheMinimumIsDeadAir() throws {
        let take = try TakeActivity(recording: range(100, 107),
                                    steps: [step(1, 104, until: 106), step(2, 106, until: 107)],
                                    pointer: [], buttons: [], shortcuts: [], speech: [], unobserved: [])
        #expect(proposals(take).contains { $0.openedBy == .press(step: 1) && $0.removes == range(104.5, 105.5) })
    }

    @Test func movingThePointerIsSomethingHappening() throws {
        // The pointer moves at 108 and 111, splitting 104–115 into 4 s, 3 s and 4 s.
        let moved = try take(pointer: [pointer(107.9, x: 0.2), pointer(108, x: 0.4),
                                       pointer(111, x: 0.6)])
        let between = proposals(moved).filter { $0.duringStep == 1 }
        #expect(between.map(\.openedBy) == [.press(step: 1), .pointerMoved, .pointerMoved])
        #expect(between.map(\.removes) == [range(104.5, 107.5), range(108.5, 110.5), range(111.5, 114.5)])
    }

    @Test func aPointerThatOnlyTremblesIsStill() throws {
        // Four thousandths of the display between samples: under the stillness radius.
        let trembling = try take(pointer: [pointer(106, x: 0.500), pointer(109, x: 0.504), pointer(112, x: 0.500)])
        let between = proposals(trembling).filter { $0.duringStep == 1 }
        #expect(between.map(\.removes) == [range(104.5, 114.5)])
    }

    @Test func aSlowDriftMadeOfTremblesHasMoved() throws {
        // Three thousandths per sample — each under the radius — six thousandths from rest by 108.
        let drifting = try take(pointer: [pointer(106, x: 0.500), pointer(107, x: 0.503), pointer(108, x: 0.506)])
        let between = proposals(drifting).filter { $0.duringStep == 1 }
        #expect(between.map(\.closedBy) == [.pointerMoved, .press(step: 2)])
        #expect(between.map(\.removes) == [range(104.5, 107.5), range(108.5, 114.5)])
    }

    @Test func theClickUnderAStepIsNamedAsTheStep() throws {
        // The button-down recorded at step 2's own instant is step 2's press.
        let found = proposals(try take(clicks: [click(115)])).filter { $0.closedBy == .recordingEnd }
        #expect(found.map(\.openedBy) == [.press(step: 2)])
    }

    @Test func whatHappenedAfterTheRecordingEndedIsNotInIt() throws {
        let late = try take(shortcuts: [KeySample(instant: at(125), shortcut: "⌘Q")])
        let last = proposals(late).last
        #expect(last?.closedBy == .recordingEnd)
        #expect(last?.removes == range(115.5, 120))
    }

    @Test func aPointerOnAnotherDisplayRevisionHasMoved() throws {
        let rearranged = PointerSample(instant: at(109), position: NormalizedPoint(x: 0.5, y: 0.5),
                                       revision: GeometryRevision(id: 5))
        let moved = try take(pointer: [pointer(106, x: 0.5), rearranged])
        #expect(proposals(moved).contains { $0.openedBy == .pointerMoved && $0.duringStep == 1 })
    }

    @Test func narrationIsNotDeadAir() throws {
        // Speaking from 106 to 113 leaves 104–106 (2 s) and 113–115 (2 s) quiet.
        let narrated = try take(speech: [range(106, 113)])
        let between = proposals(narrated).filter { $0.duringStep == 1 }
        #expect(between.map(\.removes) == [range(104.5, 105.5), range(113.5, 114.5)])
        #expect(between.map(\.closedBy) == [.speech, .press(step: 2)])
        #expect(between.map(\.openedBy) == [.press(step: 1), .speech])
    }

    @Test func aSpanNobodyCouldSeeIsNotQuiet() throws {
        // Secure input from 105 to 114: the observer emitted nothing, which is not stillness.
        let hidden = try take(unobserved: [range(105, 114)])
        #expect(proposals(hidden).allSatisfy { $0.duringStep != 1 },
                "1 s either side is under the minimum, and the hidden middle is not proposed")
    }

    @Test func aClickOnSomethingUnnamedIsStillSomethingHappening() throws {
        // A press at 109.5 that named no element made no step, and still happened.
        let clicked = try take(clicks: [click(109.5)])
        let between = proposals(clicked).filter { $0.duringStep == 1 }
        #expect(between.map(\.closedBy) == [.click, .press(step: 2)])
        #expect(between.map(\.removes) == [range(104.5, 109), range(110, 114.5)])
    }

    @Test func aShortcutIsSomethingHappening() throws {
        let typed = try take(shortcuts: [KeySample(instant: at(109.5), shortcut: "⌘S")])
        let between = proposals(typed).filter { $0.duringStep == 1 }
        #expect(between.map(\.closedBy) == [.shortcut, .press(step: 2)])
    }

    @Test func aRecordingInWhichNothingHappenedProposesNothing() throws {
        let empty = try TakeActivity(recording: range(100, 130), steps: [], pointer: [], buttons: [],
                                     shortcuts: [], speech: [], unobserved: [])
        #expect(proposals(empty).isEmpty, "removing all of it is not an edit anyone could accept")
    }

    @Test func anInstantFromAnotherBootIsRefusedByName() throws {
        let foreign = KeySample(instant: at(109, in: otherBoot), shortcut: "⌘S")
        #expect(throws: TakeActivity.Refusal.fromAnotherBoot("shortcut")) {
            try take(shortcuts: [foreign])
        }
    }

    @Test(arguments: ["step", "pointer", "button", "shortcut", "speech", "unobserved"])
    func everyKindOfInstantIsCheckedForItsBoot(_ kind: String) throws {
        let foreignRange = HostRange(epoch: otherBoot, start: at(109).hostTime, duration: Nanoseconds(1_000))
        let foreignStep = RecordedStep(origin: at(109, in: otherBoot), end: at(110, in: otherBoot), number: 9,
                                       label: "Elsewhere", role: "AXButton", application: nil, frame: nil)
        #expect(throws: TakeActivity.Refusal.fromAnotherBoot(kind)) {
            try TakeActivity(recording: range(100, 120),
                             steps: kind == "step" ? [foreignStep] : [],
                             pointer: kind == "pointer" ? [PointerSample(instant: at(109, in: otherBoot),
                                                                         position: NormalizedPoint(x: 0.5, y: 0.5),
                                                                         revision: revision)] : [],
                             buttons: kind == "button" ? [ButtonEvent(instant: at(109, in: otherBoot),
                                                                      position: NormalizedPoint(x: 0.5, y: 0.5),
                                                                      revision: revision, button: .left,
                                                                      phase: .down)] : [],
                             shortcuts: kind == "shortcut" ? [KeySample(instant: at(109, in: otherBoot),
                                                                        shortcut: "⌘S")] : [],
                             speech: kind == "speech" ? [foreignRange] : [],
                             unobserved: kind == "unobserved" ? [foreignRange] : [])
        }
    }

    @Test func reDerivingTheSameTakeGivesTheSameKeys() throws {
        let first = proposals(try take(speech: [range(106, 113)])).map(\.key)
        let second = proposals(try take(speech: [range(106, 113)])).map(\.key)
        #expect(first == second && first.count == 4)
        #expect(Set(first).count == first.count, "every proposal has its own key")
    }

    @Test func aDismissedProposalStaysDismissedAfterReDerivation() throws {
        // The producer-value rule: a person's decision outranks a producer's re-run.
        let all = proposals(try take())
        let dismissed: Set<CutProposal.Key> = [all[1].key]
        let pending = CutProposals.pending(proposals(try take()), dismissed: dismissed)
        #expect(pending.map(\.key) == [all[0].key, all[2].key])
    }

    @Test func aDismissalOfAnotherSpanDismissesNothingHere() throws {
        let elsewhere = try #require(proposals(try take(speech: [range(106, 113)])).first { $0.openedBy == .speech }).key
        let all = proposals(try take())
        #expect(CutProposals.pending(all, dismissed: [elsewhere]).count == all.count)
    }
}
