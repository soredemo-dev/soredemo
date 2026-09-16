import AppKit
import AVFoundation
import Capture
import Overlays
import Compositing
import Foundation
import Observation
import Render
import SwiftUI
import Timeline
import UniformTypeIdentifiers

/// The captions for one recording: transcribing, correcting, burning in, exporting a sidecar.
///
/// **The track is SAVED rather than re-derived, which is a deliberate exception to the
/// producer-value rule.** Everything else in this project re-derives on open, because deriving
/// is cheap and a saved derived value goes stale when the derivation improves. Transcription is
/// neither: it costs a minute of compute and a several-hundred-megabyte model download, and two
/// runs of two model versions do not agree word for word. Re-deriving on open would mean a
/// person's corrections were applied to text that had changed underneath them.
///
/// The corrections are authored either way, so the track has to be saved for them to survive.
@Observable
final class CaptionsModel {
    private(set) var track = CaptionTrack()
    private(set) var style: CaptionStyle = .default

    /// Which cue the playhead is inside, or `nil` between cues.
    ///
    /// **Held here rather than derived in the list, and that is a performance decision with a
    /// measurement behind it.** The list used to take the playhead itself and find the cue from
    /// it, which made the playhead an input to every row — so a recording playing at 10 ticks a
    /// second rebuilt all 270 rows ten times a second, and one `sample` over six seconds of
    /// playback found the main thread **0.1% idle** with `CaptionLines.rows` and `row(index:cue:)`
    /// alone accounting for a fifth of it. With the caption tab closed the same playback left the
    /// main thread 23% idle.
    ///
    /// An index changes when a cue changes — a few times a minute in a real transcript, not ten
    /// times a second — so the rows rebuild when the highlight actually moves. `CaptionCueTracker`
    /// is the one view that watches the playhead at its own rate and writes this.
    private(set) var currentCueIndex: Int?
    /// Draw the captions into the picture. Off by default: a burnt-in caption cannot be turned
    /// off, and a person who wanted a sidecar has not asked for one in their video.
    private(set) var burnsIn = false
    private(set) var phase: TranscriptionProgress?
    /// The steps that have finished this run, with how long each took.
    ///
    /// **A stage list with times, rather than one line saying what is happening now.** "Listening"
    /// answers "is it stuck?" with a shrug; three steps with the finished ones ticked and their
    /// seconds beside them answers it. Cleared when a run starts, so it is always this run's.
    private(set) var finishedSteps: [(step: TranscriptionProgress, seconds: Double)] = []
    /// When the running step began, for the same reason.
    ///
    /// **`Minting.continuousNow()`, not a clock this file obtains.** ARCHITECTURE.md rule 3 is
    /// zero-permit in the app target: an ambient reading enters at one audited place and travels
    /// as a plain value. The version that read `ContinuousClock.now` also read it TWICE in one
    /// subtraction — seconds from one instant, attoseconds from another — so a step could be
    /// reported a whole second short. One reading, subtracted, cannot do that.
    private var stepStarted: Nanoseconds?
    /// The run itself, so it can be stopped. Cancelling reaches the analyzer, not only the wait:
    /// measured at 0.16 s to return against 1.94 s to finish.
    private var transcribing: Task<Void, Never>?
    private(set) var status: String?
    /// The transcript **as recognised**, kept so a change to the caption style or the output
    /// size can re-break the lines without transcribing again. Breaking is instant; recognising
    /// is not.
    ///
    /// **Corrections are applied on the way to the cues, not baked in here.** Editing the term
    /// list then re-applies against what was actually heard rather than compounding on top of a
    /// previous pass, and the raw recognition is still there to correct differently tomorrow.
    private(set) var transcript: Transcript?
    /// Names the recogniser has never heard, spelled the way they should come out.
    ///
    /// **This does not make the recogniser hear them.** Both mechanisms Apple publishes for
    /// biasing recognition were measured on this platform and changed nothing —
    /// `docs/design/teaching-the-recogniser-a-word.md` — so this is a spelling pass over what
    /// came back, and the panel says so rather than letting somebody read it as accuracy.
    private(set) var spokenTerms: [String] = []
    /// What the cues are built from: the recognition with the person's terms spelled their way.
    var correctedTranscript: Transcript? { transcript?.correcting(terms: spokenTerms) }
    /// The language to recognise, or `nil` for the system's preferred. Held across recordings.
    var locale: Locale?
    private(set) var availableLocales: [Locale] = []
    private(set) var installedLocales: Set<String> = []
    /// True when the text that came back does not look like the language that was asked for —
    /// see `OnDeviceTranscription.languageLooksWrong`.
    private(set) var languageLooksWrong = false

