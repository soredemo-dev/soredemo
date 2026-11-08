import Compositing
import Foundation
import Framing
import Observation
import Overlays
import Timeline

/// The cut proposals for one recording, for the review list.
///
/// **It proposes and never cuts.** The timeline model owns the edit and its history; this holds
/// what the producers derived and hands a person's decision to `TimelineEditorModel.acceptCut` or
/// `dismissCut`. What is still pending is computed from the edit every time it is asked
/// (`CutReview.listing`), so an undo is reflected without this model being told.
///
/// **The producer is injected**, so a second producer — a repeated attempt, a model asked for a
/// goal — is a new `CutProposer` and nothing here changes. See
/// `docs/design/2026-11-08-evidence-cut-and-the-agent-surface.md`.
@Observable
final class CutProposalsModel {
    /// Where the "something was said" spans came from, said beside the list: without a
    /// transcript, a pause filled by narration is only kept because it made a sound.
    enum Hearing: Equatable {
        /// The transcript's segments: what was said.
        case transcript
        /// The waveform's non-silent stretches: anything that made a sound, speech or not.
        case sound
        /// Neither was available, so narration was not considered at all.
        case nothing
    }

    private(set) var proposals: [CutProposal] = []
    private(set) var anchor: EpochAnchor?
    private(set) var hearing = Hearing.nothing
    /// Why the log could not be read, or `nil`. Not shown as "no proposals": "nothing was quiet"
    /// and "the file could not be opened" are different facts.
    private(set) var failure: String?

    @ObservationIgnored private let proposer: any CutProposer

    init(proposer: any CutProposer = DeadAirProposer()) {
        self.proposer = proposer
    }

    @ObservationIgnored private var log: (url: URL, anchor: EpochAnchor, duration: Nanoseconds)?
    @ObservationIgnored private var transcript: Transcript?
    @ObservationIgnored private var silences: [SilenceFinder.Span]?

    /// The recording to propose cuts for — called once it is open, beside the steps, from the
    /// same log and anchor. Without a log, an anchor or a length there is nothing to derive from.
    func load(observationLogAt url: URL?, anchor: EpochAnchor?, duration: Nanoseconds?) {
        self.anchor = anchor
        log = url.flatMap { url in anchor.flatMap { anchor in duration.map { (url, anchor, $0) } } }
        derive()
    }

    /// What was heard, which arrives after the recording opens and changes when it is
    /// transcribed. **The transcript wins over the waveform**: it says what was SAID, and a sound
    /// is only a guess at that.
    func hear(transcript: Transcript?, silences: [SilenceFinder.Span]?) {
        self.transcript = transcript
        self.silences = silences
        derive()
    }

    private func derive() {
        guard let log else {
            proposals = []
            hearing = .nothing
            failure = nil
            return
        }
        let speech: [Range<Int64>]
        if let transcript, !transcript.segments.isEmpty {
            speech = transcript.segments.map { $0.start.rawValue..<max($0.start.rawValue, $0.end.rawValue) }
            hearing = .transcript
        } else if let silences {
            speech = SilenceFinder.sounding(outside: silences, duration: log.duration)
            hearing = .sound
        } else {
            speech = []
            hearing = .nothing
        }
        do {
            let take = try TakeActivityReader.take(fromObservationLogAt: log.url, anchor: log.anchor,
                                                   duration: log.duration, speech: speech)
            proposals = proposer.proposals(for: take)
            failure = nil
        } catch {
            proposals = []
            failure = "\(error)"
        }
    }

    /// What is still to decide, against the edit as it stands. `nil` without an anchor, which
    /// is a recording with no log header: nothing can be placed, and that is not "no proposals".
    func listing(edit: EditTimeline, dismissed: Set<CutProposal.Key>) -> CutReview.Listing? {
        anchor.map { CutReview.listing(proposals, dismissed: dismissed, edit: edit, anchor: $0) }
    }
}
