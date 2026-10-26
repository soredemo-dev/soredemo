import Foundation
import FoundationModels
import Overlays

/// What the model is asked to return. **A sentence number and a title — never a time**: the
/// time comes from the transcript, in `ChapterSuggestions.validate`.
@Generable(description: "Where the chapters of a narrated screen recording begin")
struct SuggestedChapters {
    @Guide(description: "The chapters in the order they begin. Usually one every minute or two of narration; none if the subject never changes.")
    var chapters: [SuggestedChapter]
}

@Generable
struct SuggestedChapter {
    @Guide(description: "The number in square brackets of the sentence where this chapter begins")
    var sentence: Int
    @Guide(description: "Two to six words naming what the chapter shows, in the language of the sentences. Not a copy of the sentence.")
    var title: String
}

/// Chapter suggestions from the ON-DEVICE model, and nothing else.
///
/// **`SystemLanguageModel.default` only.** The SDK also offers `PrivateCloudComputeLanguageModel`,
/// which sends the prompt off this Mac; nothing here leaves the machine unless a person sends
/// it, and a source test forbids naming that type. See `docs/design/2026-09-27-chapters.md`.
enum ChapterSuggester {
    enum Readiness: Equatable {
        case ready
        case deviceNotEligible
        case appleIntelligenceOff
        case modelNotReady
    }

    static var readiness: Readiness {
        switch SystemLanguageModel.default.availability {
        case .available: .ready
        case .unavailable(.deviceNotEligible): .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): .appleIntelligenceOff
        case .unavailable: .modelNotReady
        }
    }

    /// Characters of numbered sentences per request. **Chosen for the worst script, not the
    /// usual one**: the context is 4096 tokens (D6b-30), and Chinese or Japanese can run near a
    /// token a character, so 2000 leaves room for the instructions, the schema and the answer.
    /// A window that still does not fit is halved once — see `answers(for:)`.
    static let windowCharacters = 2000

    struct Failure: Error {
        let window: Range<Int>
        let underlying: any Error
    }

    /// Every window's answer, in order. `progress` is told how many windows are done.
    static func suggest(from transcript: Overlays.Transcript,
                        progress: @MainActor (_ done: Int, _ of: Int) -> Void) async throws
    -> [RawChapterSuggestion] {
        let windows = ChapterSuggestions.windows(of: transcript, maximumCharacters: windowCharacters)
        var found: [RawChapterSuggestion] = []
        for (index, window) in windows.enumerated() {
            try Task.checkCancellation()
            progress(index, windows.count)
            found += try await answers(for: window, in: transcript, after: found.last?.title)
        }
        progress(windows.count, windows.count)
        return found
    }

    /// One window, or its two halves if the whole failed. **Any failure, not a named one**: the
    /// error for an overlong prompt was renamed between macOS 26 and 27, and matching either
    /// name would miss the other.
    private static func answers(for window: Range<Int>, in transcript: Overlays.Transcript,
                                after previous: String?) async throws -> [RawChapterSuggestion] {
        do {
            return try await ask(window, transcript, after: previous)
        } catch where window.count > 1 && !(error is CancellationError) {
            let middle = window.lowerBound + window.count / 2
            do {
                let first = try await ask(window.lowerBound..<middle, transcript, after: previous)
                return first + (try await ask(middle..<window.upperBound, transcript,
                                              after: first.last?.title ?? previous))
            } catch {
                throw Failure(window: window, underlying: error)
            }
        } catch {
            throw Failure(window: window, underlying: error)
        }
    }

    private static func ask(_ window: Range<Int>, _ transcript: Overlays.Transcript,
                            after previous: String?) async throws -> [RawChapterSuggestion] {
        // A fresh session per window: the context holds one window, never the whole history.
        let session = LanguageModelSession(model: .default, instructions: """
            You divide the narration of a screen recording into chapters. You are shown numbered \
            sentences. Start a chapter only where the subject changes. Answer with the number of \
            the sentence each chapter begins at and a short title.
            """)
        // Said, because a window after the first begins mid-subject, and a model shown a first
        // sentence tends to start a chapter there whatever it says.
        let context = previous.map { "The chapter before these sentences is titled \"\($0)\". Do not start a chapter at the first sentence unless the subject changes there.\n\n" } ?? ""
        let response = try await session.respond(
            to: context + ChapterSuggestions.numberedSentences(of: transcript, in: window),
            generating: SuggestedChapters.self)
        return response.content.chapters.map { RawChapterSuggestion(sentence: $0.sentence, title: $0.title) }
    }
}