    func refreshLocales() async {
        availableLocales = await OnDeviceTranscription.supportedLocales
            .sorted { $0.identifier(.bcp47) < $1.identifier(.bcp47) }
        installedLocales = Set(await OnDeviceTranscription.installedLocales
            .map { $0.identifier(.bcp47) })
    }

    var isTranscribing: Bool { phase != nil }

    /// Records how long the step that just ended took, and starts timing the new one.
    private func note(_ next: TranscriptionProgress) {
        let now = Minting.continuousNow()
        if let phase, let stepStarted {
            finishedSteps.append((phase, Double(now.rawValue - stepStarted.rawValue) / 1e9))
        }
        phase = next
        stepStarted = now
    }

    /// Stops a run. The work is dropped rather than kept: half a transcript timed against the
    /// first half of a recording is not a shorter transcript, it is a wrong one.
    func cancelTranscription() {
        transcribing?.cancel()
    }
    var canTranscribe: Bool { OnDeviceTranscription.isAvailable && !isTranscribing }

    init() { publish() }

    /// Called by `CaptionCueTracker` on every playhead change. **Assigns only when the answer
    /// differs**, because `@Observable` publishes an assignment rather than a change, and an
    /// equal write here would undo the whole point of the field.
    func noteCurrentCue(at playhead: Nanoseconds) {
        let found = track.cues.firstIndex { $0.contains(playhead) }
        if found != currentCueIndex { currentCueIndex = found }
    }

    // MARK: - producing

    /// Transcribes and breaks the result into lines. `outputWidth`/`outputHeight` decide where
    /// lines break — see `CaptionArt.fits`.
    @MainActor
    func transcribe(mediaURL: URL, outputWidth: Int, outputHeight: Int,
                    maximumWords: Int?, pauses: [SilenceFinder.Span]) async {
        finishedSteps = []
        stepStarted = nil
        note(.extractingAudio)
        status = nil
        defer { phase = nil; stepStarted = nil; transcribing = nil }

        // Held so `cancelTranscription` has something to cancel, and awaited so the caller's
        // `onChange` still runs after it — cancelled or not.
        let run = Task { [weak self] in
            guard let self else { return }
            do {
                let source = OnDeviceTranscription(locale: locale)
                let recognised = try await source.transcript(
                    of: mediaURL, range: nil,
                    onProgress: { [weak self] progress in
                        Task { @MainActor in self?.note(progress) }
                    })
                transcript = recognised
                languageLooksWrong = OnDeviceTranscription.languageLooksWrong(recognised)
                rebuild(outputWidth: outputWidth, outputHeight: outputHeight,
                        maximumWords: maximumWords, pauses: pauses)
                status = track.isEmpty
                    ? String(localized: "No speech was recognised in this recording.")
                    : String(localized:
                        "\(track.cues.count) caption(s) from \(recognised.words.count) word(s).")
            } catch is CancellationError {
                status = String(localized: "Stopped. Nothing was changed.")
            } catch {
                // A cancelled analyzer surfaces as its own failure rather than as
                // `CancellationError`, so the task's own state is what decides which this was.
                status = Task.isCancelled
                    ? String(localized: "Stopped. Nothing was changed.")
                    : String(localized: "Could not transcribe: \(String(describing: error))")
            }
        }
        transcribing = run
        await run.value
    }

    /// Re-breaks the kept transcript for a new size or word cap, WITHOUT transcribing again —
    /// and therefore discarding text corrections, which is why the caller has to mean it.
    func rebuild(outputWidth: Int, outputHeight: Int, maximumWords: Int?,
                 pauses: [SilenceFinder.Span]) {
        guard let transcript = correctedTranscript else { return }
        track = CaptionTrack(cues: CaptionBuilder.cues(
            for: transcript,
            fits: CaptionArt.fits(style: style, outputWidth: outputWidth,
                                  outputHeight: outputHeight),
            maximumWords: maximumWords,
            pauses: pauses))
        publish()
    }

    // MARK: - editing

    /// The undo stack, handed in by whoever hosts this model. See `UndoRecording` for why it
    /// is a protocol rather than an `UndoManager`.
    ///
    /// **`@ObservationIgnored`, or every view that reads a caption also observes the undo
    /// stack** — and an `UndoManager` changes on every registration, which is every keystroke.
    @ObservationIgnored var undoRecorder: (any UndoRecording)?

    /// The cue a run of typing is currently in, so consecutive keystrokes are one undo step.
    /// `nil` between runs. Not observed, for `undoManager`'s reason.
    @ObservationIgnored private var typingRun: Int?

