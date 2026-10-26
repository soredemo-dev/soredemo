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
        MenuBarRow(icon: coordinator.microphone == .off ? "mic.slash" : "mic.fill",
                   iconIsOff: coordinator.microphone == .off, title: "Microphone",
                   value: Text(LocalizedStringKey(coordinator.microphone.displayName))) {
            Button("No microphone") { coordinator.microphone = .off }
            Divider()
            Button("System default") { coordinator.microphone = .systemDefault }
            ForEach(coordinator.availableMicrophones, id: \.self) { source in
                Button(LocalizedStringKey(source.displayName)) { coordinator.microphone = source }
            }
            Divider()
            Button("Microphone Modes\u{2026}") { CameraEffects.showMicrophoneModes() }
            Divider()
            // A toggle, so the menu draws its own checkmark — see `MenuBarCountdownRow`.
            Toggle("Record system audio", isOn: Binding(
                get: { coordinator.preferences.capturesSystemAudio },
                set: { coordinator.preferences.capturesSystemAudio = $0 }))
        } accessory: {
            if !coordinator.preferences.capturesSystemAudio {
                Image(systemName: "speaker.slash.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("System audio is off")
            }
        }
    }
}

struct MenuBarCameraRow: View {
    let camera: CameraController

    var body: some View {
        if !camera.available.isEmpty {
            MenuBarRow(icon: camera.source == .off ? "video.slash" : "video.fill",
                       iconIsOff: camera.source == .off, title: "Camera",
                       value: Text(LocalizedStringKey(camera.source.displayName))) {
                Button("No camera") { camera.choose(.off) }
                Divider()
                ForEach(camera.available, id: \.self) { source in
                    Button(LocalizedStringKey(source.displayName)) { camera.choose(source) }
                }
                Divider()
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
            }

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
