import Framing
import Overlays
import SwiftUI
import Timeline

/// The cuts tab: each proposed removal, what it rests on, and a person's yes or no.
///
/// **Each row says what was measured, not just how long.** "Nothing happens for 9.2 s, after step
/// 4, until the pointer moves" is checkable against the recording; "9.2 s of silence" is not, and
/// is the thing every silence cutter says. **Cut** is an ordinary undoable edit; **Keep** is a
/// "no" in the same history, so ⌘Z brings either back. `docs/design/2026-11-08-evidence-cut-and-the-agent-surface.md`.
struct CutProposalsPanel: View {
    let model: CutProposalsModel
    let timeline: TimelineEditorModel
    let onChange: () -> Void

    var body: some View {
        let edit = timeline.edit
        List {
            if let failure = model.failure {
                Section {
                    Text("The observation log could not be read, so no cuts can be suggested.")
                        .font(Type.detail).foregroundStyle(Theme.Ink.caution)
                    Text(verbatim: failure).font(Type.detail).foregroundStyle(.secondary).lineLimit(3)
                }
            } else if let listing = model.listing(edit: edit, dismissed: timeline.dismissedCuts) {
                summary(listing, edit)
                if !listing.rows.isEmpty {
                    Section("Suggested cuts") {
                        ForEach(listing.rows, id: \.proposal.key) { row($0, edit) }
                    }
                }
                Section { hearingNote }
            } else {
                Section {
                    Text("This recording has no observation log, so there is nothing to suggest cuts from.")
                        .font(Type.detail).foregroundStyle(.secondary)
                }
            }
        }
        .inspectorList()
    }

    // MARK: - the summary

    @ViewBuilder private func summary(_ listing: CutReview.Listing, _ edit: EditTimeline) -> some View {
        Section {
            if listing.rows.isEmpty {
                Text(nothingLeft(listing)).font(Type.detail).foregroundStyle(.secondary)
            } else {
                let total = CutReview.remaining(listing.rows, in: edit)
                Text("Suggested cuts: \(listing.rows.count), \(EditorToolbar.seconds(total)) in all")
                    .font(Type.label)
                // One decision, one undo step — and the total is on screen before it is pressed.
                Button("Cut all \(listing.rows.count) (\(EditorToolbar.seconds(total)))") {
                    timeline.acceptCuts(listing.rows,
                                        named: String(localized: "Cut Quiet Spans (\(listing.rows.count))"))
                    onChange()
                }
            }
            if listing.alreadyCut > 0 || listing.dismissed > 0 {
                Text("Already cut: \(listing.alreadyCut) · Kept: \(listing.dismissed)")
                    .font(Type.detail).foregroundStyle(.secondary)
            }
            if listing.unplaceable > 0 {
                Text("Suggestions from another start-up of this Mac: \(listing.unplaceable). They cannot be placed on this recording.")
                    .font(Type.detail).foregroundStyle(Theme.Ink.caution)
            }
        }
    }

    private func nothingLeft(_ listing: CutReview.Listing) -> LocalizedStringKey {
        if model.proposals.isEmpty {
            "Nothing in this recording was quiet for \(EditorToolbar.seconds(DeadAirProposer.minimumQuiet)) or more."
        } else {
            "Every suggested cut has been made or kept."
        }
    }

    /// Said beside the list, because it changes what the list can be trusted with.
    private var hearingNote: some View {
        Text(hearingText).font(Type.detail).foregroundStyle(.secondary)
    }

    private var hearingText: LocalizedStringKey {
        switch model.hearing {
        case .transcript:
            "Speech is read from the transcript, so a pause in which someone is talking is never suggested."
        case .sound:
            "Not transcribed yet, so any sound counts as something happening. Transcribe in the Captions tab to tell speech from other sound."
        case .nothing:
            "No audio was read, so a pause in which someone is talking may be suggested."
        }
    }

    // MARK: - one row

    @ViewBuilder private func row(_ row: CutReview.Row, _ edit: EditTimeline) -> some View {
        let proposal = row.proposal
        let quiet = EditorToolbar.seconds(proposal.quiet.duration)
        let removes = EditorToolbar.seconds(Nanoseconds(row.source.upperBound - row.source.lowerBound))
        // Shown where it plays in the video; the playhead goes to the moment on the recording.
        let moment = SourceTime(nanos: row.source.lowerBound)
        let start = edit.outputTime(atSource: moment)
        VStack(alignment: .leading, spacing: Space.tight) {
            Text(headline(proposal, quiet: quiet)).font(Type.label)
            HStack(spacing: Space.tight) {
                Text(opened(proposal.openedBy))
                Text(verbatim: "·")
                Text(closed(proposal.closedBy))
            }
            .font(Type.detail).foregroundStyle(.secondary)
            Text("Cuts \(removes), keeping a breath on each side")
                .font(Type.detail).foregroundStyle(.secondary)
            if row.survival == .partly {
                Text("Part of it is already cut.").font(Type.detail).foregroundStyle(Theme.Ink.caution)
            }
            HStack {
                Button {
                    if start != nil { timeline.movePlayhead(to: moment) }
                } label: {
                    Text(verbatim: start.map { ChapterList.timestamp($0.nanoseconds, withHours: false) } ?? "—")
                        .font(Type.readout)
                }
                .buttonStyle(.plain)
                .disabled(start == nil)
                .help("Move the playhead here")
                Spacer()
                Button("Keep") {
                    timeline.dismissCut(proposal.key, named: String(localized: "Keep \(quiet) Pause"))
                    onChange()
                }
                .help("Leave this pause in. Undo brings the suggestion back.")
                Button("Cut") {
                    timeline.acceptCut(row, named: String(localized: "Cut \(removes) Pause"))
                    onChange()
                }
                .help("Remove this pause. Undo puts it back.")
            }
        }
    }

    private func headline(_ proposal: CutProposal, quiet: String) -> LocalizedStringKey {
        if proposal.openedBy == .recordingStart {
            "Nothing happens for the first \(quiet)"
        } else if proposal.closedBy == .recordingEnd {
            "Nothing happens for the last \(quiet)"
        } else if let step = proposal.duringStep {
            "Nothing happens for \(quiet) during step \(step)"
        } else {
            "Nothing happens for \(quiet)"
        }
    }

    private func opened(_ boundary: CutProposal.Boundary) -> LocalizedStringKey {
        switch boundary {
        case .recordingStart: "From the start"
        case .recordingEnd: "From the end"
        case .press(let step): "After step \(step)"
        case .click: "After a click"
        case .shortcut: "After a shortcut"
        case .pointerMoved: "After the pointer stops"
        case .speech: "After the talking stops"
        case .unobserved: "After a stretch nobody could see"
        }
    }

    private func closed(_ boundary: CutProposal.Boundary) -> LocalizedStringKey {
        switch boundary {
        case .recordingStart: "until the start"
        case .recordingEnd: "until the end"
        case .press(let step): "until step \(step)"
        case .click: "until a click"
        case .shortcut: "until a shortcut"
        case .pointerMoved: "until the pointer moves"
        case .speech: "until someone talks"
        case .unobserved: "until a stretch nobody could see"
        }
    }
}