    /// Replaces the whole track, undoably.
    ///
    /// **One place, because every edit below is a whole-track replacement.** `CaptionTrack` is a
    /// value: the cheapest correct undo is the previous value. Registering at each call site
    /// would be eight chances to forget the ninth, and the one forgotten is the one a person
    /// loses work to.
    ///
    /// **Symmetric by construction.** The closure calls this same method, so undoing registers
    /// its own redo and ⇧⌘Z works without a second mechanism.
    ///
    /// **An edit that changed nothing is not a step.** `setText` runs on every keystroke,
    /// including the ones that retype the same character; a no-op registered as a step is a ⌘Z
    /// that appears to do nothing.
    private func change(_ name: String, to next: CaptionTrack, typingAt index: Int? = nil) {
        guard next != track else { return }
        // **Typing coalesces into one step per cue.** Registering per keystroke means ⌘Z walks
        // back a character at a time, which is not what undo means to anybody. The first
        // keystroke in a cue registers the pre-typing track; the rest of that run register
        // nothing, so one ⌘Z restores the line as it was before the run began. Any other edit,
        // or a keystroke in a different cue, ends the run.
        let continuesRun = index != nil && index == typingRun
        if !continuesRun {
            let previous = track
            let previousRun = typingRun
            // **Symmetric by construction.** The closure calls this same method, so undoing
            // registers its own redo and ⇧⌘Z works without a second mechanism. `self` is
            // captured strongly: the step is worthless if the model it restores has gone.
            undoRecorder?.register(name) { [self] in
                typingRun = previousRun
                change(name, to: previous)
            }
        }
        typingRun = index
        track = next
        publish()
    }

    /// Ends the current typing run, so the next keystroke starts a new undo step. Called when
    /// the caret leaves a line — which is what `CaptionField.onCommit` already reports.
    func endTypingRun() { typingRun = nil }

    func setText(_ text: String, at index: Int) {
        change(String(localized: "Edit Caption"),
               to: track.replacingText(at: index, with: text), typingAt: index)
    }

    func remove(at index: Int) {
        change(String(localized: "Delete Caption"), to: track.removing(at: index))
    }

    /// **The three edits that could not be made before.** Text could be retyped and a line
    /// deleted, and that was the whole of it — a cue whose timing was wrong could not be
    /// corrected at all. Each clamps against its neighbours in `CaptionTrack` rather than
    /// refusing, so a nudge at the end of the room available does as much as it can.
    func retime(at index: Int, start: Nanoseconds, end: Nanoseconds) {
        change(String(localized: "Retime Caption"),
               to: track.retiming(at: index, start: start, end: end))
    }

    func split(at index: Int, atCharacter offset: Int) {
        change(String(localized: "Split Caption"),
               to: track.splitting(at: index, atCharacter: offset))
    }

    func merge(at index: Int) {
        change(String(localized: "Merge Captions"), to: track.merging(at: index))
    }

    func snap(at index: Int, to pauses: [SilenceFinder.Span]) {
        change(String(localized: "Snap Caption"), to: track.snapping(at: index, to: pauses))
    }

    /// One correction applied to every line that has the same run in it, and remembered.
    ///
    /// **Both, because they answer different halves of the same question.** Replacing fixes the
    /// captions that exist; adding the corrected spelling to `spokenTerms` means transcribing
    /// this recording again does not undo the work — `Transcript.correcting(terms:)` puts it
    /// back. Doing only the first is a correction that survives until somebody presses
    /// Transcribe; doing only the second changes nothing on screen now.
    func applyEverywhere(_ edit: RunEdit, correctedWord: String?) {
        track = track.replacing(edit.was, with: edit.now)
        if let correctedWord, addTerm(correctedWord) { }
        publish()
    }

    func setBurnsIn(_ value: Bool) {
        burnsIn = value
        publish()
    }

