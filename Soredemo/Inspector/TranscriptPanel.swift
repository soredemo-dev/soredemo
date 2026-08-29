import Overlays
import SwiftUI
import Timeline

/// **Editing the video by editing what was said.**
///
/// Both halves of this existed for a long time before it did and nothing joined them: a
/// transcript with per-word and per-sentence timings on one side, `EditTimeline` with
/// `removing(sourceRange:)` on the other. The join is the headline editing
/// idea — "deleting a sentence removes the video segment" — and it is the cheapest large
/// feature this project had left, because the join is the only new part.
///
/// **This panel starts no transcription, and that is deliberate.** Recognising is shaped by
/// settings that belong to captions — the language, the words-per-line cap, the output size a
/// line is broken for — and a second button here would either duplicate those controls or
/// silently pick values for them. One place starts it; this reads what it produced.
///
/// **Undo is the restore.** A deleted sentence is not remembered as deleted anywhere: the cut
/// goes through the same history as every other edit, so there is one way back and it is
/// already in the menu. Which is also why a row whose footage is gone still shows its text —
/// it is a record of what was said, not a list of what remains.
struct TranscriptPanel: View {
    let transcript: Transcript?
    /// What survives, so a row can say whether the thing it names is still in the video.
    let edit: EditTimeline
    /// Removes a span of the recording. The name becomes the undo title, so it carries the
    /// sentence rather than a generic verb.
    let onDelete: (Range<Int64>, String) -> Void
    /// Moves the playhead, in the recording's own time — the same space the transcript is in.
    let onSeek: (Nanoseconds) -> Void

    /// Which sentence is showing its individual words, if any.
    ///
    /// **One at a time, deliberately.** Cleaning up a sentence is something somebody does to one
    /// sentence; letting every row open at once would turn a readable list of what was said into
    /// a wall of chips, and the panel's first job is still reading.
    @State private var openedForWords: Int?
    /// The words chosen inside the opened sentence, by index into `transcript.words`. Cleared
    /// whenever a different sentence is opened — a selection belonging to a row nobody can see is
    /// a cut waiting to surprise somebody.
    @State private var chosenWords: Set<Int> = []

