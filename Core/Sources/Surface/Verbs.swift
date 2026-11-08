import Framing
import Timeline

/// What each verb answers, from an opened project. **Pure over `ProjectReading`**: no file is
/// named here, so every answer is tested against a fixture reader.
///
/// **The proposals come from the same functions the editor's Cuts tab calls** —
/// `DeadAirProposer`, `CutReview.listing` — so a terminal and the editor cannot disagree about
/// what is pending except through what each one heard, which both say.
enum Verbs {
    static func listing() -> VerbsResult {
        VerbsResult(verbs: Verb.allCases.map {
            VerbsResult.Row(name: $0.rawValue, kind: $0.kind, summary: $0.summary, usage: $0.usage)
        }, note: "Every verb reads or proposes. None accepts a cut, changes a project or publishes: a person does that, in the editor.")
    }

    static func status(_ project: OpenedProject, reader: any ProjectReading) throws -> StatusResult {
        guard let log = project.log else {
            return StatusResult(project: project.name, media: project.mediaFilename, observationLog: nil,
                                durationNanos: nil, durationFrom: nil, outputDurationNanos: project.edit?.outputDuration.rawValue,
                                edited: project.edit != nil, steps: nil, clicks: nil, framedClicks: nil, proposals: nil)
        }
        let take = try reader.take(of: log, speech: [])
        let plan = try reader.framing(of: log)
        let listing = review(DeadAirProposer().proposals(for: take), project, log)
        let edit = project.edit ?? .whole(duration: log.duration)
        return StatusResult(
            project: project.name, media: project.mediaFilename, observationLog: log.url.lastPathComponent,
            durationNanos: log.duration.rawValue, durationFrom: "observationLogTrailer",
            outputDurationNanos: edit.outputDuration.rawValue, edited: project.edit != nil,
            steps: take.steps.count, clicks: plan.entries.count,
            framedClicks: plan.entries.filter { $0.decision.rejection == nil }.count,
            proposals: .init(pending: listing.rows.count, alreadyCut: listing.alreadyCut,
                             dismissed: listing.dismissed, unplaceable: listing.unplaceable))
    }

    static func steps(_ project: OpenedProject, reader: any ProjectReading) throws -> StepsResult {
        let log = try requireLog(project)
        let take = try reader.take(of: log, speech: [])
        return StepsResult(steps: take.steps.map { step in
            StepsResult.Row(number: step.number, label: step.label, role: step.role,
                            application: step.application,
                            span: TimeSpan(startNanos: offset(step.origin, log), endNanos: offset(step.end, log)))
        })
    }

    static func framing(_ project: OpenedProject, reader: any ProjectReading) throws -> FramingResult {
        let log = try requireLog(project)
        let rows = try reader.framing(of: log).entries.map { entry in
            switch entry.decision {
            case .framed(let target):
                FramingResult.Row(atNanos: offset(entry.instant, log), framed: true, role: target.role, refusedBecause: nil)
            case .rejected(let reason):
                FramingResult.Row(atNanos: offset(entry.instant, log), framed: false, role: nil, refusedBecause: reason.rawValue)
            }
        }
        return FramingResult(clicks: rows, framed: rows.filter(\.framed).count, refused: rows.filter { !$0.framed }.count)
    }

    static func proposals(_ project: OpenedProject, heard: Heard, reader: any ProjectReading) throws -> ProposalsResult {
        let log = try requireLog(project)
        let speech: [Range<Int64>]
        let hearing: String
        let note: String
        switch heard {
        case .sound(let spans):
            speech = spans
            hearing = "sound"
            note = "Any sound counted as something happening, so a narrated pause is never proposed; music with nobody talking is not dead air either."
        case .nothing(let why):
            speech = []
            hearing = "nothing"
            note = "No audio was read (\(why)), so a pause in which someone is talking may be proposed."
        }
        let listing = review(DeadAirProposer().proposals(for: try reader.take(of: log, speech: speech)), project, log)
        return ProposalsResult(
            proposals: listing.rows.map { row in
                let p = row.proposal
                return ProposalsResult.Row(
                    key: .init(reason: p.key.reason.rawValue, boot: p.key.quietStart.epoch.id.uuidString,
                               quietStartHostNanos: p.key.quietStart.hostTime.rawValue),
                    reason: p.reason.rawValue,
                    quiet: TimeSpan(startNanos: p.quiet.start.rawValue - log.anchor.hostTime.rawValue,
                                endNanos: p.quiet.end.rawValue - log.anchor.hostTime.rawValue),
                    removes: TimeSpan(startNanos: row.source.lowerBound, endNanos: row.source.upperBound),
                    openedBy: bound(p.openedBy), closedBy: bound(p.closedBy), duringStep: p.duringStep,
                    survival: row.survival == .whole ? "whole" : "partly")
            },
            alreadyCut: listing.alreadyCut, dismissed: listing.dismissed, unplaceable: listing.unplaceable,
            hearing: hearing, hearingNote: note, applied: false)
    }

    // MARK: - shared

    private static func review(_ proposals: [CutProposal], _ project: OpenedProject,
                               _ log: OpenedProject.Log) -> CutReview.Listing {
        CutReview.listing(proposals, dismissed: project.dismissed,
                          edit: project.edit ?? .whole(duration: log.duration), anchor: log.anchor)
    }

    private static func requireLog(_ project: OpenedProject) throws -> OpenedProject.Log {
        guard let log = project.log else {
            throw Failure(code: .noObservationLog,
                          message: "\(project.name) has no observation log for \(project.mediaFilename): it was recorded without one, so there are no steps, clicks or proposals to read.")
        }
        return log
    }

    /// An instant as nanoseconds into the recording. The take has already refused every instant
    /// from another boot (`TakeActivity.init`), and the plan's instants come from the same log.
    private static func offset(_ instant: HostInstant, _ log: OpenedProject.Log) -> Int64 {
        instant.hostTime.rawValue - log.anchor.hostTime.rawValue
    }

    static func bound(_ boundary: CutProposal.Boundary) -> ProposalsResult.Bound {
        switch boundary {
        case .recordingStart: .init(kind: "recordingStart", step: nil)
        case .recordingEnd: .init(kind: "recordingEnd", step: nil)
        case .press(let step): .init(kind: "press", step: step)
        case .click: .init(kind: "click", step: nil)
        case .shortcut: .init(kind: "shortcut", step: nil)
        case .pointerMoved: .init(kind: "pointerMoved", step: nil)
        case .speech: .init(kind: "speech", step: nil)
        case .unobserved: .init(kind: "unobserved", step: nil)
        }
    }
}
