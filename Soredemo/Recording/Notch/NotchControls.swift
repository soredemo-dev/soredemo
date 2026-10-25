import Capture
import SwiftUI

/// The open recorder: what to record, and with which microphone and camera.
struct NotchRecorderControls: View {
    let coordinator: RecordingCoordinator
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            HStack(spacing: Space.snug) {
                target("display", "Screen", chosen: coordinator.isChosen(.screen)) { coordinator.choose(.screen) }
                target("macwindow", "Window", chosen: coordinator.isChosen(.window)) { coordinator.choose(.window) }
                target("rectangle.dashed", "Area", chosen: coordinator.isChosen(.area)) { coordinator.choose(.area) }
                // **A plugged-in phone or tablet, the same fourth choice the menu offers** — once
                // missed here, so recording a phone from the notch was impossible. Chosen like the
                // others; Screenshot is disabled for it, as in the panel.
                ForEach(coordinator.availableMobileScreens) { device in
                    target(device.symbolName, verbatim: device.displayName,
                           chosen: coordinator.isChosen(device: device)) {
                        coordinator.choose(device: device)
                    }
                }
                ForEach(coordinator.mobileScreensWaiting, id: \.self) { name in waiting(name) }
            }
            HStack(spacing: Space.snug) {
                Menu {
                    Button("No microphone") { coordinator.microphone = .off }
                    Button("System default") { coordinator.microphone = .systemDefault }
                    ForEach(coordinator.availableMicrophones, id: \.self) { source in
                        Button(LocalizedStringKey(source.displayName)) { coordinator.microphone = source }
                    }
                } label: {
                    Label(LocalizedStringKey(coordinator.microphone.displayName),
                          systemImage: coordinator.microphone == .off ? "mic.slash" : "mic")
                }
                Menu {
                    Button("No camera") { coordinator.camera.choose(.off) }
                    ForEach(coordinator.camera.available, id: \.self) { source in
                        Button(LocalizedStringKey(source.displayName)) { coordinator.camera.choose(source) }
                    }
                } label: {
                    Label(LocalizedStringKey(coordinator.camera.source.displayName),
                          systemImage: coordinator.camera.source == .off ? "video.slash" : "video")
                }
                // **A hint, beside the choice it is about, and IN this row.** The open surface's
                // depth is fixed (`NotchSurfaceLayout.openDepth`); a third row is cut in half at
                // its bottom edge — reported 2026-09-29, and repeated 2026-10-25 by the Record row
                // before it moved in here too. An icon, so the row keeps room for the act; the
                // sentence is its label and its help. See `AudioRoute` for why it says headphones.
                if coordinator.speakersReachTheMicrophone {
                    Label("The speakers will be heard in the recording", systemImage: "speaker.wave.2.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Signal.paused)
                        .help("The built-in microphone hears the built-in speakers, so whatever this Mac plays is recorded twice. Headphones keep it out of the take.")
                }
                NotchActions(coordinator: coordinator, done: done)
            }
            .menuStyle(.borderlessButton)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.8))
        }
        .onChange(of: coordinator.microphone) { coordinator.refreshAudioRoute() }
        // When the surface opens, which is the moment a phone was plugged in for — the menu's
        // own `.task` does the same, and without it the notch showed yesterday's devices.
        .task {
            coordinator.refreshMicrophones()
            coordinator.refreshAudioRoute()
            coordinator.camera.refresh()
            coordinator.refreshMobileScreens()
        }
    }

    /// A device on the cable that is not offering its screen — almost always locked. Shown, not
    /// hidden: a person holding a plugged-in phone and seeing no choice for it has no way to
    /// guess why. The full sentence is the menu's, already in every language.
    private func waiting(_ name: String) -> some View {
        VStack(spacing: Space.tight) {
            Image(systemName: "lock.iphone").font(.system(size: 18))
            Text(verbatim: name).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(.white.opacity(0.45))
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.05)))
        .help(Text("\(name) is connected. Unlock it \u{2014} and tap Trust if it asks \u{2014} to record its screen."))
    }

    private func target(_ icon: String, verbatim title: String, chosen: Bool,
                        _ choose: @escaping () -> Void) -> some View {
        targetButton(icon, label: Text(verbatim: title), chosen: chosen, choose)
    }

    /// A target, chosen — the notch's grammar is the panel's; the act is Record or Screenshot.
    private func target(_ icon: String, _ title: LocalizedStringKey, chosen: Bool,
                        _ choose: @escaping () -> Void) -> some View {
        targetButton(icon, label: Text(title), chosen: chosen, choose)
    }

    private func targetButton(_ icon: String, label: Text, chosen: Bool,
                              _ choose: @escaping () -> Void) -> some View {
        Button(action: choose) {
            VStack(spacing: Space.tight) {
                Image(systemName: icon).font(.system(size: 18))
                label.font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background {
                let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                shape.fill(.white.opacity(chosen ? 0.16 : 0.08))
                    .overlay(shape.stroke(.white.opacity(chosen ? 0.9 : 0), lineWidth: 1.5))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// The notch's act: Screenshot and Record for the chosen target, as in the panel. Both close the
/// surface first — the picker that follows is a window of its own, and the surface hanging open
/// over it would be in the way. Record is a white capsule with an ink mark — no red before
/// anything records, as in the panel.
struct NotchActions: View {
    let coordinator: RecordingCoordinator
    let done: () -> Void

    var body: some View {
        let deviceChosen = coordinator.selectedDevice != nil
        HStack(spacing: Space.snug) {
            Spacer(minLength: 0)
            Button {
                done()
                coordinator.start(.picture)
            } label: {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 30, height: 26)
                    .background(Capsule().fill(.white.opacity(0.12)))
            }
            .disabled(deviceChosen)
            .help(deviceChosen ? Text("A connected device is recorded, not photographed")
                               : Text("Screenshot"))
            .accessibilityLabel(Text("Screenshot"))
            Button {
                done()
                coordinator.start(.take)
            } label: {
                HStack(spacing: Space.tight) {
                    Image(systemName: "record.circle").font(.system(size: 12, weight: .medium))
                    Text("Record").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.black)
                .padding(.horizontal, Space.regular)
                .frame(height: 26)
                .background(Capsule().fill(.white))
            }
            .help(Text("Record what is chosen (\(GlobalHotkey.toggleRecordingSpelling))"))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}

/// The right wing of a live take: the level, unless there is something more urgent to say.
///
/// **A microphone that hears nothing replaces the meter**, because a meter at the bottom of its
/// track looks exactly like a quiet room.
struct NotchSoundWing: View {
    let coordinator: RecordingCoordinator

    var body: some View {
        if coordinator.guards.microphoneHearsNothing {
            Label("The microphone hears nothing", systemImage: "mic.slash.fill")
                .labelStyle(.iconOnly)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Signal.paused)
                .frame(width: 36)
                .help("The microphone hears nothing")
        } else {
            LevelMeter(level: coordinator.guards.microphoneLevel).frame(width: 36, height: 4)
        }
    }
}

/// A take's controls, shown only while the pointer is on the surface.
struct NotchTakeControls: View {
    let coordinator: RecordingCoordinator

    var body: some View {
        HStack(spacing: Space.snug) {
            Button { coordinator.togglePause() } label: {
                Label {
                    coordinator.isPaused ? Text("Resume") : Text("Pause")
                } icon: {
                    Image(systemName: coordinator.isPaused ? "play.fill" : "pause.fill")
                }
            }
            if case .ready(let ceiling) = coordinator.clipReadiness {
                Button { coordinator.saveClip(lastSeconds: ceiling) } label: {
                    Label("Save the last \(Int(ceiling)) seconds — the recording keeps going",
                          systemImage: "clock.arrow.circlepath")
                        .labelStyle(.iconOnly)
                }
                .help(Text("Save the last \(Int(ceiling)) seconds — the recording keeps going"))
            }
            Spacer(minLength: 0)
            Button { coordinator.stop() } label: {
                Label("Stop", systemImage: "stop.fill")
                    .padding(.horizontal, Space.regular)
                    .padding(.vertical, Space.tight)
                    .background(Capsule().fill(Signal.record))
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white)
    }
}
