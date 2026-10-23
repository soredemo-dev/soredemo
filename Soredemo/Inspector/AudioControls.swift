import AppKit
import SwiftUI
import Compositing
import Overlays
import Project
import Timeline
import UniformTypeIdentifiers

/// One row per recorded source: a level and a mute.
///
/// **Mute is a separate control from a zero level**, which is what lets a person unmute
/// back to where they had it — `AudioMix` keeps the two apart for that reason, and a UI
/// that collapsed them would throw the level away.
///
/// The level is shown as a percentage because that is what a person reads a volume in;
/// `AudioMix` stores a linear gain, which is what `AVAudioMix` takes. The conversion is
/// here, at the edge, rather than in the model.
///
/// Moved out of `StageWindow` — step 2 of `docs/design/2026-10-23-splitting-the-stage-window.md`,
/// with the preview pipeline it reads (`EditorPreview`): the noise-removal note, the loudness
/// measurements a reset forgets, and the music's failure.
struct AudioControls: View {
    @Bindable var editor: EditorViewModel
    let preview: EditorPreview
    let files: EditorPreview.Files

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: Binding(
                get: { editor.noiseReduction != nil },
                set: { editor.noiseReduction = $0 ? .default : nil })
            ) {
                Text("Remove background noise")
            }
            .toggleStyle(.checkbox)
            .font(.caption)

            if editor.noiseReduction != nil {
                HStack {
                    Text("Strength").font(.caption).foregroundStyle(.secondary)
                    LiveSlider(
                        value: editor.noiseReduction?.strength
                            ?? NoiseReduction.Settings.default.strength,
                        // **Not the type's full 0…4 range.** Zero removes nothing, and above
                        // three the voice starts going with the room — a range whose ends are
                        // both useless is a slider that spends most of its travel doing harm.
                        range: 0.5...3.0,
                        commit: { strength in
                            editor.noiseReduction = .init(
                                strength: strength,
                                floor: editor.noiseReduction?.floor
                                    ?? NoiseReduction.Settings.default.floor)
                        })
                }
            }
            // **What it can and cannot do, on screen.** It takes out a fan, a hum, a laptop under
            // load — sound that is there the whole time. It does not take out a door, a keyboard
            // or a dog, and somebody who expects it to will conclude the feature is broken.
            (preview.noiseReductionNote.map { Text(verbatim: $0) }
                 ?? Text("Removes steady sound — a fan, a hum, air conditioning — from the microphone only. It cannot remove a one-off noise like a door or a keyboard."))
                .font(Type.detail)
                .foregroundStyle(preview.noiseReductionNote == nil ? .secondary : Signal.paused)
        }
        .padding(.bottom, 2)

        ForEach(AudioMix.Source.allCases, id: \.self) { source in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Toggle(isOn: Binding(
                        get: { !editor.audioMix.isMuted(source) },
                        set: { editor.audioMix = editor.audioMix.setting(source, muted: !$0) })
                    ) {
                        Text(LocalizedStringKey(source.displayName))
                    }
                    .toggleStyle(.checkbox)
                    Spacer()
                    Text(verbatim: "\(Int((editor.audioMix.gain(for: source) * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(editor.audioMix.isMuted(source) ? .tertiary : .secondary)
                }
                .font(.caption)
                Slider(value: Binding(
                    get: { editor.audioMix.gain(for: source) },
                    set: { editor.audioMix = editor.audioMix.setting(source, gain: $0) }),
                       in: 0...AudioMix.maximumGain)
                    // A muted source's slider is disabled rather than hidden: the level is
                    // still there, and hiding it would suggest it had been lost.
                    .disabled(editor.audioMix.isMuted(source))
            }
        }
        // **Levelling, which every comparable recorder ships and this had none of.** A demo's
        // narration sits at whatever level the microphone happened to be at, and every platform
        // it is posted to renormalises by loudness — so a file that ignores loudness is a file
        // the platform will change. The target is in
        // LUFS because that is the unit the platforms publish theirs in; the measurement and
        // the gain that follows are `Loudness`'s.
        Divider()
        Toggle(isOn: Binding(
            get: { editor.audioMix.targetLoudness != nil },
            set: { editor.audioMix = editor.audioMix.settingTargetLoudness(
                $0 ? Loudness.defaultTargetLUFS : nil) })
        ) {
            Text("Match a loudness target")
        }
        .toggleStyle(.checkbox)
        .font(.caption)
        if let target = editor.audioMix.targetLoudness {
            HStack {
                Text("Target").font(.caption)
                Spacer()
                Text(verbatim: "\(Int(target.rounded())) LUFS")
                    .monospacedDigit().foregroundStyle(.secondary).font(.caption)
            }
            Slider(value: Binding(get: { target },
                                  set: { editor.audioMix = editor.audioMix.settingTargetLoudness($0.rounded()) }),
                   in: AudioMix.quietestTarget...AudioMix.loudestTarget)
            Text("YouTube and Spotify normalise to \u{2212}14; \u{2212}16 leaves a little headroom under it.")
                .font(Type.detail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if editor.audioMix.changesAnything {
            Button("Reset audio") { editor.audioMix = .unchanged; preview.forgetLoudness() }
                .buttonStyle(.link).font(.caption)
        }
        Divider()
        musicControls
    }

    /// **A music bed, and how far out of the way it gets when somebody speaks.**
    ///
    /// The file is copied into the project — `MusicBed` says why — and the envelope
    /// comes from the silences the timeline already found, so there is one answer to "where is
    /// the voice" rather than two.
    @ViewBuilder private var musicControls: some View {
        HStack {
            Text("Music").font(.caption)
            Spacer()
            if let name = editor.music.filename {
                Text(verbatim: name).font(Type.detail).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Button {
                if let source = Self.chooseAudio() { preview.adoptMusic(source, files: files, editor: editor) }
            } label: {
                editor.music.filename == nil ? Text("Choose\u{2026}") : Text("Replace\u{2026}")
            }
            .buttonStyle(.link).font(.caption)
        }
        if let failure = preview.musicFailure {
            Text(verbatim: failure).font(Type.detail).foregroundStyle(Signal.paused)
                .fixedSize(horizontal: false, vertical: true)
        }
        if editor.music.filename != nil {
            Toggle("Play the music", isOn: Binding(
                get: { editor.music.isEnabled },
                set: { editor.music = editor.music.changing(isEnabled: $0) }))
                .toggleStyle(.checkbox).font(.caption)
            musicSlider("Music level", value: editor.music.ducking.bedGain, upTo: 1) { value in
                let settings = editor.music.ducking
                editor.music = editor.music.changing(ducking: MusicDucking.Settings(
                    bedGain: value, duckedGain: min(settings.duckedGain, value),
                    attack: settings.attack, release: settings.release, hold: settings.hold))
            }
            Toggle("Lower it while I speak", isOn: Binding(
                get: { editor.music.ducks },
                set: { editor.music = editor.music.changing(ducks: $0) }))
                .toggleStyle(.checkbox).font(.caption)
            if editor.music.ducks {
                musicSlider("Level while speaking", value: editor.music.ducking.duckedGain,
                            upTo: editor.music.ducking.bedGain) { value in
                    let settings = editor.music.ducking
                    editor.music = editor.music.changing(ducking: MusicDucking.Settings(
                        bedGain: settings.bedGain, duckedGain: value,
                        attack: settings.attack, release: settings.release, hold: settings.hold))
                }
                if editor.timeline.silences.isEmpty {
                    Text("Nothing on the microphone track reads as speech yet, so the bed stays at its own level.")
                        .font(Type.detail).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button("Remove the music") {
                preview.removeMusic(editor: editor)
            }
            .buttonStyle(.link).font(.caption)
        }
    }

    /// A level slider with its value written beside it. `upTo` is clamped away from zero
    /// because a `Slider` whose range is empty traps, and "level while speaking" has an upper
    /// bound that is itself a slider somebody can drag to nothing.
    @ViewBuilder private func musicSlider(_ title: LocalizedStringKey, value: Double, upTo: Double,
                                          commit: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(verbatim: "\(Int((value * 100).rounded()))%")
                    .monospacedDigit().foregroundStyle(.secondary).font(.caption)
            }
            Slider(value: Binding(get: { min(value, max(upTo, 0.0001)) }, set: { commit($0) }),
                   in: 0...max(upTo, 0.0001))
        }
    }

    /// The open panel, audio only.
    @MainActor
    private static func chooseAudio() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
