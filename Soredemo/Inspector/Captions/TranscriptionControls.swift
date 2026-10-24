import Compositing
import Foundation
import Overlays
import SwiftUI
import Timeline

/// Transcribing: the button, the steps while it runs, the language, and how many words a line
/// may hold. Moved out of `CaptionsPanel` (2026-10-23).
struct TranscriptionControls: View {
    let model: CaptionsModel
    let mediaURL: URL
    let outputWidth: Int
    let outputHeight: Int
    let pauses: [SilenceFinder.Span]
    /// Held by the panel, because the names list re-breaks lines with the same cap.
    @Binding var maximumWords: Int?
    let onChange: () -> Void

    var body: some View {
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
