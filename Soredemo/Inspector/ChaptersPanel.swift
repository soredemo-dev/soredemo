import Foundation
import Observation
import Overlays
import SwiftUI
import Timeline

/// The recording's chapters, and the suggestions a person has not decided on yet.
///
/// **Suggestions are a separate list, never chapters.** Asking again replaces the suggestions and
/// leaves every chapter where it is — the producer-value rule, and the thesis: automation
/// proposes, the person adds. `docs/design/2026-09-27-chapters.md`.
@Observable
final class ChaptersModel {
    private(set) var track = ChapterTrack()
    private(set) var suggestions: [ChapterSuggestion] = []
    private(set) var refusals: [SuggestionRefusal] = []
    /// Windows done and windows in all, while the model is working.
    private(set) var progress: (done: Int, of: Int)?
    private(set) var failure: String?
    private var work: Task<Void, Never>?

    var isSuggesting: Bool { work != nil }

    func add(at start: Nanoseconds) {
        track = track.adding(title: String(localized: "Chapter"), start: start)
    }

    func retitle(_ id: Int, to title: String) { track = track.retitled(id, to: title) }
    func remove(_ id: Int) { track = track.removing(id) }

    func restore(_ saved: ChapterTrack) {
        track = saved
        suggestions = []
        refusals = []
    }

    func accept(_ suggestion: ChapterSuggestion) {
        track = track.adding(title: suggestion.title, start: suggestion.start, origin: suggestion.origin)
        suggestions.removeAll { $0.id == suggestion.id }
    }

    func acceptAll() { suggestions.forEach(accept) }
    func dismiss(_ suggestion: ChapterSuggestion) { suggestions.removeAll { $0.id == suggestion.id } }