    /// Adds a term, trimmed, refusing an empty one and a duplicate. **Case-insensitively
    /// duplicate**: two spellings of one name are two answers to the same question, and the
    /// second would be picked or not depending on which came first in the list.
    func addTerm(_ term: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !spokenTerms.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return false }
        spokenTerms.append(trimmed)
        return true
    }

    func removeTerm(at index: Int) {
        guard spokenTerms.indices.contains(index) else { return }
        spokenTerms.remove(at: index)
    }

    func restoreTerms(_ terms: [String]) { spokenTerms = terms }

    func setStyle(_ value: CaptionStyle) {
        style = value
        publish()
    }

    /// Applies a saved project's captions.
    func restore(track: CaptionTrack, style: CaptionStyle, burnsIn: Bool) {
        self.track = track
        self.style = style
        self.burnsIn = burnsIn
        publish()
    }

    // MARK: - the sidecar

    /// Reads an `.srt` or `.vtt` somebody edited elsewhere, back into this recording's captions.
    ///
    /// **The file is in the EXPORT's clock and the track is in the recording's**, because that
    /// is what `exportSidecar` wrote — so every cue is mapped back through the same edit. A cue
    /// whose output time falls past the end of the edit has no source instant and is counted
    /// rather than placed at zero.
    ///
    /// **Replaces rather than merges.** A file somebody corrected IS the answer; offering to
    /// merge it with what is here would need a rule for which of two versions of a line wins,
    /// and there is no such rule that is not a guess.
    @MainActor
    func importSidecar(edit: EditTimeline?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SubtitleFile.Format.allCases.compactMap {
            UTType(filenameExtension: $0.fileExtension)
        } + [.plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let reading = try SubtitleFile.read(try String(contentsOf: url, encoding: .utf8))
            var placed: [CaptionCue] = []
            var unplaceable = 0
            for cue in reading.track.cues {
                guard let edit else { placed.append(cue); continue }
                guard let start = edit.sourceTime(atOutput: cue.start),
                      let end = edit.sourceTime(atOutput: cue.end), end.rawValue > start.rawValue
                else { unplaceable += 1; continue }
                placed.append(CaptionCue(text: cue.text, start: start, end: end))
            }
            guard !placed.isEmpty else {
                status = String(localized:
                    "None of \(reading.track.cues.count) cue(s) fall inside this edit.")
                return
            }
            track = CaptionTrack(cues: placed)
            publish()

            var note = "Read \(placed.count) cue(s) from \(url.lastPathComponent)."
            if !reading.refused.isEmpty {
                note += " \(reading.refused.count) line(s) could not be read"
                    + " (first at line \(reading.refused[0].line))."
            }
            if reading.overlapsTrimmed > 0 {
                note += " \(reading.overlapsTrimmed) overlapping cue(s) were trimmed."
            }
            if unplaceable > 0 { note += " \(unplaceable) fell outside the edit." }
            // Word runs are not in a sidecar, so the highlight has nothing to point at until
            // this recording is transcribed again. Said, rather than left to look like the
            // style being broken.
            if style.highlightsSpokenWord {
                note += " Word-by-word highlighting is off for these."
            }
            status = note
        } catch SubtitleFile.ReadError.noCues {
            status = String(localized: "\(url.lastPathComponent) has no subtitles in it.")
        } catch {
            status = String(localized:
                "Could not read \(url.lastPathComponent): \(String(describing: error))")
        }
    }

    /// Writes an `.srt` or `.vtt` beside wherever a person chooses, retimed through `edit` so
    /// the cues line up with the exported video rather than with the uncut recording.
    @MainActor
    func exportSidecar(format: SubtitleFile.Format, edit: EditTimeline?, defaultName: String) {
        let retimed = edit.map { track.retimed(through: $0) } ?? track
        guard !retimed.isEmpty else {
            status = String(localized: "There are no captions to export.")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        panel.nameFieldStringValue = "\(defaultName).\(format.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SubtitleFile.text(for: retimed, format: format)
                .write(to: url, atomically: true, encoding: .utf8)
            status = String(localized:
                "Wrote \(retimed.cues.count) cue(s) to \(url.lastPathComponent).")
        } catch {
            status = String(localized:
                "Could not write \(url.lastPathComponent): \(String(describing: error))")
        }
    }

    /// The one place the model and the compositor's statics are connected — `StageStyleModel`'s
    /// arrangement, for the same reason: a static is not observable, and AVFoundation owns
    /// every compositor instance so it cannot be an argument.
    private func publish() {
        StageCompositor.captions = track
        StageCompositor.captionStyle = style
        StageCompositor.burnsInCaptions = burnsIn
    }
}

/// The captions tab. A list a person reads down, which is what an inspector is for.
struct CaptionsPanel: View {
    let model: CaptionsModel
    let mediaURL: URL
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

    @State private var maximumWords: Int?
    /// Why a chosen font did not take, or `nil`. Said rather than left to look like the picker
    /// did nothing: a copy that fails silently is a font somebody chose and cannot find.
    @State private var fontFailure: String?
    /// The name being typed. Cleared on add, so the field is ready for the next one.
    @State private var newTerm = ""
    /// Which row has the caret. Also what decides whether the list follows the playhead: a list
    /// that scrolled itself while somebody was typing in it would move the field out from under
    /// them.
    @FocusState private var focused: Int?
    /// A correction worth offering to apply everywhere, with how many other lines it reaches.
    /// What the cue list remembers. See `CaptionListState` — it is a class because the list
    /// itself is a value SwiftUI throws away between redraws.
    @State private var listState = CaptionListState()

