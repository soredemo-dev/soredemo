import Timeline

/// The proposals a person still has to decide about, placed on the recording's own clock.
///
/// **Derived from the timeline, never from a remembered acceptance.** A proposal whose span is
/// already gone from the edit — accepted, or cut by hand — has nothing left to decide and leaves
/// the list; undo the cut and it is back, because the timeline is the one record of what was
/// removed and the undo history already orders it. The only thing remembered is a dismissal, which
/// is a person's "no" and outranks every re-derivation (`CutProposals.pending`).
///
/// **Every proposal goes exactly one way**, and each way is counted, so the counts sum to the
/// proposals given: a proposal that silently vanished from the list would read as one that was
/// never made.
public enum CutReview {
    /// One proposal as the list shows it.
    public struct Row: Hashable, Sendable {
        public let proposal: CutProposal
        /// What accepting it removes, in nanoseconds from the recording's start — the clock
        /// `EditTimeline` cuts in.
        public let source: Range<Int64>
        /// `.whole` or `.partly`; a `.gone` proposal is not a row.
        public let survival: EditTimeline.Survival
    }

    public struct Listing: Hashable, Sendable {
        /// In the order the proposals were given, which a producer gives in time order.
        public let rows: [Row]
        /// Proposals whose whole span the edit has already removed.
        public let alreadyCut: Int
        /// Proposals a person dismissed.
        public let dismissed: Int
        /// Proposals from a boot the anchor is not in, which no offset can place.
        public let unplaceable: Int
    }

    public static func listing(_ proposals: [CutProposal], dismissed: Set<CutProposal.Key>,
                               edit: EditTimeline, anchor: EpochAnchor) -> Listing {
        var rows: [Row] = []
        var alreadyCut = 0
        var dismissedCount = 0
        var unplaceable = 0
        for proposal in proposals {
            // A dismissal first: a "no" is the person's whether or not the span still plays.
            if dismissed.contains(proposal.key) {
                dismissedCount += 1
                continue
            }
            guard let source = proposal.removedSource(from: anchor) else {
                unplaceable += 1
                continue
            }
            switch edit.survival(ofSource: source) {
            case .gone: alreadyCut += 1
            case let survival: rows.append(Row(proposal: proposal, source: source, survival: survival))
            }
        }
        return Listing(rows: rows, alreadyCut: alreadyCut, dismissed: dismissedCount, unplaceable: unplaceable)
    }

    /// The edit with the row's span removed. **The only way a proposal becomes a cut**, and it is
    /// an ordinary one: the caller records it in the same undo history as every other edit.
    /// Removing a span that is partly cut already removes what is left of it, nothing more.
    public static func accepting(_ row: Row, in edit: EditTimeline) -> EditTimeline {
        edit.removing(sourceRange: row.source)
    }

    /// Every row accepted at once — one decision, so the caller records it as one undo step.
    ///
    /// **Back to front**, for `SilenceFinder.removing`'s reason: the ranges are in source time
    /// and would land the same in any order, but cutting from the end leaves the earlier clips'
    /// ids untouched, so a selection a person made survives.
    public static func acceptingAll(_ rows: [Row], in edit: EditTimeline) -> EditTimeline {
        rows.sorted { $0.source.lowerBound > $1.source.lowerBound }
            .reduce(edit) { $0.removing(sourceRange: $1.source) }
    }

    /// How much the rows would remove from what still plays — the number a person reads before
    /// pressing "cut all". A partly cut row counts only what is left of it.
    public static func remaining(_ rows: [Row], in edit: EditTimeline) -> Nanoseconds {
        Nanoseconds(edit.outputDuration.rawValue - acceptingAll(rows, in: edit).outputDuration.rawValue)
    }
}

extension CutProposal {
    /// What this proposal removes, as nanoseconds from the anchor — `nil` when the anchor is in
    /// another boot, where a subtraction would produce a plausible, meaningless time.
    public func removedSource(from anchor: EpochAnchor) -> Range<Int64>? {
        guard removes.epoch == anchor.epoch else { return nil }
        let start = removes.start.rawValue - anchor.hostTime.rawValue
        return start..<(start + removes.duration.rawValue)
    }
}
