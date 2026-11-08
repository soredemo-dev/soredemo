import Timeline

/// Cutting a recording to a person's goal and length: **the model judges, the code measures.**
///
/// A language model is asked one thing it is good at — which steps a stated goal does not need,
/// least needed first, with a sentence each — and nothing it is bad at: no time, no length, no
/// arithmetic. This plans the cut from that answer:
///
/// 1. **Dead air first.** If the rules' own proposals already bring the edit to the target, no
///    step is proposed and the model's answer is not used.
/// 2. **Then whole steps, in the model's order**, each removed from a second before its press to a
///    second before the next press, so the viewer still sees the pointer travel to what comes
///    next — until the projected length meets the target.
/// 3. **Never a step the model called necessary, and never one a person kept.** If the target is
///    still out of reach, the plan says by how much rather than cutting further.
///
/// Every verdict is checked first (`Refusal`); a step the model said nothing about is kept. See
/// `docs/design/2026-11-08-evidence-cut-and-the-agent-surface.md`, "Cutting to a goal".
public enum GoalCut {
    /// Kept before the next press, so a removal does not land on the click itself. Uncalibrated,
    /// like the dead-air breath (`ARCHITECTURE.md` D4).
    public static let leadIn = Nanoseconds(1_000_000_000)

    /// One step, as the model judged it.
    public struct Verdict: Hashable, Sendable {
        public let step: Int
        public let keep: Bool
        public let reason: String

        public init(step: Int, keep: Bool, reason: String) {
            self.step = step
            self.keep = keep
            self.reason = reason
        }
    }

    /// What the model got wrong, by name. Each refused verdict is dropped, never repaired.
    public enum Refusal: Hashable, Sendable {
        case noSuchStep(Int)
        /// A second verdict on one step; the first one counts.
        case judgedTwice(Int)
        /// A step proposed for cutting with no reason — a cut a person cannot check.
        case noReason(Int)
    }

    public enum Outcome: Hashable, Sendable {
        /// The rules' dead-air cuts alone reach the target; no step needs to go.
        case metByDeadAir
        case met
        /// Still this much over, without cutting a step the model called necessary.
        case short(by: Nanoseconds)
    }

    public struct Plan: Sendable {
        /// The steps to cut, in time order.
        public let proposals: [CutProposal]
        public let outcome: Outcome
        /// How long the edit would play with the dead air and these steps cut.
        public let projected: Nanoseconds
        public let refusals: [Refusal]
        /// Steps the model returned no verdict for, which are kept.
        public let unjudged: [Int]
    }

    public static func plan(target: Nanoseconds, verdicts: [Verdict], steps: [RecordedStep],
                            deadAir: [CutReview.Row], dismissed: Set<CutProposal.Key>,
                            edit: EditTimeline, anchor: EpochAnchor) -> Plan {
        let (accepted, refusals) = validate(verdicts, steps: steps)
        // Said nothing about — not "refused": a refused verdict is in `refusals`, and listing it
        // here too would count one step two ways.
        let unjudged = steps.map(\.number).filter { number in !verdicts.contains { $0.step == number } }

        var working = CutReview.acceptingAll(deadAir, in: edit)
        guard working.outputDuration.rawValue > target.rawValue else {
            return Plan(proposals: [], outcome: .metByDeadAir, projected: working.outputDuration,
                        refusals: refusals, unjudged: unjudged)
        }

        var chosen: [CutProposal] = []
        for verdict in accepted where !verdict.keep {
            guard working.outputDuration.rawValue > target.rawValue else { break }
            guard let index = steps.firstIndex(where: { $0.number == verdict.step }),
                  let proposal = proposal(cutting: index, of: steps, reason: verdict.reason),
                  !dismissed.contains(proposal.key),
                  let source = proposal.removedSource(from: anchor) else { continue }
            working = working.removing(sourceRange: source)
            chosen.append(proposal)
        }
        let over = working.outputDuration.rawValue - target.rawValue
        return Plan(proposals: chosen.sorted { $0.quiet.start < $1.quiet.start },
                    outcome: over > 0 ? .short(by: Nanoseconds(over)) : .met,
                    projected: working.outputDuration, refusals: refusals, unjudged: unjudged)
    }

    /// The verdicts that stand, in the model's order, and why the others do not.
    static func validate(_ verdicts: [Verdict], steps: [RecordedStep]) -> ([Verdict], [Refusal]) {
        let numbers = Set(steps.map(\.number))
        var seen: Set<Int> = []
        var accepted: [Verdict] = []
        var refusals: [Refusal] = []
        for verdict in verdicts {
            guard numbers.contains(verdict.step) else {
                refusals.append(.noSuchStep(verdict.step))
                continue
            }
            guard seen.insert(verdict.step).inserted else {
                refusals.append(.judgedTwice(verdict.step))
                continue
            }
            if !verdict.keep && verdict.reason.trimmingWhitespace.isEmpty {
                refusals.append(.noReason(verdict.step))
                continue
            }
            accepted.append(verdict)
        }
        return (accepted, refusals)
    }

    /// The step at `index`, as a cut: from a lead-in before its press — never before the previous
    /// press — to a lead-in before the next press, or to the recording's end for the last step.
    private static func proposal(cutting index: Int, of steps: [RecordedStep], reason: String) -> CutProposal? {
        let step = steps[index]
        let floor = index > 0 ? steps[index - 1].origin.hostTime.rawValue : Int64.min
        let start = max(step.origin.hostTime.rawValue - leadIn.rawValue, floor)
        let isLast = index + 1 == steps.count
        let end = isLast ? step.end.hostTime.rawValue : step.end.hostTime.rawValue - leadIn.rawValue
        guard end > start, step.end.hostTime.rawValue > step.origin.hostTime.rawValue else { return nil }
        let epoch = step.origin.epoch
        return CutProposal(
            reason: .outsideTheGoal,
            quiet: HostRange(epoch: epoch, start: step.origin.hostTime,
                             duration: Nanoseconds(step.end.hostTime.rawValue - step.origin.hostTime.rawValue)),
            removes: HostRange(epoch: epoch, start: Nanoseconds(start), duration: Nanoseconds(end - start)),
            openedBy: .press(step: step.number),
            closedBy: isLast ? .recordingEnd : .press(step: steps[index + 1].number),
            duringStep: step.number,
            rationale: reason.trimmingWhitespace)
    }
}

private extension String {
    /// Spaces and line breaks off both ends, without Foundation — this module imports none.
    var trimmingWhitespace: String {
        var view = Substring(self)
        while let first = view.first, first.isWhitespace { view = view.dropFirst() }
        while let last = view.last, last.isWhitespace { view = view.dropLast() }
        return String(view)
    }
}