    var body: some View {
        // **`ScrollViewReader` around the LIST, and one row per cue inside it.** Both were wrong
        // together: the cues were built into a `VStack` inside a single `Section` row, so a
        // 270-cue recording built 270 views before showing one, and the scroll that follows the
        // playhead was a scroll view nested inside another one. A row each is lazy and is what
        // `scrollTo` addresses.
        ScrollViewReader { scroller in
            List {
                Section("Transcript") { transcriptControls }
                if !model.track.isEmpty {
                    Section("Preset") { presetControls }
                    Section("Look") { lookControls }
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
                    Section { Text(status).font(Type.detail).foregroundStyle(.secondary) }
                }
            }
            .listStyle(.sidebar)
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

    @ViewBuilder private var transcriptControls: some View {
        if model.isTranscribing {
            transcriptionSteps
        } else {
            Button(model.track.isEmpty ? "Transcribe" : "Transcribe again") {
                Task {
                    await model.transcribe(mediaURL: mediaURL, outputWidth: outputWidth,
                                           outputHeight: outputHeight,
                                           maximumWords: maximumWords, pauses: pauses)
                    onChange()
                }
            }
            .disabled(!model.canTranscribe)

            if !OnDeviceTranscription.isAvailable {
                // Said rather than left as a button that always fails.
                Text("This Mac has no on-device speech model available.")
                    .font(Type.detail).foregroundStyle(.secondary)
            }
        }

        Picker("Language", selection: Binding(
            get: { model.locale?.identifier(.bcp47) ?? "" },
            set: { model.locale = $0.isEmpty ? nil : Locale(identifier: $0) })) {
            Text("This Mac's language").tag("")
            ForEach(model.availableLocales, id: \.identifier) { locale in
                // Installed languages are marked, because choosing one that is not starts a
                // several-hundred-megabyte download and a person should see which is which
                // BEFORE they press the button rather than after.
                Text(Self.name(of: locale)
                     + (model.installedLocales.contains(locale.identifier(.bcp47))
                        ? "" : " \u{2014} downloads"))
                    .tag(locale.identifier(.bcp47))
            }
        }
        .task { await model.refreshLocales() }

        if model.languageLooksWrong {
            Label("What came back does not look like that language. Try another one.",
                  systemImage: "exclamationmark.triangle")
                .font(Type.detail).foregroundStyle(Signal.paused)
        }

        // **Said once, where the choice is made.** A sentence that switches between Chinese and
        // English part-way is transcribed by whichever model was chosen, and the other
        // language's words come back wrong — a property of the on-device model, not of how it is
        // driven. Leaving a person to discover that from a page of nonsense is the worse option.
        Text("One language per recording. A sentence that switches part-way is recognised as the chosen language throughout.")
            .font(Type.detail).foregroundStyle(.secondary)

        Picker("Words per line", selection: $maximumWords) {
            Text("As many as fit").tag(Int?.none)
            ForEach([1, 2, 3, 4, 5, 6], id: \.self) { Text("\($0)").tag(Int?.some($0)) }
        }
        .onChange(of: maximumWords) {
            model.rebuild(outputWidth: outputWidth, outputHeight: outputHeight,
                          maximumWords: maximumWords, pauses: pauses)
            onChange()
        }
        .disabled(model.transcript == nil)
    }

    /// The named starting points, above every slider because that is the order a person works
    /// in: pick the one closest, then move what is wrong with it.
    ///
    /// **"Custom" is a real row, not a placeholder.** It is selected — and cannot be picked —
    /// the moment a control moves the style off every preset, because a picker still naming
    /// "Broadcast" after four sliders moved would be naming something that is not on the screen.
    /// `CaptionStyle.matchingPreset` decides, on full equality.
    /// A list of names the recogniser has never heard, and what it can and cannot do about them.
    ///
    /// **The sentence under it is the feature.** Every surveyed recorder offers a list like this
    /// and the ones built on a downloaded Whisper-class model really do bias recognition with it.
    /// This one cannot — measured, twice, in `docs/design/teaching-the-recogniser-a-word.md` —
    /// so it corrects the spelling of what came back, and says that rather than letting somebody
    /// read the control as accuracy and blame the recording when a name is still wrong.
    @ViewBuilder private var termControls: some View {
        HStack {
            TextField("A name, spelled your way", text: $newTerm)
                .onSubmit(addTerm)
            Button("Add") { addTerm() }
                .disabled(newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        ForEach(Array(model.spokenTerms.enumerated()), id: \.offset) { index, term in
            HStack {
                Text(verbatim: term)
                Spacer()
                Button {
                    model.removeTerm(at: index)
                    rebuildAndPublish()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove this name")
            }
        }
        Text("These correct the SPELLING of what was recognised. They cannot make the recogniser hear a name it does not know — a name it heard as something else entirely stays that way.")
            .font(Type.detail).foregroundStyle(.secondary)
    }

    private func addTerm() {
        guard model.addTerm(newTerm) else { return }
        newTerm = ""
        rebuildAndPublish()
    }

    /// A term list change re-breaks the cues, because a corrected word is a different width and
    /// may not fit the line it was on. Cheap — `rebuild` re-breaks a kept transcript rather than
    /// recognising anything.
    private func rebuildAndPublish() {
        model.rebuild(outputWidth: outputWidth, outputHeight: outputHeight,
                      maximumWords: maximumWords, pauses: pauses)
        onChange()
    }

    /// The tag for the system-appearance entry. **Not a `CaptionStyle.presets` member**: those
    /// are fixed values in the package, and this one is read from the machine every time it is
    /// chosen — a person who changes their system captions and comes back should get the new
    /// ones, not a copy taken the first time.
    private static let systemPresetName = "\u{1}system"

    @ViewBuilder private var presetControls: some View {
        Picker("Preset", selection: Binding(
            get: { model.style.matchingPreset?.name },
            set: { name in
                if name == Self.systemPresetName {
                    model.setStyle(SystemCaptionAppearance.read().style())
                    onChange()
                    return
                }
                guard let preset = CaptionStyle.presets.first(where: { $0.name == name })
                else { return }
                model.setStyle(preset.style)
                onChange()
            })) {
            ForEach(CaptionStyle.presets, id: \.name) { preset in
                Text(LocalizedStringKey(preset.name)).tag(String?.some(preset.name))
            }
            // **The fifth preset is not a preset — it is what this Mac is already set to.**
            // Somebody who needs captions has tuned System Settings once for every app on the
            // machine; offering the four above and not that one asks them to make a decision
            // they already made. See `SystemCaptionAppearance`.
            Divider()
            Text("Match my system captions").tag(String?.some(Self.systemPresetName))
            // Only present while it is the answer, so the list is not permanently one row
            // longer for a state most recordings are never in.
            if model.style.matchingPreset == nil {
                Divider()
                Text("Custom").tag(String?.none)
            }
        }
        if let detail = model.style.matchingPreset?.detail {
            Text(LocalizedStringKey(detail)).font(Type.detail).foregroundStyle(.secondary)
        } else {
            Text("Edited from a preset. Picking one above replaces every value below.")
                .font(Type.detail).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var lookControls: some View {
        Toggle("Burn into the video", isOn: Binding(
            get: { model.burnsIn },
            set: { model.setBurnsIn($0); onChange() }))
        Text("A burnt-in caption cannot be turned off, translated or searched. A sidecar file can.")
            .font(Type.detail).foregroundStyle(.secondary)

        Slider(value: Binding(get: { model.style.heightFraction },
                              set: { model.setStyle(styleChanging(height: $0)); onChange() }),
               in: 0.02...0.09) { Text("Size") }
        Slider(value: Binding(get: { model.style.bottomInsetFraction },
                              set: { model.setStyle(styleChanging(inset: $0)); onChange() }),
               in: 0...0.4) { Text("Height above the bottom") }
        Slider(value: Binding(get: { model.style.backgroundOpacity },
                              set: { model.setStyle(styleChanging(plate: $0)); onChange() }),
               in: 0...1) { Text("Plate") }

        // **Six controls that were literals in `CaptionStyle.asTextStyle`.** Every one of them
        // was already drawable — the conversion passed `x: 0.5`, `.center`, `isBold: false`, a
        // black plate and no shadow as constants, so a caption could be sized and raised and
        // nothing else.
        Picker("Alignment", selection: Binding(
            get: { model.style.alignment },
            set: { model.setStyle(model.style.changing(alignment: $0)); onChange() })) {
            ForEach(TextAnchor.allCases, id: \.self) { anchor in
                Text(LocalizedStringKey(anchor.displayName)).tag(anchor)
            }
        }
        // Only where it can do anything: a centred caption is at the middle by definition, and
        // a slider that moves nothing is a slider people learn not to trust.
        if model.style.alignment != .center {
            Slider(value: Binding(
                get: { model.style.horizontalFraction },
                set: { model.setStyle(model.style.changing(horizontalFraction: $0)); onChange() }),
                   in: 0...1) { Text("Across the frame") }
        }
        Toggle("Bold", isOn: Binding(
            get: { model.style.isBold },
            set: { model.setStyle(model.style.changing(isBold: $0)); onChange() }))
        ColorPicker("Text", selection: Binding(
            get: { Color(red: model.style.red, green: model.style.green, blue: model.style.blue) },
            set: { colour in
                let rgb = Self.components(of: colour)
                model.setStyle(model.style.changing(red: rgb.red, green: rgb.green,
                                                    blue: rgb.blue))
                onChange()
            }), supportsOpacity: false)
        // Offered only when there is a plate to colour. At zero opacity it draws nothing, and a
        // colour well for an invisible rectangle is a control that answers nothing.
        if model.style.backgroundOpacity > 0 {
            ColorPicker("Plate colour", selection: Binding(
                get: { Color(red: model.style.plateRed, green: model.style.plateGreen,
                             blue: model.style.plateBlue) },
                set: { colour in
                    let rgb = Self.components(of: colour)
                    model.setStyle(model.style.changing(plateRed: rgb.red, plateGreen: rgb.green,
                                                        plateBlue: rgb.blue))
                    onChange()
                }), supportsOpacity: false)
        }
        fontRow

        // **Offered above the plate and the shadow, because it is the one that reads over
        // anything.** A plate covers the picture and a shadow softens an edge; an outline
        // follows the letters, so a caption crossing a light region and a dark one in the same
        // line stays legible without a rectangle across the frame.
        Slider(value: Binding(
            get: { model.style.outlineWidthFraction },
            set: { model.setStyle(model.style.changing(outlineWidthFraction: $0)); onChange() }),
               in: 0...0.14) { Text("Outline") }
        if model.style.outlineWidthFraction > 0 {
            ColorPicker("Outline colour", selection: Binding(
                get: { Color(red: model.style.outlineRed, green: model.style.outlineGreen,
                             blue: model.style.outlineBlue) },
                set: { colour in
                    let rgb = Self.components(of: colour)
                    model.setStyle(model.style.changing(outlineRed: rgb.red,
                                                        outlineGreen: rgb.green,
                                                        outlineBlue: rgb.blue))
                    onChange()
                }), supportsOpacity: false)
        }

        Slider(value: Binding(
            get: { model.style.shadowOpacity },
            set: { model.setStyle(model.style.changing(shadowOpacity: $0,
                                                       shadowBlurFraction: $0 > 0
                                                           ? max(model.style.shadowBlurFraction,
                                                                 0.004)
                                                           : model.style.shadowBlurFraction))
                   onChange() }),
               in: 0...1) { Text("Shadow") }
        Text("A shadow separates the words from what is behind them without covering it, which is what a plate does instead.")
            .font(Type.detail).foregroundStyle(.secondary)

        // **The recogniser has been giving word times all along and nothing read them.**
        // `TranscribedWord.start`/`.end` were stored, retimed through cuts and clipped at cut
        // boundaries, and never drawn.
        Toggle("Highlight the word being said", isOn: Binding(
            get: { model.style.highlightsSpokenWord },
            set: { model.setStyle(model.style.changing(highlightsSpokenWord: $0)); onChange() }))
        if model.style.highlightsSpokenWord {
            Slider(value: Binding(
                get: { model.style.unspokenOpacity },
                set: { model.setStyle(model.style.changing(unspokenOpacity: $0)); onChange() }),
                   in: 0.15...1) { Text("Other words") }
            if let transcript = model.transcript, transcript.words.isEmpty {
                // Said rather than left to fail silently: a language whose model reports no word
                // times produces a toggle that does nothing, and a person would blame the app.
                Label("This language's model gave no word times, so the whole line stays lit.",
                      systemImage: "info.circle")
                    .font(Type.detail).foregroundStyle(.secondary)
            }
        }

        HStack(spacing: Space.snug) {
            ForEach(SubtitleFile.Format.allCases, id: \.self) { format in
                Button("Export .\(format.fileExtension)") {
                    model.exportSidecar(
                        format: format, edit: edit,
                        defaultName: mediaURL.deletingPathExtension().lastPathComponent)
                }
            }
            Spacer()
            Button("Import…") {
                model.importSidecar(edit: edit)
                onChange()
            }
        }
        // **The escape hatch, and it is worth saying it is one.** Whatever this panel cannot do,
        // a dedicated subtitle editor can — and an export with no import is a one-way door.
        Text("Import replaces every caption with the file's. A sidecar carries no word times, so highlighting stays off for what comes back until this recording is transcribed again.")
            .font(Type.detail).foregroundStyle(.secondary)
    }


    /// The font a caption is set in: the project's own, or the system's.
    ///
    /// **The file is copied into the project, not referenced.** `adoptMusic`'s argument
    /// exactly: a caption pointing at a `.ttf` on somebody's Desktop is a caption that changes
    /// when the file moves, and a project opened on another machine would silently fall back to
    /// a different width. Inside the package it travels with the recording.
    ///
    /// **A name rather than a preview of the type.** Rendering a sample means loading the font
    /// into this view, and the view is not where fonts are resolved — `TextArt` is, once, for
    /// both measurement and drawing. A second loader here is the second answer that seam exists
    /// to prevent.
    @ViewBuilder private var fontRow: some View {
        HStack(spacing: Space.snug) {
            Text("Font").font(Type.label)
            Spacer(minLength: Space.tight)
            Text(model.style.fontFilename.map { LocalizedStringKey($0) }
                    ?? LocalizedStringKey("System"))
                .font(Type.detail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Choose\u{2026}") { chooseFont() }
            if model.style.fontFilename != nil {
                Button("System") {
                    model.setStyle(model.style.changing(fontFilename: .some(nil)))
                    onChange()
                }
            }
        }
        if let fontFailure {
            Label(LocalizedStringKey(fontFailure), systemImage: "exclamationmark.triangle")
                .font(Type.detail).foregroundStyle(.secondary)
        }
    }

    /// Copies a chosen font into the project and points the style at it.
    ///
    /// **The font cache is cleared on the way through.** It is keyed on a filename, and
    /// replacing a `Brand.ttf` with a different `Brand.ttf` would otherwise keep drawing the
    /// first — which reads as the new font not working rather than as a stale cache.
    private func chooseFont() {
        guard let source = Self.chooseFontFile() else { return }
        let packageURL = ProjectStore.packageURL(forMediaAt: mediaURL)
        let directory = packageURL.appending(path: TextArt.fontDirectory,
                                             directoryHint: .isDirectory)
        let name = source.lastPathComponent
        guard StageBackground.isSafeImageFilename(name) else {
            fontFailure = "\(name) is not a name this can use."
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            let destination = directory.appending(path: name)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            fontFailure = "Could not copy \(name) into the project: \(error)"
            return
        }
        TextArt.forgetProjectFonts()
        fontFailure = nil
        model.setStyle(model.style.changing(fontFilename: .some(name)))
        onChange()
    }

    /// The open panel, fonts only.
    @MainActor
    private static func chooseFontFile() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.font]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// A colour's own components, in the space the renderer draws in.
    ///
    /// **Converted to sRGB rather than read raw.** A `Color` from the picker can be in the
    /// display's P3 space, and its raw components in that space are different numbers for the
    /// same colour — a red picked on a P3 display would export as a duller one. sRGB is what
    /// `CoreImageFrameRenderer` composites in and what the recording is pinned to.
    static func components(of colour: Color) -> (red: Double, green: Double, blue: Double) {
        let converted = NSColor(colour).usingColorSpace(.sRGB) ?? NSColor(colour)
        return (Double(converted.redComponent), Double(converted.greenComponent),
                Double(converted.blueComponent))
    }

    private func styleChanging(height: Double? = nil, inset: Double? = nil,
                               plate: Double? = nil) -> CaptionStyle {
        model.style.changing(heightFraction: height, bottomInsetFraction: inset,
                             backgroundOpacity: plate)
    }

    /// A language's own name where the system knows one, so a person reading a list of
    /// languages reads it in the languages themselves.
    static func name(of locale: Locale) -> String {
        locale.localizedString(forIdentifier: locale.identifier)
            ?? Locale.current.localizedString(forIdentifier: locale.identifier)
            ?? locale.identifier(.bcp47)
    }

    /// The whole shape of the wait: every step, the finished ones ticked with what they took,
    /// the running one lit, the rest ahead.
    ///
    /// **One line saying "Listening…" answers "is it stuck?" with a shrug.** A person watching a
    /// spinner cannot tell a slow step from a hung one, and the slow step here is genuinely slow
    /// — it scales with the recording. Showing the list says which of three this is, that the
    /// two before it took a second each, and that this one is the long one.
    ///
    /// `installingModel` is not in the list because it runs once per language ever; when it IS
    /// running it appears in place, rather than standing in the list every other time as a step
    /// that will not happen.
    @ViewBuilder private var transcriptionSteps: some View {
        let running = model.phase
        let steps: [TranscriptionProgress] = {
            guard case .installingModel = running else { return TranscriptionProgress.ordinarySteps }
            var all = TranscriptionProgress.ordinarySteps
            all.insert(running!, at: 1)
            return all
        }()

        ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
            let done = running.map { $0.hasPassed(step) } ?? false
            let isRunning = running == step
            HStack(spacing: Space.snug) {
                if done {
                    // No colour: `Signal` has none for "done", and the accent in this app marks
                    // the primary action rather than state — the tick is already the difference.
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
                } else if isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "circle").foregroundStyle(.tertiary)
                }
                Text(LocalizedStringKey(step.displayName))
                    .foregroundStyle(done || isRunning ? AnyShapeStyle(.primary)
                                                       : AnyShapeStyle(.secondary))
                Spacer()
                if let seconds = model.finishedSteps.first(where: { $0.step == step })?.seconds {
                    Text(verbatim: String(format: "%.1fs", seconds))
                        .font(Type.readout).foregroundStyle(.secondary)
                }
            }
            .font(Type.label)
            if isRunning, let detail = step.detail {
                Text(LocalizedStringKey(detail))
                    .font(Type.detail).foregroundStyle(.secondary)
            }
        }

        // **The work survives leaving this panel**, and saying so is most of what it is for: a
        // person who does not know that sits and watches. The model outlives the tab.
        Text("You can look at something else while this runs.")
            .font(Type.detail).foregroundStyle(.secondary)
        Button("Stop") { model.cancelTranscription() }
    }
}
