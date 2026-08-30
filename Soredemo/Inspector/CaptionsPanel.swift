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
    /// The transcript as recognised, kept so a change to the caption style or the output size
    /// can re-break the lines without transcribing again. Breaking is instant; recognising is
    /// not.
    private(set) var transcript: Transcript?
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
        guard let transcript else { return }
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

    func setBurnsIn(_ value: Bool) {
        burnsIn = value
        publish()
    }

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

    @State private var maximumWords: Int?
    @State private var editingIndex: Int?
    @State private var draft = ""

    var body: some View {
        List {
            Section("Transcript") { transcriptControls }
            if !model.track.isEmpty {
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
        }
    }

    @ViewBuilder private var lines: some View {
        ForEach(Array(model.track.cues.enumerated()), id: \.offset) { index, cue in
            VStack(alignment: .leading, spacing: Space.tight) {
                HStack {
                    Text(timecode(cue.start)).font(Type.readout).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        model.remove(at: index)
                        onChange()
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
                if editingIndex == index {
                    TextField("Caption", text: $draft, axis: .vertical)
                        .onSubmit { commit(index) }
                    HStack(spacing: Space.snug) {
                        Button("Save") { commit(index) }
                        Button("Cancel") { editingIndex = nil }
                    }
                    .font(Type.detail)
                } else {
                    Text(cue.text)
                        .font(Type.label)
                        // A recogniser gets a name or an acronym wrong far more often than it
                        // gets the timing wrong, so correcting text is the common gesture and
                        // it must not re-time the line.
                        .onTapGesture { editingIndex = index; draft = cue.text }
                }
            }
            .padding(.vertical, Space.hairline)
        }
    }

    private func commit(_ index: Int) {
        model.setText(draft, at: index)
        editingIndex = nil
        onChange()
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
