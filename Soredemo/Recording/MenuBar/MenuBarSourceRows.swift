import Capture
import SwiftUI

/// Both audio sources: which microphone, and whether the machine's own output is recorded.
///
/// **One row rather than two, because they are one question.** The microphone is what has a
/// list, so it keeps the label; system audio is a switch inside the same menu, and the row
/// shows a struck-through speaker when it is off — state a person turned off has to be
/// visible without opening anything.
///
/// **System audio can be turned off here, and it could not before.** The old objection — an
/// unfed `AVAssetWriter` input starves a fed one — is still accurate and no longer binding:
/// `HeldAudioQueue` holds about eight seconds against a grace period of one and a half.
/// A written reason its own codebase overtook; `docs/design/hearing-the-scrub.md` has it.
///
/// **The source rows do not wear the accent.** A `Menu`'s label inherits the tint, which put
/// the brand colour on two rows that only report what is selected — and left the button that
/// starts the recording competing with them. The accent marks the primary action; these are
/// state.
struct MenuBarMicrophoneRow: View {
    let coordinator: RecordingCoordinator

    var body: some View {
        Menu {
            Button("No microphone") { coordinator.microphone = .off }
            Divider()
            Button("System default") { coordinator.microphone = .systemDefault }
            ForEach(coordinator.availableMicrophones, id: \.self) { source in
                Button(LocalizedStringKey(source.displayName)) { coordinator.microphone = source }
            }
            Divider()
            // **Voice Isolation is the noise removal, done by the system, on the input.** It is
            // a mode macOS applies before any app sees a sample, so it is in the recording
            // rather than something an export has to undo. No app can set it — see
            // `CameraEffects` — so this opens the panel that can.
            Button("Microphone Modes\u{2026}") { CameraEffects.showMicrophoneModes() }
            Divider()
            // A checkmark rather than a `Toggle`: inside a `Menu` the two look the
            // same and the button carries its own action, which keeps the state in
            // the coordinator rather than in a binding this view would own.
            Button {
                coordinator.preferences.capturesSystemAudio.toggle()
            } label: {
                Label("Record system audio",
                      systemImage: coordinator.preferences.capturesSystemAudio ? "checkmark" : "")
            }
        } label: {
            SourceRowLabel(icon: coordinator.microphone == .off ? "mic.slash" : "mic.fill",
                           isOff: coordinator.microphone == .off,
                           name: coordinator.microphone.displayName) {
                // Shown only when it is OFF. A speaker drawn on every recording
                // would be one more thing to read on a row that is usually just
                // "System default"; a struck-through one appears exactly when
                // somebody has turned something off and needs to see that they did.
                if !coordinator.preferences.capturesSystemAudio {
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("System audio is off")
                }
            }
        }
        .sourceRowMenu()
    }
}

/// Which camera, including none.
///
/// **Hidden entirely when this machine has no camera** — an option that can only fail is worse
/// than no option. The permission is asked for when a camera is chosen rather than at launch,
/// because a recorder that asks for the camera on first run before anyone has asked for one is
/// a recorder people distrust; **a refusal keeps the row and says so** (`wasRefused`, below),
/// because hiding it would teach only that the row had vanished.
struct MenuBarCameraRow: View {
    let camera: CameraController

    var body: some View {
        if !camera.available.isEmpty {
            Menu {
                Button("No camera") { camera.source = .off }
                Divider()
                ForEach(camera.available, id: \.self) { source in
                    Button(LocalizedStringKey(source.displayName)) { camera.choose(source) }
                }
                Divider()
                // **The quality is the camera's, read from the device.** It was capped at 1080p
                // by a decision this app had no business making — a camera grows when the stage
                // zooms, it can be made large, and a ProRes 4444 export of a large overlay wants
                // every pixel the source has.
                Menu("Camera Quality") {
                    ForEach(CameraRecorder.qualities(for: camera.source), id: \.self) { q in
                        Button {
                            camera.quality = q
                        } label: {
                            Text(LocalizedStringKey(q.displayName))
                        }
                    }
                }
                Divider()
                Button("Video Effects\u{2026}") { CameraEffects.showVideoEffects() }
            } label: {
                SourceRowLabel(icon: camera.source == .off ? "video.slash" : "video.fill",
                               isOff: camera.source == .off, name: camera.source.displayName) {}
            }
            .sourceRowMenu()

            // **What the chosen camera will actually record at.** Every camera used to be
            // recorded at 480p whatever it could do, so an external one was throwing away most
            // of itself and nothing said so. Shown rather than made a control: the camera is
            // drawn a few hundred pixels across in the finished video, so the ceiling is 1080p
            // and 4K would be disk and encode time for detail the export discards.
            if case .device = camera.source,
               let size = CameraRecorder.recordingSize(of: camera.source,
                                                       quality: camera.quality) {
                Text(verbatim: size)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            // **What the system is applying, said where the camera is chosen.** Portrait and
            // Studio Light are switched on in Control Center and stay on for every app, so a
            // person who turned one on for a call months ago has it in this recording too; the
            // effects panel itself is one press away in the menu above.
            //
            // **Only when a camera is actually being recorded.** These are macOS's own video
            // effects — Reactions, Portrait, Studio Light — and they apply to a camera. Shown
            // beside "No camera" they name a thing that is not happening, which is worse than
            // saying nothing: somebody reads it as "this recording will have Reactions in it".
            if camera.source != .off, !camera.activeEffects.isEmpty {
                Button { CameraEffects.showVideoEffects() } label: {
                    HStack(spacing: Space.tight) {
                        Image(systemName: "sparkles").font(.system(size: 9))
                        Text(verbatim: camera.activeEffects
                            .map { NSLocalizedString($0.rawValue, comment: "") }
                            .joined(separator: " \u{00B7} "))
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            // **Said before the recording, not after it.** A camera another application already
            // holds is what a video call in a browser looks like from here, and the failure
            // used to arrive as a missing camera track in a finished recording.
            if camera.isBusy {
                Label("Another app is using this camera. The screen will still record.",
                      systemImage: "video.badge.ellipsis")
                    .font(.system(size: 10))
                    .foregroundStyle(Signal.paused)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if camera.wasRefused {
                Button { camera.openSettings() } label: {
                    Label("This Mac has not allowed Soredemo the camera. Open Settings\u{2026}",
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(Signal.paused)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The label both source rows wear: an icon, the source's name, room for one more mark, and the
/// chevron that says it opens.
///
/// **One shape for the two rows**, for `MenuBarSettingRow`'s reason: two labels built side by
/// side are two labels free to drift apart in padding and height.
private struct SourceRowLabel<Accessory: View>: View {
    let icon: String
    let isOff: Bool
    /// **Looked up here, because the name crosses a module boundary as a `String`.**
    /// `MicrophoneSource.displayName` is in the package, which has no strings table and should
    /// not have one — a capture module that knew about the app's UI language would be the wrong
    /// shape. "System default" and "No microphone" are keys in this app's table; a real device's
    /// name is not, and falls through to itself, which is right — the system already localised it.
    let name: String
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(spacing: Space.snug) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(isOff ? .secondary : .primary)
                .frame(width: 14)
            accessory()
            Text(LocalizedStringKey(name))
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: Space.tight)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Space.regular)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: Glass.controlRadius, style: .continuous)
            .fill(.quaternary.opacity(0.5)))
    }
}

private extension View {
    /// A source row's menu: borderless, no indicator, and **not in the accent** — a `Menu`'s
    /// label inherits the tint, and these report state rather than offering the primary action.
    func sourceRowMenu() -> some View {
        menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(Theme.Ink.primary)
    }
}
