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
            let source = OnDeviceTranscription()
            let recognised = try await source.transcript(of: mediaURL, range: nil,
                                                         onProgress: { [weak self] progress in
                Task { @MainActor in self?.phase = progress }
            })
            transcript = recognised
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

    private func styleChanging(height: Double? = nil, inset: Double? = nil,
                               plate: Double? = nil) -> CaptionStyle {
        CaptionStyle(heightFraction: height ?? model.style.heightFraction,
                     bottomInsetFraction: inset ?? model.style.bottomInsetFraction,
                     maximumWidthFraction: model.style.maximumWidthFraction,
                     backgroundOpacity: plate ?? model.style.backgroundOpacity,
                     backgroundCornerFraction: model.style.backgroundCornerFraction,
                     red: model.style.red, green: model.style.green, blue: model.style.blue)
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
