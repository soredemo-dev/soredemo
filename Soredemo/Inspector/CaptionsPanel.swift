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

    @State private var maximumWords: Int?
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
                Section("Transcribe") { transcriptControls }
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
                    Section { Text(verbatim: status).font(Type.detail).foregroundStyle(.secondary) }
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

    @ViewBuilder private var transcriptControls: some View {
        if model.isTranscribing {
            transcriptionSteps
        } else {
            Button {
                Task {
                    await model.transcribe(mediaURL: mediaURL, outputWidth: outputWidth,
                                           outputHeight: outputHeight,
                                           maximumWords: maximumWords, pauses: pauses)
                    onChange()
                }
            } label: {
                model.track.isEmpty ? Text("Transcribe") : Text("Transcribe again")
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
                let name = Self.name(of: locale)
                (model.installedLocales.contains(locale.identifier(.bcp47))
                    ? Text(verbatim: name) : Text("\(name) \u{2014} downloads"))
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
            ForEach([1, 2, 3, 4, 5, 6], id: \.self) { Text(verbatim: "\($0)").tag(Int?.some($0)) }
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
                    guard model.readyToExport(),
                          let url = Self.sidecarDestination(format: format,
                                                            defaultName: recordingName)
                    else { return }
                    model.exportSidecar(format: format, edit: edit, to: url)
                }
            }
            Spacer()
            Button("Import…") {
                guard let url = Self.chooseSidecar() else { return }
                model.importSidecar(from: url, edit: edit)
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
            (model.style.fontFilename.map { Text(verbatim: $0) } ?? Text("System"))
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
        if let fontFailure = model.fontFailure {
            Label { Text(verbatim: fontFailure) } icon: { Image(systemName: "exclamationmark.triangle") }
                .font(Type.detail).foregroundStyle(.secondary)
        }
    }

    private func chooseFont() {
        guard let source = Self.chooseFontFile() else { return }
        model.adoptFont(source, mediaURL: mediaURL)
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

    /// The open panel, sidecars only.
    @MainActor
    private static func chooseSidecar() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SubtitleFile.Format.allCases.compactMap {
            UTType(filenameExtension: $0.fileExtension)
        } + [.plainText]
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Where to write a sidecar, starting from the recording's name.
    @MainActor
    private static func sidecarDestination(format: SubtitleFile.Format,
                                           defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        panel.nameFieldStringValue = "\(defaultName).\(format.fileExtension)"
        panel.canCreateDirectories = true
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
