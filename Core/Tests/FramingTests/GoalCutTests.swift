import Foundation
import Geometry
import Project
import Testing
import Timeline
@testable import Framing

// Cutting to a goal: dead air first, then whole steps the model judged unnecessary, least
// needed first, until the target length is met — or a shortfall said plainly.
// `docs/design/2026-11-08-evidence-cut-and-the-agent-surface.md`, "Cutting to a goal".
//
// **A sixty-second recording anchored at 100 s**, steps at 104, 114, 124, 134 and 144 s, and a
// pointer moving every half second except from 150 s to 156 s — so the rules propose exactly one
// dead-air cut, 150.5–155.5 s, five seconds. With it accepted the recording plays 55 s.
// Removing a step keeps the second before the next press: step 3 removes 123–133 s.

private let epoch = BootEpoch(id: UUID(uuidString: "60A1C077-0000-4000-8000-0000000000D1")!)
private let second: Int64 = 1_000_000_000
private let anchor = EpochAnchor(epoch: epoch, hostTime: Nanoseconds(100 * second), wallClockUnixNanos: 0)

private func at(_ seconds: Double) -> HostInstant {
    HostInstant(epoch: epoch, hostTime: Nanoseconds(Int64((seconds * 1_000_000_000).rounded())))
}

private func range(_ from: Double, _ to: Double) -> HostRange {
    HostRange(epoch: epoch, start: at(from).hostTime, duration: Nanoseconds(at(to).hostTime.rawValue - at(from).hostTime.rawValue))
}

private let labels = ["Open Keynote", "Settings", "Change theme", "Export", "Done"]

private func steps(at origins: [Double] = [104, 114, 124, 134, 144], end: Double = 160) -> [RecordedStep] {
    origins.enumerated().map { index, origin in
        RecordedStep(origin: at(origin), end: at(index + 1 < origins.count ? origins[index + 1] : end),
                     number: index + 1, label: labels[index], role: "AXButton", application: "Keynote", frame: nil)
    }
}

/// The dead-air rows the Cuts tab would list for this recording: one, 150.5–155.5 s.
private func deadAir() throws -> [CutReview.Row] {
    var samples: [PointerSample] = []
    var t = 100.0
    var x = 0.1
    while t < 160 {
        if !(t > 150 && t < 156) {
            samples.append(PointerSample(instant: at(t), position: NormalizedPoint(x: x, y: 0.5), revision: GeometryRevision(id: 1)))
            x += 0.01
        }
        t += 0.5
    }
    let take = try TakeActivity(recording: range(100, 160), steps: steps(), pointer: samples, buttons: [],
                                shortcuts: [], speech: [], unobserved: [])
    return CutReview.listing(DeadAirProposer().proposals(for: take), dismissed: [], edit: uncut, anchor: anchor).rows
}

private let uncut = EditTimeline.whole(duration: Nanoseconds(60 * second))

private func verdict(_ step: Int, keep: Bool, _ reason: String = "a reason") -> GoalCut.Verdict {
    GoalCut.Verdict(step: step, keep: keep, reason: reason)
}

/// The model's answer for "show how to export": theme first, settings second, the rest kept.
private let exportGoal = [verdict(3, keep: false, "The theme change is cosmetic"),
                          verdict(2, keep: false, "Settings are not part of exporting"),
                          verdict(1, keep: true), verdict(4, keep: true), verdict(5, keep: true)]

private func plan(target seconds: Int64, verdicts: [GoalCut.Verdict] = exportGoal,
                  steps given: [RecordedStep] = steps(), dismissed: Set<CutProposal.Key> = []) throws -> GoalCut.Plan {
    GoalCut.plan(target: Nanoseconds(seconds * second), verdicts: verdicts, steps: given,
                 deadAir: try deadAir(), dismissed: dismissed, edit: uncut, anchor: anchor)
}

@Suite struct GoalCutTests {
    @Test func theFixtureHasOneDeadAirCutOfFiveSeconds() throws {
        #expect(try deadAir().map(\.proposal.removes) == [range(150.5, 155.5)])
    }

