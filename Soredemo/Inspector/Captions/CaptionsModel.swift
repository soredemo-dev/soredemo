import Capture
import Compositing
import Foundation
import Observation
import Overlays
import Render
import Timeline

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
    /// **An edit that changed nothing is not a step.** `setText` runs on every keystroke,
    /// including the ones that retype the same character; a no-op registered as a step is a ⌘Z
    /// that appears to do nothing.
    ///
    /// **`terms` moves the names list with the lines**, for the one edit that changes both —
    /// `docs/design/2026-10-24-every-caption-edit-is-undoable.md`. `nil` leaves the list.
    private func change(_ name: String, to next: CaptionTrack, typingAt index: Int? = nil,
                        terms nextTerms: [String]? = nil) {
        guard next != track else { return }
        // **Typing coalesces into one step per cue.** Registering per keystroke means ⌘Z walks
        // back a character at a time, which is not what undo means to anybody. The first
        // keystroke in a cue registers the pre-typing track; the rest of that run register
        // nothing, so one ⌘Z restores the line as it was before the run began. Any other edit,
        // or a keystroke in a different cue, ends the run.
        let continuesRun = index != nil && index == typingRun
        if !continuesRun {
            let previous = track
            let previousTerms = nextTerms.map { _ in spokenTerms }
            let previousRun = typingRun
            // **Symmetric by construction.** The closure calls this same method, so undoing
            // registers its own redo and ⇧⌘Z works without a second mechanism. `self` is
            // captured strongly: the step is worthless if the model it restores has gone.
            undoRecorder?.register(name) { [self] in
                typingRun = previousRun
                change(name, to: previous, terms: previousTerms)
            }
        }
        typingRun = index
        track = next
        if let nextTerms { spokenTerms = nextTerms }
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
    ///
    /// **One undo step for both.** It wrote the track directly until 2026-10-24, so "Fix them
    /// too" could not be undone at all — `docs/design/2026-10-24-every-caption-edit-is-undoable.md`.
    func applyEverywhere(_ edit: RunEdit, correctedWord: String?) {
        let terms = correctedWord.map { Self.adding($0, to: spokenTerms) } ?? spokenTerms
        change(String(localized: "Fix Captions Everywhere"),
               to: track.replacing(edit.was, with: edit.now), terms: terms)
    }

    func setBurnsIn(_ value: Bool) {
        burnsIn = value
        publish()
    }

    /// Adds a term, trimmed, refusing an empty one and a duplicate. **Case-insensitively
    /// duplicate**: two spellings of one name are two answers to the same question, and the
    /// second would be picked or not depending on which came first in the list.
    func addTerm(_ term: String) -> Bool {
        let next = Self.adding(term, to: spokenTerms)
        guard next != spokenTerms else { return false }
        spokenTerms = next
        return true
    }

    /// `terms` with `term` added, trimmed — or unchanged when it is empty or already there.
    private static func adding(_ term: String, to terms: [String]) -> [String] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !terms.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return terms }
        return terms + [trimmed]
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
    ///
    /// **Given the file rather than asking for it.** The open panel is the panel's, as every
    /// other panel is its window's, and this half can then be tested with a file.
    func importSidecar(from url: URL, edit: EditTimeline?) {
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
            // **Undoable, because it replaces.** An import over corrected captions used to
            // discard the corrections with no way back.
            change(String(localized: "Import Subtitles"), to: CaptionTrack(cues: placed))

            // **One whole sentence per fact, each its own key.** This used to be one `String`
            // grown with `+=`, which no table could reach — the import report was English in
            // every language.
            var report = [String(localized: "Read \(placed.count) cue(s) from \(url.lastPathComponent).")]
            if !reading.refused.isEmpty {
                report.append(String(localized:
                    "\(reading.refused.count) line(s) could not be read (first at line \(reading.refused[0].line))."))
            }
            if reading.overlapsTrimmed > 0 {
                report.append(String(localized: "\(reading.overlapsTrimmed) overlapping cue(s) were trimmed."))
            }
            if unplaceable > 0 { report.append(String(localized: "\(unplaceable) fell outside the edit.")) }
            // Word runs are not in a sidecar, so the highlight has nothing to point at until
            // this recording is transcribed again. Said, rather than left to look like the
            // style being broken.
            if style.highlightsSpokenWord {
                report.append(String(localized: "Word-by-word highlighting is off for these."))
            }
            status = report.joined(separator: " ")
        } catch SubtitleFile.ReadError.noCues {
            status = String(localized: "\(url.lastPathComponent) has no subtitles in it.")
        } catch {
            status = String(localized:
                "Could not read \(url.lastPathComponent): \(String(describing: error))")
        }
    }

    /// Writes an `.srt` or `.vtt` beside wherever a person chooses, retimed through `edit` so
    /// the cues line up with the exported video rather than with the uncut recording.
    func exportSidecar(format: SubtitleFile.Format, edit: EditTimeline?, to url: URL) {
        let retimed = edit.map { track.retimed(through: $0) } ?? track
        guard !retimed.isEmpty else {
            status = String(localized: "There are no captions to export.")
            return
        }
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

    /// True when there is a caption to export; otherwise says so. Asked before the save panel
    /// opens, so nobody chooses a place for a file that will not be written. `exportSidecar`
    /// still checks what survives the edit, which can be nothing when this is not.
    func readyToExport() -> Bool {
        guard track.isEmpty else { return true }
        status = String(localized: "There are no captions to export.")
        return false
    }

    // MARK: - the font

    /// Why a chosen font did not take, or `nil`. Said rather than left to look like the picker
    /// did nothing: a copy that fails silently is a font somebody chose and cannot find.
    private(set) var fontFailure: String?

    /// Copies a chosen font into the project and points the style at it.
    ///
    /// **The file is copied into the project, not referenced.** `EditorPreview.adoptMusic`'s
    /// argument exactly: a caption pointing at a `.ttf` on somebody's Desktop is a caption that
    /// changes when the file moves, and a project opened on another machine would silently fall
    /// back to a different width. Inside the package it travels with the recording.
    ///
    /// **The font cache is cleared on the way through.** It is keyed on a filename, and
    /// replacing a `Brand.ttf` with a different `Brand.ttf` would otherwise keep drawing the
    /// first — which reads as the new font not working rather than as a stale cache.
    func adoptFont(_ source: URL, mediaURL: URL) {
        let name = source.lastPathComponent
        guard StageBackground.isSafeImageFilename(name) else {
            fontFailure = String(localized: "\(name) is not a name this can use.")
            return
        }
        do {
            try ProjectStore.copyIntoPackage(source, directory: TextArt.fontDirectory,
                                             mediaURL: mediaURL)
        } catch {
            fontFailure = String(localized: "Could not copy \(name) into the project: \(String(describing: error))")
            return
        }
        TextArt.forgetProjectFonts()
        fontFailure = nil
        setStyle(style.changing(fontFilename: .some(name)))
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
