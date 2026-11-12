import Compositing
import Foundation
import Framing
import Overlays
import Observation
import Project
import Timeline

/// The recording's steps — each deliberate press on a named element — for the timeline's Steps
/// lane and, later, the guide and the walkthrough.
///
/// **Its own model, not the framing review's.** Both read the same log, but the review is about
/// what the camera does and this is about what the person did; one type holding both would be two
/// reasons to change. See `docs/design/2026-10-25-a-recording-knows-its-steps.md`.
@Observable
final class RecordedStepsModel {
    private(set) var steps: [RecordedStep] = []
    /// For turning a step's absolute instant into a time in the video. `nil` without a header.
    private(set) var anchor: EpochAnchor?
    /// Why the log could not be read, or `nil`. Reported rather than shown as no steps: "nobody
    /// clicked anything named" and "the file could not be opened" are different facts.
    private(set) var failure: String?

    /// Reads the steps for one recording. `duration` closes the last step; without it the last
    /// step ends where it began, which is the honest length of a step whose end is unknown.
    /// What was on screen in each step, as vocabulary for the captions: the pressed element's
    /// label and the application's name, each credited to its step. Blank ones are not words.
    var vocabulary: [VocabularyEvidence] {
        steps.flatMap { step -> [VocabularyEvidence] in
            var words: [VocabularyEvidence] = []
            let label = step.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty { words.append(VocabularyEvidence(term: label, origin: .pressedLabel(step: step.number))) }
            if let application = step.application?.trimmingCharacters(in: .whitespacesAndNewlines), !application.isEmpty {
                words.append(VocabularyEvidence(term: application, origin: .application(step: step.number)))
            }
            return words
        }
    }

    func load(observationLogAt url: URL?, anchor: EpochAnchor?, duration: Nanoseconds?) {
        self.anchor = anchor
        guard let url else {
            steps = []
            failure = nil
            return
        }
        do {
            let chains = try FramingPlanReader.chains(fromObservationLogAt: url)
            // No clicks is no steps — not a made-up instant to end a step nobody took.
            guard let last = chains.map(\.instant).max(by: { $0.hostTime.rawValue < $1.hostTime.rawValue })
            else {
                steps = []
                failure = nil
                return
            }
            let end = anchor.flatMap { anchor in duration.map { anchor.instant(atOffset: $0) } }
            steps = RecordedSteps.steps(from: chains, recordingEnd: end ?? last)
            failure = nil
        } catch {
            steps = []
            failure = "\(error)"
        }
    }

    /// Each step's start in the recording, for the lane — steps from another boot session, which
    /// have no place on this recording's clock, are left out rather than put at zero.
    var marks: [StepMark] {
        guard let anchor else { return [] }
        return steps.compactMap { step in
            FramingPlanReader.offset(of: step.origin, from: anchor).map {
                StepMark(start: $0, number: step.number, label: step.label)
            }
        }
    }
}

/// A step as the timeline draws it.
struct StepMark: Hashable {
    let start: Nanoseconds
    let number: Int
    let label: String
}
