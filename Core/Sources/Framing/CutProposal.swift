import Timeline

/// A span of the take proposed for removal, with what was measured on each side of it.
///
/// **Proposed, never applied.** Nothing in the package writes an `EditTimeline` from one: a person
/// accepts a proposal in the editor, and that acceptance is an ordinary authored cut. See
/// `docs/design/2026-11-08-evidence-cut-and-the-agent-surface.md`.
///
/// **The evidence is the type, not a field beside it.** `quiet`, `openedBy` and `closedBy` are
/// non-optional, so a proposal that cannot say what bounded its span cannot be built; the
/// initialiser is internal, so only a producer in this module builds one.
public struct CutProposal: Hashable, Sendable {
    /// Why the span is proposed. Closed: a reason the review list cannot name is one it cannot
    /// show a person, so a new reason is a new case here, not a string.
    public enum Reason: String, Hashable, Sendable, Codable {
        /// Nothing was pressed, clicked, typed, said or moved, and the observer was watching.
        case deadAir
        /// A whole step the on-device model judged unnecessary for a person's stated goal, cut
        /// because the recording was still longer than they asked for (`GoalCut`).
        case outsideTheGoal
    }

    /// What ended the activity before a quiet span, or began the activity after it.
    public enum Boundary: Hashable, Sendable {
        case recordingStart
        case recordingEnd
        /// A press that made a step, by the step's number.
        case press(step: Int)
        /// A press on something that named no element, so made no step.
        case click
        case shortcut
        case pointerMoved
        case speech
        /// A span the observer could not see — secure input, a tap the system disabled.
        case unobserved
    }

    /// Identifies a proposal across re-derivations of the same take: its reason and the instant
    /// its quiet span began. A dismissal is stored against this, never against an array index.
    public struct Key: Hashable, Sendable, Codable {
        public let reason: Reason
        public let quietStart: HostInstant

        /// Public so a saved dismissal can be built and compared; a key that matches no proposal
        /// dismisses nothing, so a made-up one is harmless.
        public init(reason: Reason, quietStart: HostInstant) {
            self.reason = reason
            self.quietStart = quietStart
        }

        /// In a fixed order — boot, instant, reason — for writing to a file. A `Set` encodes in
        /// hash order, which differs between processes, so the same dismissals would save as
        /// different bytes and every open-and-save would read as a change.
        public static func fileOrder(_ keys: Set<Key>) -> [Key] {
            keys.sorted {
                ($0.quietStart.epoch.id.uuidString, $0.quietStart.hostTime.rawValue, $0.reason.rawValue)
                    < ($1.quietStart.epoch.id.uuidString, $1.quietStart.hostTime.rawValue, $1.reason.rawValue)
            }
        }
    }

    public let reason: Reason
    /// The span the proposal rests on: for dead air, the whole span in which nothing happened;
    /// for a step outside the goal, the step from its press to the next one's.
    public let quiet: HostRange
    /// The part of `quiet` proposed for removal: smaller by the breath kept on each side.
    public let removes: HostRange
    public let openedBy: Boundary
    public let closedBy: Boundary
    /// The step in progress when the quiet began, by number; `nil` before the first step.
    public let duringStep: Int?
    /// Why a model proposed it, in its own words, already checked to be non-empty; `nil` for a
    /// rule, whose reason is the measurement above.
    public let rationale: String?

    public var key: Key { Key(reason: reason, quietStart: HostInstant(epoch: quiet.epoch, hostTime: quiet.start)) }

    init(reason: Reason, quiet: HostRange, removes: HostRange, openedBy: Boundary, closedBy: Boundary,
         duringStep: Int?, rationale: String? = nil) {
        self.reason = reason
        self.quiet = quiet
        self.removes = removes
        self.openedBy = openedBy
        self.closedBy = closedBy
        self.duringStep = duringStep
        self.rationale = rationale
    }
}

/// Something that reads a take and proposes cuts. A new producer is a new conformance; the review
/// list, the CLI and an agent see every producer's proposals the same way.
public protocol CutProposer: Sendable {
    func proposals(for take: TakeActivity) -> [CutProposal]
}

public enum CutProposals {
    /// The proposals a person has not dismissed. **A dismissal outranks a re-derivation**: the
    /// producer-value rule, for a value whose authored half is a "no".
    public static func pending(_ proposals: [CutProposal], dismissed: Set<CutProposal.Key>) -> [CutProposal] {
        proposals.filter { !dismissed.contains($0.key) }
    }
}
