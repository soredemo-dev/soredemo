import Foundation
import Overlays
import SwiftUI
import Timeline

/// The captions tab. A list a person reads down, which is what an inspector is for.
struct CaptionsPanel: View {
    let model: CaptionsModel
    let mediaURL: URL
    /// What the recording is called — the sidecar's starting name. See `RecordingName`.
    let recordingName: String
    let edit: EditTimeline?
    let outputWidth: Int
    let outputHeight: Int
    /// Rebuild the preview: turning burn-in on has to change the picture, or the toggle is a
    /// form field rather than a control.
    let onChange: () -> Void
    /// The playhead, read at the moment a key is pressed rather than stored — see
    /// `CaptionLines.playheadNow`. This panel itself needs no playhead: which cue is current
    /// comes from `model.currentCueIndex`, which changes when the highlight moves rather than
    /// ten times a second.
    let playheadNow: () -> Nanoseconds
    /// Move the playhead. **The list is a way of navigating the recording**, not a table of its
    /// contents: a caption is corrected at the pace of playback, and a row that cannot be
    /// listened to is a row somebody has to find in the scrubber first.
    let onSeek: (Nanoseconds) -> Void
    /// Where the RECORDING is silent, from the timeline's own detection. **The same spans the
    /// Silence lane and the music ducking read**, so "where did they stop talking" has one
    /// answer in this app rather than three.
    let pauses: [SilenceFinder.Span]
    /// What was said, as sentences. **A different unit from the cues below** — `CaptionBuilder`
    /// breaks one sentence into one or more lines — which is why this panel shows two lists and
    /// not one merged one. See `TranscriptPanel.sections`.
    let transcript: Transcript?
    /// Cuts a span of the recording out. The name becomes the undo title.
    let onDeleteRange: (Range<Int64>, String) -> Void
    /// Opens the full-width caption editor. **Inside this panel's Captions half**, because that
    /// is what it is the full-width version of — above the panel it sat over the transcript too.
    let onOpenEditor: () -> Void

    /// Which of the two lists is showing.
    ///
    /// **They were two inspector tabs and are now one**, because a person looking for what they
    /// had said had to know which of two rail icons held it, and the two look like the same
    /// list. They are not: a SENTENCE is the unit you cut the video by, a LINE is the unit a
    /// viewer reads. Premiere puts the same two inside one Text panel; Descript keeps the
    /// transcript as the document and captions as a panel. Neither merges the rows, because a
    /// delete meaning "remove my footage" on some rows and "remove a subtitle" on others is a
    /// trap somebody springs once, on their own recording.
    @State private var showing: Words = .lines

    enum Words: String, CaseIterable, Hashable {
        case sentences, lines
        var title: String {
            switch self {
            case .sentences: String(localized: "Transcript")
            case .lines: String(localized: "Captions")
            }
        }
    }

    /// How many words a line may hold, or `nil` for as many as fit. Here rather than in
    /// `TranscriptionControls`, because a change to the names list re-breaks lines with it too.
    @State private var maximumWords: Int?
    /// Which row has the caret. Also what decides whether the list follows the playhead: a list
    /// that scrolled itself while somebody was typing in it would move the field out from under
    /// them.
    @FocusState private var focused: Int?
    /// What the cue list remembers. See `CaptionListState` — it is a class because the list
    /// itself is a value SwiftUI throws away between redraws.
    @State private var listState = CaptionListState()
    /// What the sentence list remembers. See `TranscriptListState`.
    @State private var transcriptState = TranscriptListState()

