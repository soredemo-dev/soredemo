import Foundation
import Observation
import Overlays

/// What a cue list remembers between redraws, and the decisions made from it.
///
/// **A class, because the list is a value that gets thrown away.** `CaptionLines` is handed to a
/// host's `List` as rows; SwiftUI rebuilds that struct constantly, and `@State` inside it is
/// never installed, so every binding is a constant of its initial value. The runtime reports
/// exactly that, and the symptom is a search field that filters nothing.
///
/// Held by the host with `@State`, so the host's identity is what keeps it alive.
///
/// **The decisions are here and not in the rows**, so they can be tested: which cues the search
/// lets through, and when a commit becomes an offer to fix the same thing elsewhere — see
/// `docs/design/2026-10-24-the-caption-list-decides-in-its-state.md`.
@Observable
final class CaptionListState {
    /// What the list is filtered to. **A filter, not a jump-to-match**: on a long recording the
    /// question is "where did I say that", and the answer is every line that says it.
    var search = ""
    /// What the focused row said before anybody typed in it, so a commit can tell what changed.
    private(set) var textOnFocus: (index: Int, text: String)?
    /// A correction worth offering to apply everywhere, with how many other lines it reaches.
    var offer: (edit: RunEdit, others: Int, word: String)?

    /// The cues the search lets through, each with its index into the UNFILTERED track — which
    /// is what every edit addresses, so filtering can never retime the wrong line. Matched
    /// without regard to case, and ignoring spaces around what was typed.
    func visibleCues(of track: CaptionTrack) -> [(index: Int, cue: CaptionCue)] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return track.cues.enumerated()
            .filter { needle.isEmpty || $0.element.text.lowercased().contains(needle) }
            .map { (index: $0.offset, cue: $0.element) }
    }

    /// Remembers what the row at `index` says as the caret arrives in it.
    func remember(_ index: Int, in track: CaptionTrack) {
        guard index < track.cues.count else { return }
        textOnFocus = (index, track.cues[index].text)
    }

    /// Turns a committed correction into an offer, when it is one.
    ///
    /// **The reason correcting a transcript is hard is not one line — it is the same word forty
    /// times.** A demo says a product's name forty times and the recogniser gets it wrong forty
    /// times, and fixing that by hand is what makes people give up on automatic captions.
    ///
    /// So a commit that changed ONE contiguous run of text, in a line whose run appears
    /// elsewhere, becomes an offer with the count on it. Offered rather than done: a silent
    /// sweep across a transcript is a change nobody reviewed, and the count is what lets
    /// somebody predict what pressing it will do. Only for the row whose text was remembered:
    /// a commit on another row compares two lines that were never the same line.
    func noteCorrection(at index: Int, in track: CaptionTrack) {
        defer { textOnFocus = nil }
        guard let before = textOnFocus, before.index == index,
              index < track.cues.count else { return }
        let after = track.cues[index].text
        guard let edit = RunEdit(from: before.text, to: after) else { return }
        let others = track.cuesContaining(edit.was, excluding: index)
        guard others > 0 else { return }
        // The whole word the run sits in is what gets remembered for next time — a term list of
        // three-letter fragments would match things nobody meant.
        let word = after.split(whereSeparator: \.isWhitespace)
            .first { $0.contains(edit.now) }.map(String.init)
        offer = (edit, others, word ?? edit.now)
    }
}
