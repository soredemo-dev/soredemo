import Capture
import SwiftUI

/// The open recorder: what to record, and with which microphone and camera.
struct NotchRecorderControls: View {
    let coordinator: RecordingCoordinator
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            HStack(spacing: Space.snug) {
                target("display", "Screen") { coordinator.beginRecording(.displaysOnly) }
                target("macwindow", "Window") { coordinator.beginWindowRecordingByPointing() }
                target("rectangle.dashed", "Area") { coordinator.beginRegionRecording() }
                // **A plugged-in phone or tablet, the same fourth choice the menu offers.** This row
                // was built from the menu's first three and the fourth — which exists only while a
                // device does — was missed, so recording a phone from the notch was impossible.
                // A take's only: a phone is recorded through a stack with no screenshot path.
                if coordinator.capturePurpose == .take {
                    ForEach(coordinator.availableMobileScreens) { device in
                        target(device.symbolName, verbatim: device.displayName) {
                            coordinator.beginMobileRecording(device)
                        }
                    }
                    ForEach(coordinator.mobileScreensWaiting, id: \.self) { name in waiting(name) }
                }
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
                // depth is fixed (`NotchSurfaceLayout.openDepth`); as a third row it was cut in
                // half at the surface's bottom edge — reported 2026-09-29 with a screenshot. This
                // row has the width to spare. Only when true; see `AudioRoute` for why it
                // suggests headphones and not muting.
                if coordinator.speakersReachTheMicrophone {
                    Spacer(minLength: Space.snug)
                    Label("The speakers will be heard in the recording", systemImage: "speaker.wave.2.fill")
                        .lineLimit(1)
                        .foregroundStyle(Signal.paused)
                        .help("The built-in microphone hears the built-in speakers, so whatever this Mac plays is recorded twice. Headphones keep it out of the take.")
                }
            }
            .menuStyle(.borderlessButton)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.8))
            // **Hidden, not removed, for a picture**: a picture has no sound and no camera, and
            // keeping the row's space stops the surface's content jumping when the mode changes.
            .opacity(coordinator.capturePurpose == .take ? 1 : 0)
            .disabled(coordinator.capturePurpose != .take)
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

    private func target(_ icon: String, verbatim title: String, _ start: @escaping () -> Void) -> some View {
        targetButton(icon, label: Text(verbatim: title), start)
    }

    /// A way to start. Closes the surface first: the picker that follows is a window of its own,
    /// and the surface hanging open over it would be in the way of the choice it asks for.
    private func target(_ icon: String, _ title: LocalizedStringKey, _ start: @escaping () -> Void) -> some View {
        targetButton(icon, label: Text(title), start)
    }

    private func targetButton(_ icon: String, label: Text, _ start: @escaping () -> Void) -> some View {
        Button {
            done()
            start()
        } label: {
            VStack(spacing: Space.tight) {
                Image(systemName: icon).font(.system(size: 18))
                label.font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