    /// The model is not needed when cutting the dead air already reaches the target.
    @Test func aTargetTheDeadAirAloneMeetsProposesNoStep() throws {
        let result = try plan(target: 55)
        #expect(result.outcome == .metByDeadAir)
        #expect(result.proposals.isEmpty)
        #expect(result.projected == Nanoseconds(55 * second))
    }

    @Test func theLeastNeededStepGoesFirstAndNoMoreThanTheTargetNeeds() throws {
        let result = try plan(target: 45)
        #expect(result.outcome == .met)
        #expect(result.proposals.map(\.duringStep) == [3], "step 3 alone takes 55 s to 45 s; step 2 is not needed")
        #expect(result.projected == Nanoseconds(45 * second))
    }

    @Test func moreStepsGoInTheModelsOrderUntilTheTargetIsMet() throws {
        let result = try plan(target: 40)
        #expect(result.outcome == .met)
        #expect(Set(result.proposals.compactMap(\.duringStep)) == [2, 3])
        #expect(result.proposals.map(\.duringStep) == [2, 3], "listed in time order, whatever order they were chosen in")
        #expect(result.projected == Nanoseconds(35 * second))
    }

    /// Steps the model called necessary are never cut to make a number, and the gap is said.
    @Test func aTargetOnlyNecessaryStepsCouldMeetIsAShortfallSaidInSeconds() throws {
        let result = try plan(target: 20)
        #expect(result.outcome == .short(by: Nanoseconds(15 * second)), "35 s is the shortest without a necessary step")
        #expect(result.proposals.count == 2)
    }

    @Test func aStepCutKeepsTheSecondBeforeTheNextPressAndCarriesItsEvidence() throws {
        let cut = try #require(try plan(target: 45).proposals.first)
        #expect(cut.reason == .outsideTheGoal)
        #expect(cut.removes == range(123, 133), "from a second before its own press to a second before the next")
        #expect(cut.quiet == range(124, 134), "it rests on the step itself, press to press")
        #expect(cut.openedBy == .press(step: 3) && cut.closedBy == .press(step: 4))
        #expect(cut.rationale == "The theme change is cosmetic")
    }

    @Test func theLastStepRunsToTheRecordingsEnd() throws {
        let cut = try #require(try plan(target: 50, verdicts: [verdict(5, keep: false, "Done is a formality")]).proposals.first)
        #expect(cut.removes == range(143, 160))
        #expect(cut.closedBy == .recordingEnd)
    }

    /// The lead-in never reaches back past the previous press, or the cut would take the end of
    /// a step the model kept.
    @Test func theLeadInNeverReachesBackPastThePreviousPress() throws {
        let close = steps(at: [104, 104.5, 124, 134, 144])
        let cut = try #require(try plan(target: 45, verdicts: [verdict(2, keep: false, "x")], steps: close).proposals.first)
        #expect(cut.removes == range(104, 123))
    }

    @Test func whatTheModelGotWrongIsRefusedByNameAndNothingElseIsGuessed() throws {
        let result = try plan(target: 45, verdicts: [verdict(9, keep: false, "x"), verdict(3, keep: false, "first"),
                                                     verdict(3, keep: false, "again"), verdict(2, keep: false, "  ")])
        #expect(result.refusals == [.noSuchStep(9), .judgedTwice(3), .noReason(2)])
        #expect(result.unjudged == [1, 4, 5], "steps the model said nothing about are kept, and listed")
        #expect(result.proposals.map(\.rationale) == ["first"], "the first verdict on a step counts")
    }

    /// A step a person already kept is not offered again; the next one goes instead.
    @Test func aStepAPersonKeptIsSkippedForTheNextOne() throws {
        let kept = try #require(try plan(target: 45).proposals.first).key
        let result = try plan(target: 45, dismissed: [kept])
        #expect(result.proposals.map(\.duringStep) == [2])
    }

    @Test func askingAgainGivesTheSameKeysSoAKeepHolds() throws {
        #expect(try plan(target: 40).proposals.map(\.key) == (try plan(target: 40)).proposals.map(\.key))
    }
}