    var body: some View {
        // **`ScrollViewReader` around the LIST, and one row per cue inside it.** Both were wrong
        // together: the cues were built into a `VStack` inside a single `Section` row, so a
        // 270-cue recording built 270 views before showing one, and the scroll that follows the
        // playhead was a scroll view nested inside another one. A row each is lazy and is what
        // `scrollTo` addresses.
        ScrollViewReader { scroller in
            List {
                Section { picker }
                Section { explanation }
                Section("Transcribe") {
                    TranscriptionControls(model: model, mediaURL: mediaURL,
                                          outputWidth: outputWidth, outputHeight: outputHeight,
                                          pauses: pauses, maximumWords: $maximumWords,
                                          onChange: onChange)
                }
                // **In both lists**, because a name is spelled wrong in a sentence and in a line
                // alike — and it was in neither until 2026-10-23. See
                // `everyPrivateViewInTheAppIsPlacedSomewhere`.
                Section("Names") { CaptionTermControls(model: model, onTermsChanged: rebuildAndPublish) }
                if !model.suggestions.isEmpty {
                    CaptionSuggestionList(model: model, onChange: onChange)
                }
                if showing == .sentences {
                    // `edit ?? EditTimeline(clips: [])`: the panel already holds an optional
                    // edit — `nil` before the asset loads — and a sentence asked whether its
                    // footage survives an EMPTY timeline is told it does not, which is the
                    // honest answer while nothing is loaded rather than a crash or a guess.
                    TranscriptPanel(transcript: transcript, edit: edit ?? EditTimeline(clips: []),
                                    onDelete: onDeleteRange, onSeek: onSeek,
                                    listState: transcriptState)
                        .sections
                }
                if showing == .lines, !model.track.isEmpty {
                    Section {
                        Button(action: onOpenEditor) {
                            Label("Open the caption editor", systemImage: "rectangle.split.2x1")
                        }
                        .help("Captions at full width, with the waveform")
                    }
                    Section("Preset") { CaptionPresetControls(model: model, onChange: onChange) }
                    Section("Look") {
                        CaptionLookControls(model: model, mediaURL: mediaURL,
                                            recordingName: recordingName, edit: edit,
                                            onChange: onChange)
                    }
                    Section("Lines") {
                        // **The same rows the caption editor draws**, in a column measured at
                        // 300pt for content measured at 437. The list is not wrong here — it is
                        // how you correct a line while looking at the picture — but it is not
                        // where a person should have to do an hour of caption work, which is
                        // what `CaptionEditor` is for.
                        lines.rows
                    }
                }
                if let status = model.status {
                    Section { Text(verbatim: status).font(Type.detail).foregroundStyle(.secondary) }
                }
            }
            .inspectorList()
            // **Not while somebody is typing in it, and the reason was already written down.**
            // `focused`'s own comment says a list that scrolled itself while somebody was
            // typing would move the field out from under them — and the guard to match it was
            // never written here. During playback the current cue changes every few seconds, so
            // correcting a line while the video ran meant the row you were editing slid away
            // mid-word. Reported as "you cannot edit subtitles while it plays".
            .onChange(of: currentIndex) {
                guard focused == nil, let currentIndex else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    scroller.scrollTo(currentIndex, anchor: .center)
                }
            }
        }
    }

    /// Which list is showing. **A segmented control rather than two rail icons**: the two are
    /// one subject seen two ways, and switching between them should cost a glance rather than a
    /// trip across the window.
    @ViewBuilder private var picker: some View {
        Picker("", selection: $showing) {
            ForEach(Words.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    /// One sentence, because the relationship is the thing nobody can guess: a person who
    /// deletes in the wrong list loses footage they meant to keep.
    ///
    /// **Its own `Section`, and wrapped.** Sharing a section with the picker put it on a row
    /// sized for a control and it came out as one truncated line — which for this sentence
    /// means the half that survives is "a sentence is what you cut the video by" and the half
    /// that explains the other list is gone.
    @ViewBuilder private var explanation: some View {
        Text("A sentence is what you cut the video by. A caption line is what a viewer reads \u{2014} one sentence becomes one or more lines.")
            .font(Type.detail)
            .foregroundStyle(.secondary)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The shared cue list, configured for this panel. **The state it reads is held HERE**, by
    /// this view's `@State`, because the struct below is rebuilt on every redraw.
    private var lines: CaptionLines {
        CaptionLines(model: model, onChange: onChange,
                     currentIndex: model.currentCueIndex, playheadNow: playheadNow,
                     onSeek: onSeek, pauses: pauses,
                     state: listState, focused: $focused)
    }

    /// The index of the cue the playhead is inside, or `nil` between cues. Kept here only to
    /// scroll to it; every other use of it moved into `CaptionLines`. Read from the model rather
    /// than derived, for the reason in `CaptionsModel.currentCueIndex`.
    private var currentIndex: Int? { model.currentCueIndex }

    /// A term list change re-breaks the cues, because a corrected word is a different width and
    /// may not fit the line it was on. Cheap — `rebuild` re-breaks a kept transcript rather than
    /// recognising anything.
    private func rebuildAndPublish() {
        model.rebuild(outputWidth: outputWidth, outputHeight: outputHeight,
                      maximumWords: maximumWords, pauses: pauses)
        onChange()
    }
}
