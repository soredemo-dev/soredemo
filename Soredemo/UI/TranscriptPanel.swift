import Overlays
import SwiftUI
import Timeline

/// **Editing the video by editing what was said.**
///
/// Both halves of this existed for a long time before it did and nothing joined them: a
/// transcript with per-word and per-sentence timings on one side, `EditTimeline` with
/// `removing(sourceRange:)` on the other. ScreenKite ships the join as its headline editing
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