    var body: some View {
        List {
            if let transcript, !transcript.segments.isEmpty {
                Section("Summary") { summary(transcript) }
                Section("Sentences") {
                    ForEach(Array(transcript.segments.enumerated()), id: \.offset) { index, segment in
                        row(transcript, index: index, segment: segment)
                    }
                }
            } else {
                Section("Transcript") { empty }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - rows

    @ViewBuilder private func summary(_ transcript: Transcript) -> some View {
        let states = transcript.segments.indices.map { survival(transcript, index: $0) }
        let removed = states.count { $0 == .gone }
        let partial = states.count { $0 == .partly }
        VStack(alignment: .leading, spacing: Space.tight) {
            Text("\(transcript.segments.count) sentence\(transcript.segments.count == 1 ? "" : "s")")
                .font(Type.label)
            // Only the counts that are not zero: "0 removed" is a line a person has to read to
            // learn nothing.
            if removed > 0 || partial > 0 {
                Text([removed > 0 ? "\(removed) removed" : nil,
                      partial > 0 ? "\(partial) partly cut" : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(Type.detail).foregroundStyle(.secondary)
            }
            Text("Deleting a sentence cuts exactly its own span. The pause after it stays — use the Silence lane for that.")
                .font(Type.detail).foregroundStyle(.secondary)
        }
        .padding(.vertical, Space.hairline)
    }

    @ViewBuilder private func row(_ transcript: Transcript, index: Int,
                                  segment: TranscribedSegment) -> some View {
        let state = survival(transcript, index: index)
        HStack(alignment: .top, spacing: Space.snug) {
            VStack(alignment: .leading, spacing: Space.hairline) {
                HStack(spacing: Space.snug) {
                    Text(timecode(segment.start))
                        .font(Type.detail.monospacedDigit())
                        .foregroundStyle(.secondary)
                    badge(state)
                }
                Text(segment.text)
                    .font(Type.label)
                    // Struck through rather than hidden: the row is a record of what was said,
                    // and a sentence that vanished from the list would leave a person unable to
                    // tell "I deleted that" from "it was never recognised".
                    .strikethrough(state == .gone)
                    .foregroundStyle(state == .gone ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .textSelection(.enabled)
            }
            Spacer(minLength: Space.tight)
            Button {
                guard let range = transcript.removalRange(ofSegmentAt: index) else { return }
                onDelete(range, "Delete \u{201C}\(shortened(segment.text))\u{201D}")
            } label: {
                Image(systemName: "scissors")
            }
            .buttonStyle(.borderless)
            .help("Cut this sentence out of the video")
            // Nothing left to cut. Disabled rather than hidden, so the row keeps its shape and
            // the button does not move under the pointer as sentences are deleted above it.
            .disabled(state == .gone)
        }
        .contentShape(Rectangle())
        .onTapGesture { onSeek(segment.start) }

        // **Word by word, which is the honest answer to "take out my filler words".**
        //
        // The automatic version was researched and refused. macOS 26's
        // `SpeechTranscriber.TranscriptionOption` has exactly one case and none of them is a
        // verbatim mode, so the recogniser cannot be asked to keep disfluencies — and measured,
        // it does not: "uh" and "Hmm" produced no token at all, and "um" came back as **"am"**, a
        // real word that a list-matcher would either miss or delete out of a real sentence.
        //
        // A dictionary cannot tell "I like this" from "it is, like, useful". Somebody reading
        // their own sentence can, at a glance — so they choose, and this makes choosing cheap.
        let indices = transcript.wordIndices(inSegmentAt: index)
        // Offered only when the recogniser gave word times AND there is still something to cut.
        // A transcript with sentences and no word times is normal rather than an error, and the
        // honest response is to offer nothing rather than an empty row.
        if !indices.isEmpty, state != .gone {
            Button {
                if openedForWords == index {
                    openedForWords = nil
                } else {
                    openedForWords = index
                }
                chosenWords = []
            } label: {
                // Spelled out rather than chosen inside the call, for the same reason the cut
                // button below is: a title assembled by an expression is a title the label scan
                // cannot see, and what it cannot see drifts out of the string tables.
                if openedForWords == index {
                    Label("Hide words", systemImage: "chevron.down").font(Type.detail)
                } else {
                    Label("Choose words", systemImage: "chevron.right").font(Type.detail)
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)

            if openedForWords == index {
                words(transcript, indices: indices)
            }
        }
    }

    /// The sentence as chips, wrapped into lines.
    ///
    /// **Wrapped by counting characters rather than by measuring, and that is D6 rule 5 rather
    /// than laziness.** A real flow container means conforming to `Layout`, whose whole signature
    /// is `CGSize` and `CGRect` — CoreGraphics geometry, which the app target may not name; the
    /// allow-list scan rejects it. Counting characters is an approximation and it is a good one
    /// here, because these are words in a sidebar rather than a paragraph in a document, and the
    /// cost of a slightly ragged line is nothing while the cost of a bridge for a chip row would
    /// be a type that exists to make a picker prettier.
    @ViewBuilder private func words(_ transcript: Transcript, indices: Range<Int>) -> some View {
        VStack(alignment: .leading, spacing: Space.hairline) {
            ForEach(Array(Self.wrapped(indices, in: transcript).enumerated()), id: \.offset) { _, line in
                HStack(spacing: Space.hairline) {
                    ForEach(line, id: \.self) { word in
                        chip(transcript, at: word)
                    }
                    Spacer(minLength: 0)
                }
            }
            if !chosenWords.isEmpty {
                Button {
                    cutChosen(transcript)
                } label: {
                    // **Two literals rather than one interpolated title.** An interpolated
                    // `LocalizedStringKey` becomes `"Cut %lld words"`, which is a key no reader
                    // of this file would think to look for in the tables and which the label
                    // scan skips outright. Spelled out, both are keys somebody can find.
                    if chosenWords.count == 1 {
                        Label("Cut 1 word", systemImage: "scissors").font(Type.detail)
                    } else {
                        Label("Cut these words", systemImage: "scissors").font(Type.detail)
                    }
                }
                .buttonStyle(.borderless)
                .padding(.top, Space.hairline)
            }
        }
        .padding(.leading, Space.snug)
        .padding(.vertical, Space.hairline)
    }

    /// One word, chosen or not, cut or not.
    @ViewBuilder private func chip(_ transcript: Transcript, at word: Int) -> some View {
        let gone = transcript.removalRange(ofWordAt: word)
            .map { edit.survival(ofSource: $0) == .gone } ?? true
        let isChosen = chosenWords.contains(word)
        Text(transcript.words[word].text.trimmingCharacters(in: .whitespaces))
            .font(Type.detail)
            .strikethrough(gone)
            .foregroundStyle(gone ? AnyShapeStyle(.tertiary)
                             : isChosen ? AnyShapeStyle(Theme.accent)
                             : AnyShapeStyle(.primary))
            .padding(.horizontal, Space.hairline)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isChosen ? Theme.accent.opacity(0.18) : Color.clear)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                // A word already cut out of the video cannot be cut again, and a chip that
                // toggled anyway would build a selection that removes nothing.
                guard !gone else { return }
                if isChosen { chosenWords.remove(word) } else { chosenWords.insert(word) }
            }
    }

    /// Cuts what was chosen and closes the row.
    ///
    /// **Each span goes through `onDelete` separately, and the order does not matter.**
    /// `removalRanges(ofWordsAt:)` returns source time, and `EditTimeline.removing(sourceRange:)`
    /// takes source time — so three cuts land the same way whatever order they arrive in, which
    /// is the property repeated sentence deletion already relies on.
    ///
    /// The undo title names the words rather than counting them, because "Cut 2 words" in the
    /// menu a week later says nothing about what came out.
    private func cutChosen(_ transcript: Transcript) {
        let chosen = chosenWords.sorted()
        let spoken = chosen.map { transcript.words[$0].text.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
        let ranges = transcript.removalRanges(ofWordsAt: chosen)
        guard !ranges.isEmpty else { return }
        for range in ranges {
            onDelete(range, "Cut \u{201C}\(shortened(spoken))\u{201D}")
        }
        chosenWords = []
        openedForWords = nil
    }

    /// Words grouped into lines short enough to sit side by side. See `words(_:indices:)` for why
    /// this counts rather than measures.
    ///
    /// **A pure function over the text, so the one piece of arithmetic here can be checked.**
    /// § 23 of the cross-boundary probe exercises it; the app target has no test target of its
    /// own, which is the same reason `RecordingCoordinator`'s preferences are checked there.
    static func wrapped(_ indices: Range<Int>, in transcript: Transcript) -> [[Int]] {
        wrappedLines(indices.map { ($0, transcript.words[$0].text) })
    }

    /// The rule itself, over `(index, text)` pairs so it needs no `Transcript` to check.
    ///
    /// Thirty-four characters is what fits across the inspector at the detail font, measured by
    /// eye rather than by instrument — and a line that runs one word long costs a ragged edge,
    /// which is why this is allowed to be approximate. **A word longer than the line still gets
    /// its own line rather than being dropped**, which is the case a naive accumulator loses.
    static func wrappedLines(_ words: [(index: Int, text: String)],
                             charactersPerLine: Int = 34) -> [[Int]] {
        var lines: [[Int]] = []
        var current: [Int] = []
        var used = 0
        for word in words {
            let length = word.text.trimmingCharacters(in: .whitespaces).count + 1
            if !current.isEmpty, used + length > charactersPerLine {
                lines.append(current)
                current = []
                used = 0
            }
            current.append(word.index)
            used += length
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    @ViewBuilder private func badge(_ state: EditTimeline.Survival) -> some View {
        switch state {
        case .whole:
            EmptyView()
        case .partly:
            Label("partly cut", systemImage: "scissors.badge.ellipsis")
                .font(Type.detail).foregroundStyle(.secondary)
        case .gone:
            Label("removed", systemImage: "scissors")
                .font(Type.detail).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var empty: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            Text("No transcript yet.").font(Type.label)
            Text("Transcribe the recording in Overlays, then delete a sentence here to cut it out of the video.")
                .font(Type.detail).foregroundStyle(.secondary)
        }
    }

    // MARK: - derived

    private func survival(_ transcript: Transcript, index: Int) -> EditTimeline.Survival {
        guard let range = transcript.removalRange(ofSegmentAt: index) else { return .gone }
        return edit.survival(ofSource: range)
    }

    /// Enough of the sentence to recognise it in an undo menu, and no more.
    private func shortened(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 28 else { return trimmed }
        return trimmed.prefix(27).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    /// **Integer arithmetic rather than `String(format:)`**, which is a C-variadic call and one
    /// of the unmarked unsafe sites `check-strict-memory-safety.sh` reports. Tenths of a second,
    /// because a sentence boundary a person is about to cut on is worth more than whole seconds.
    private func timecode(_ time: Nanoseconds) -> String {
        let tenths = max(0, time.rawValue) / 100_000_000
        let minutes = tenths / 600
        let seconds = (tenths / 10) % 60
        let fraction = tenths % 10
        let padded = seconds < 10 ? "0\(seconds)" : "\(seconds)"
        return "\(minutes):\(padded).\(fraction)"
    }
}