    func suggest(from transcript: Transcript, edit: EditTimeline) {
        work?.cancel()
        failure = nil
        progress = (0, 1)
        work = Task { @MainActor in
            defer { work = nil; progress = nil }
            do {
                let raw = try await ChapterSuggester.suggest(from: transcript) { done, of in
                    self.progress = (done, of)
                }
                receive(ChapterSuggestions.validate(raw, transcript: transcript,
                                                    timeline: edit, existing: track))
            } catch is CancellationError {
            } catch let failed as ChapterSuggester.Failure {
                failure = String(localized: "The on-device model could not read sentences \(failed.window.lowerBound + 1)–\(failed.window.upperBound): \(failed.underlying.localizedDescription)")
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    func stopSuggesting() { work?.cancel() }

    /// Where checked suggestions arrive. **Replaces the suggestions and touches no chapter** —
    /// separate from `suggest` so that promise is testable without the model.
    func receive(_ checked: (accepted: [ChapterSuggestion], refused: [SuggestionRefusal])) {
        suggestions = checked.accepted
        refusals = checked.refused
    }
}

/// The chapters tab.
struct ChaptersPanel: View {
    let model: ChaptersModel
    let edit: EditTimeline
    let transcript: Transcript?
    let playhead: Nanoseconds
    let onSeek: (Nanoseconds) -> Void
    let onChange: () -> Void

    private var placement: ChapterPlacement {
        model.track.outputChapters(through: edit, outputDuration: edit.outputDuration)
    }

    var body: some View {
        let placement = placement
        List {
            Section {
                Button("Add a chapter at the playhead") { model.add(at: playhead); onChange() }
            }
            if model.track.isEmpty {
                Section {
                    Text("No chapters yet. They are written into the exported MP4 or MOV, where players list them.")
                        .font(Type.detail).foregroundStyle(.secondary)
                }
            } else {
                Section("Chapters") {
                    ForEach(model.track.chapters) { row($0, placement) }
                }
                listSection(placement)
            }
            suggestionSections
        }
        .inspectorList()
    }

    // MARK: - chapters

    @ViewBuilder private func row(_ chapter: Chapter, _ placement: ChapterPlacement) -> some View {
        let placed = placement.placed.first { $0.id == chapter.id }
        VStack(alignment: .leading, spacing: Space.tight) {
            HStack {
                Button { onSeek(chapter.start) } label: {
                    Text(verbatim: placed.map { ChapterList.timestamp($0.start, withHours: hours) } ?? "—")
                        .font(Type.readout).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Move the playhead here")
                TextField("Title", text: Binding(
                    get: { chapter.title },
                    set: { model.retitle(chapter.id, to: $0); onChange() }))
                    .textFieldStyle(.plain)
                Button { model.remove(chapter.id); onChange() } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .help("Remove this chapter")
            }
            if case .suggested(let sentence, let text) = chapter.origin {
                Text("Suggested from sentence \(sentence + 1): “\(text)”")
                    .font(Type.detail).foregroundStyle(.secondary).lineLimit(2)
            }
            if let fate = placement.fates[chapter.id], let note = note(for: fate) {
                Text(note).font(Type.detail).foregroundStyle(Theme.Ink.caution)
            }
        }
    }

    private var hours: Bool { edit.outputDuration.rawValue >= 3_600_000_000_000 }

    private func note(for fate: ChapterFate) -> LocalizedStringKey? {
        switch fate {
        case .placed: nil
        case .movedPastACut: "Its first moment was cut, so it starts where its content resumes."
        case .droppedNothingAfter: "Nothing after it survives the edit, so no export will have it."
        case .collided(let other):
            "It lands on the same moment as “\(model.track.chapters.first { $0.id == other }?.title ?? "")”, which keeps it."
        }
    }

    /// Copying is the person's act and goes nowhere but the clipboard.
    @ViewBuilder private func listSection(_ placement: ChapterPlacement) -> some View {
        Section("For a video description") {
            Button("Copy as a list") {
                Clipboard.put(text: ChapterList.text(placement.placed, outputDuration: edit.outputDuration))
            }
            .disabled(placement.placed.isEmpty)
            ForEach(Array(ChapterList.problems(placement.placed).enumerated()), id: \.offset) { _, problem in
                Text(text(for: problem)).font(Type.detail).foregroundStyle(.secondary)
            }
        }
    }

    private func text(for problem: ChapterList.Problem) -> LocalizedStringKey {
        switch problem {
        case .firstIsNotAtTheStart: "Video sites list chapters only when the first starts at 0:00."
        case .fewerThanThree: "Video sites list chapters only when there are at least three."
        case .tooShort(let id):
            "“\(model.track.chapters.first { $0.id == id }?.title ?? "")” is shorter than the ten seconds video sites accept."
        }
    }

    // MARK: - suggestions

    @ViewBuilder private var suggestionSections: some View {
        Section("Suggestions") {
            if let progress = model.progress {
                HStack {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.of, 1)))
                    Button("Stop") { model.stopSuggesting() }
                }
            } else if let reason: LocalizedStringKey = unavailableReason {
                Text(reason).font(Type.detail).foregroundStyle(.secondary)
            } else if let transcript {
                Button("Suggest chapters from what was said") {
                    model.suggest(from: transcript, edit: edit)
                }
                Text("Made on this Mac by Apple Intelligence. Nothing is sent anywhere.")
                    .font(Type.detail).foregroundStyle(.secondary)
            }
            if let failure = model.failure {
                Text(verbatim: failure).font(Type.detail).foregroundStyle(Theme.Ink.caution)
            }
            ForEach(model.suggestions) { suggestion in
                VStack(alignment: .leading, spacing: Space.tight) {
                    HStack {
                        Text(verbatim: suggestion.title).font(Type.label)
                        Spacer()
                        Button("Add") { model.accept(suggestion); onChange() }
                        Button("Dismiss") { model.dismiss(suggestion) }
                    }
                    Text("Sentence \(suggestion.sentence + 1): “\(suggestion.evidence)”")
                        .font(Type.detail).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if model.suggestions.count > 1 {
                Button("Add all suggestions") { model.acceptAll(); onChange() }
            }
        }
        if !model.refusals.isEmpty {
            Section {
                DisclosureGroup("Not offered") {
                    ForEach(Array(model.refusals.enumerated()), id: \.offset) { _, refusal in
                        Text(text(for: refusal)).font(Type.detail).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var unavailableReason: LocalizedStringKey? {
        switch ChapterSuggester.readiness {
        case .deviceNotEligible: return "This Mac cannot run the on-device model that suggests chapters."
        case .appleIntelligenceOff: return "Turn on Apple Intelligence in System Settings to have chapters suggested."
        case .modelNotReady: return "The on-device model is not ready yet. Try again once it has finished downloading."
        case .ready: break
        }
        if transcript?.segments.isEmpty ?? true {
            return "Transcribe the recording in the Captions tab first — suggestions are made from what was said."
        }
        return nil
    }

    private func text(for refusal: SuggestionRefusal) -> LocalizedStringKey {
        switch refusal {
        case .noSuchSentence(let n): "Sentence \(n + 1) does not exist."
        case .notAfterThePrevious(let n): "Sentence \(n + 1) came out of order."
        case .noTitle(let n): "Sentence \(n + 1) came with no title."
        case .titleTooLong(let n): "The title for sentence \(n + 1) was too long to be a title."
        case .sentenceWasCut(let n): "Sentence \(n + 1) has been cut from the edit."
        case .tooCloseToAChapter(let n, _): "Sentence \(n + 1) is within ten seconds of a chapter you have."
        case .tooCloseToTheLastSuggestion(let n): "Sentence \(n + 1) is within ten seconds of the suggestion before it."
        }
    }
}
