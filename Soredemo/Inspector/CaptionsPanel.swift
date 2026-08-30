import AppKit
import AVFoundation
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
    /// Draw the captions into the picture. Off by default: a burnt-in caption cannot be turned
    /// off, and a person who wanted a sidecar has not asked for one in their video.
    private(set) var burnsIn = false
    private(set) var phase: TranscriptionProgress?
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
    var canTranscribe: Bool { OnDeviceTranscription.isAvailable && !isTranscribing }

    init() { publish() }

    // MARK: - producing

    /// Transcribes and breaks the result into lines. `outputWidth`/`outputHeight` decide where
    /// lines break — see `CaptionArt.fits`.
    @MainActor
    func transcribe(mediaURL: URL, outputWidth: Int, outputHeight: Int,
                    maximumWords: Int?) async {
        phase = .extractingAudio
        status = nil
        defer { phase = nil }
        do {
            let source = OnDeviceTranscription(locale: locale)
            let recognised = try await source.transcript(of: mediaURL, range: nil,
                                                         onProgress: { [weak self] progress in
                Task { @MainActor in self?.phase = progress }
            })
            transcript = recognised
            languageLooksWrong = OnDeviceTranscription.languageLooksWrong(recognised)
            rebuild(outputWidth: outputWidth, outputHeight: outputHeight,
                    maximumWords: maximumWords)
            status = track.isEmpty
                ? "No speech was recognised in this recording."
                : "\(track.cues.count) caption(s) from \(recognised.words.count) word(s)."
        } catch {
            status = "Could not transcribe: \(error)"
        }
    }

    /// Re-breaks the kept transcript for a new size or word cap, WITHOUT transcribing again —
    /// and therefore discarding text corrections, which is why the caller has to mean it.
    func rebuild(outputWidth: Int, outputHeight: Int, maximumWords: Int?) {
        guard let transcript = correctedTranscript else { return }
        track = CaptionTrack(cues: CaptionBuilder.cues(
            for: transcript,
            fits: CaptionArt.fits(style: style, outputWidth: outputWidth,
                                  outputHeight: outputHeight),
            maximumWords: maximumWords))
        publish()
    }

    // MARK: - editing

    func setText(_ text: String, at index: Int) {
        track = track.replacingText(at: index, with: text)
        publish()
    }

    func remove(at index: Int) {
        track = track.removing(at: index)
        publish()
    }

    /// **The three edits that could not be made before.** Text could be retyped and a line
    /// deleted, and that was the whole of it — a cue whose timing was wrong could not be
    /// corrected at all. Each clamps against its neighbours in `CaptionTrack` rather than
    /// refusing, so a nudge at the end of the room available does as much as it can.
    func retime(at index: Int, start: Nanoseconds, end: Nanoseconds) {
        track = track.retiming(at: index, start: start, end: end)
        publish()
    }

    func split(at index: Int, atCharacter offset: Int) {
        track = track.splitting(at: index, atCharacter: offset)
        publish()
    }

    func merge(at index: Int) {
        track = track.merging(at: index)
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
                status = "None of \(reading.track.cues.count) cue(s) fall inside this edit."
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
            status = "\(url.lastPathComponent) has no subtitles in it."
        } catch {
            status = "Could not read \(url.lastPathComponent): \(error)"
        }
    }

    /// Writes an `.srt` or `.vtt` beside wherever a person chooses, retimed through `edit` so
    /// the cues line up with the exported video rather than with the uncut recording.
    @MainActor
    func exportSidecar(format: SubtitleFile.Format, edit: EditTimeline?, defaultName: String) {
        let retimed = edit.map { track.retimed(through: $0) } ?? track
        guard !retimed.isEmpty else {
            status = "There are no captions to export."
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
            status = "Wrote \(retimed.cues.count) cue(s) to \(url.lastPathComponent)."
        } catch {
            status = "Could not write \(url.lastPathComponent): \(error)"
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
    /// Where the playhead is, in the RECORDING's own time — the same clock a cue is stamped in,
    /// so no conversion happens here.
    let playhead: Nanoseconds
    /// Move the playhead. **The list is a way of navigating the recording**, not a table of its
    /// contents: a caption is corrected at the pace of playback, and a row that cannot be
    /// listened to is a row somebody has to find in the scrubber first.
    let onSeek: (Nanoseconds) -> Void

    @State private var maximumWords: Int?
    @State private var editingIndex: Int?
    @State private var draft = ""
    /// Why a chosen font did not take, or `nil`. Said rather than left to look like the picker
    /// did nothing: a copy that fails silently is a font somebody chose and cannot find.
    @State private var fontFailure: String?
    /// The name being typed. Cleared on add, so the field is ready for the next one.
    @State private var newTerm = ""
    /// Which cue's timing controls are open. Separate from `editingIndex`: correcting the words
    /// and correcting the span are different jobs, and showing both sets at once puts six
    /// controls under a line somebody wanted to retype.
    @State private var selectedIndex: Int?

    var body: some View {
        List {
            Section("Transcript") { transcriptControls }
            if !model.track.isEmpty {
                Section("Preset") { presetControls }
                Section("Look") { lookControls }
                Section("Lines") { lines }
            }
            if let status = model.status {
                Section { Text(status).font(Type.detail).foregroundStyle(.secondary) }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder private var transcriptControls: some View {
        if model.isTranscribing {
            HStack(spacing: Space.snug) {
                ProgressView().controlSize(.small)
                Text(phaseLabel).font(Type.detail).foregroundStyle(.secondary)
            }
        } else {
            Button(model.track.isEmpty ? "Transcribe" : "Transcribe again") {
                Task {
                    await model.transcribe(mediaURL: mediaURL, outputWidth: outputWidth,
                                           outputHeight: outputHeight,
                                           maximumWords: maximumWords)
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
        Text("One language per recording. A sentence that switches part-way is recognised as "
             + "the chosen language throughout.")
            .font(Type.detail).foregroundStyle(.secondary)

        Picker("Words per line", selection: $maximumWords) {
            Text("As many as fit").tag(Int?.none)
            ForEach([1, 2, 3, 4, 5, 6], id: \.self) { Text("\($0)").tag(Int?.some($0)) }
        }
        .onChange(of: maximumWords) {
            model.rebuild(outputWidth: outputWidth, outputHeight: outputHeight,
                          maximumWords: maximumWords)
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
        Text("These correct the SPELLING of what was recognised. They cannot make the "
             + "recogniser hear a name it does not know — a name it heard as something else "
             + "entirely stays that way.")
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
                      maximumWords: maximumWords)
        onChange()
    }

    @ViewBuilder private var presetControls: some View {
        Picker("Preset", selection: Binding(
            get: { model.style.matchingPreset?.name },
            set: { name in
                guard let preset = CaptionStyle.presets.first(where: { $0.name == name })
                else { return }
                model.setStyle(preset.style)
                onChange()
            })) {
            ForEach(CaptionStyle.presets, id: \.name) { preset in
                Text(LocalizedStringKey(preset.name)).tag(String?.some(preset.name))
            }
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
        Text("A shadow separates the words from what is behind them without covering it, which "
             + "is what a plate does instead.")
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
        Text("Import replaces every caption with the file's. A sidecar carries no word times, so "
             + "highlighting stays off for what comes back until this recording is transcribed "
             + "again.")
            .font(Type.detail).foregroundStyle(.secondary)
    }

    /// The index of the cue the playhead is inside, or `nil` between cues.
    private var currentIndex: Int? {
        model.track.cues.firstIndex { $0.contains(playhead) }
    }

    /// **A row per cue, and the row the playhead is in is lit.** The list and the transport are
    /// the same cursor seen twice: clicking a row moves the playhead to it, and playing moves
    /// the highlight. A list that did neither is a table of contents.
    ///
    /// `ScrollViewReader` keeps the lit row visible during playback. Scrolling only on a CHANGE
    /// of index, not on every playhead tick — a scroll issued sixty times a second while the
    /// same row stays current fights a person trying to look somewhere else in the list.
    @ViewBuilder private var lines: some View {
        ScrollViewReader { scroller in
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.track.cues.enumerated()), id: \.offset) { index, cue in
                    row(index: index, cue: cue).id(index)
                }
            }
            .onChange(of: currentIndex) {
                guard let currentIndex else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    scroller.scrollTo(currentIndex, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder private func row(index: Int, cue: CaptionCue) -> some View {
        let isCurrent = currentIndex == index
        VStack(alignment: .leading, spacing: Space.tight) {
            HStack(alignment: .firstTextBaseline) {
                Text(timecode(cue.start)).font(Type.readout)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.primary)
                                               : AnyShapeStyle(.secondary))
                Spacer()
                measurement(of: cue)
            }
            if editingIndex == index {
                TextField("Caption", text: $draft, axis: .vertical)
                    .onSubmit { commit(index) }
                editingControls(index: index)
            } else {
                Text(cue.text)
                    .font(Type.label)
                    // A recogniser gets a name or an acronym wrong far more often than it
                    // gets the timing wrong, so correcting text is the common gesture and
                    // it must not re-time the line.
                    .onTapGesture { editingIndex = index; draft = cue.text }
            }
            if selectedIndex == index { timingControls(index: index, cue: cue) }
        }
        .padding(.vertical, Space.hairline)
        .padding(.horizontal, Space.tight)
        .background(isCurrent ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: Glass.controlRadius, style: .continuous))
        // Anywhere that is not the text: move the playhead here and open this cue's controls.
        .contentShape(Rectangle())
        .onTapGesture {
            onSeek(cue.start)
            selectedIndex = selectedIndex == index ? nil : index
        }
    }

    /// A cue's own numbers, and the verdict when there is one.
    ///
    /// **The fault is a word, not a colour alone.** A red number tells somebody a line is wrong
    /// without telling them what to do, and the three faults have three different fixes — see
    /// `CaptionFault`. The reading speed is shown whatever the verdict, because the number is
    /// what a person adjusts against.
    @ViewBuilder private func measurement(of cue: CaptionCue) -> some View {
        let reading = cue.measurement
        HStack(spacing: Space.tight) {
            if let fault = reading.fault {
                Text(LocalizedStringKey(fault.displayName))
                    .font(Type.detail)
                    .foregroundStyle(Signal.record)
            }
            Text(verbatim: String(format: "%d · %.1f/s", reading.characters,
                                  reading.charactersPerSecond.isFinite
                                      ? reading.charactersPerSecond : 0))
                .font(Type.readout)
                .foregroundStyle(.secondary)
        }
    }

    /// Start and end, nudged. **A hundred milliseconds**, which is about three frames: a step
    /// small enough that two of them are a fine adjustment and large enough that a person is not
    /// pressing it thirty times. `CaptionTrack.retiming` clamps, so holding a button at the end
    /// of the room available stops rather than corrupting the neighbour.
    @ViewBuilder private func timingControls(index: Int, cue: CaptionCue) -> some View {
        HStack(spacing: Space.tight) {
            nudge("arrow.left.to.line", "Start earlier") {
                model.retime(at: index, start: shifted(cue.start, by: -Self.nudge.rawValue), end: cue.end)
            }
            nudge("arrow.right.to.line", "Start later") {
                model.retime(at: index, start: shifted(cue.start, by: Self.nudge.rawValue), end: cue.end)
            }
            Divider().frame(height: 12)
            nudge("arrow.left", "End earlier") {
                model.retime(at: index, start: cue.start, end: shifted(cue.end, by: -Self.nudge.rawValue))
            }
            nudge("arrow.right", "End later") {
                model.retime(at: index, start: cue.start, end: shifted(cue.end, by: Self.nudge.rawValue))
            }
            Spacer()
            nudge("arrow.triangle.merge", "Merge with the next line") {
                model.merge(at: index)
                selectedIndex = nil
            }
            .disabled(index + 1 >= model.track.cues.count)
            nudge("trash", "Delete this line") {
                model.remove(at: index)
                selectedIndex = nil
            }
        }
        .font(Type.detail)
    }

    /// Splitting is offered only while editing, because the split point is the CARET — there is
    /// no other way for a person to say where. `draft`'s own text is what gets split, so the
    /// text is committed first: splitting a cue whose edits had not landed would discard them.
    @ViewBuilder private func editingControls(index: Int) -> some View {
        HStack(spacing: Space.snug) {
            Button("Save") { commit(index) }
            Button("Cancel") { editingIndex = nil }
            Spacer()
            Button("Split in two") {
                model.setText(draft, at: index)
                model.split(at: index, atCharacter: splitOffset(of: draft))
                editingIndex = nil
                selectedIndex = nil
                onChange()
            }
            .disabled(splitOffset(of: draft) == 0)
        }
        .font(Type.detail)
    }

    /// Where a line splits when nobody has said: **the space nearest the middle**, which is the
    /// break a person would have made. Zero when there is no space at all — a dense script with
    /// no gaps has no offset this can guess, and offering the button would split it mid-word.
    private func splitOffset(of text: String) -> Int {
        let characters = Array(text)
        let middle = characters.count / 2
        let spaces = characters.indices.filter { characters[$0] == " " }
        return spaces.min(by: { abs($0 - middle) < abs($1 - middle) }).map { $0 + 1 } ?? 0
    }

    private static let nudge = Nanoseconds(100_000_000)

    private func shifted(_ time: Nanoseconds, by delta: Int64) -> Nanoseconds {
        Nanoseconds(max(0, time.rawValue + delta))
    }

    @ViewBuilder private func nudge(_ symbol: String, _ label: String,
                                    action: @escaping () -> Void) -> some View {
        Button(action: { action(); onChange() }) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .help(LocalizedStringKey(label))
            .accessibilityLabel(LocalizedStringKey(label))
    }

    private func commit(_ index: Int) {
        model.setText(draft, at: index)
        editingIndex = nil
        onChange()
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

    private var phaseLabel: String {
        switch model.phase {
        case .extractingAudio: "Reading the audio…"
        case .installingModel(let language): "Downloading the \(language) speech model…"
        case .listening, nil: "Listening…"
        }
    }

    /// `m:ss.t` — a caption list is scanned for WHERE something was said, and hours of leading
    /// zeroes on every row is noise in a column a person reads down.
    private func timecode(_ time: Nanoseconds) -> String {
        let tenths = max(0, time.rawValue) / 100_000_000
        return "\(tenths / 600):" + String(format: "%02d.%01d", (tenths / 10) % 60, tenths % 10)
    }
}
