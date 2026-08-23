import AVFoundation
import Capture
import Render
import SwiftUI
import UniformTypeIdentifiers

/// What the window shows before there is a recording in it.
///
/// **The empty state is a picture of what this app makes.** A rounded screen floating on a
/// gradient, with a shadow under it, is exactly the frame `StageCompositor` composes — so the
/// first thing a person sees is the output, and the actions sit inside the thing they are about
/// to produce. That is the one idea here that is not borrowed:
/// `../opensource/Screen Record Opensource/a Swift recorder`'s welcome screen is a logo above three
/// cards on a flat background, which is a good screen for any app and a picture of nothing.
///
/// The colours are read from `StageBackground.presets`, not chosen here, so the demonstration
/// stays true when a preset is retuned.
struct WelcomeView: View {
    let coordinator: RecordingCoordinator
    @State private var isDropTarget = false
    @State private var dropRefusal: String?

    var body: some View {
        ZStack {
            backdrop
            card
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.movie, .video, .fileURL], isTargeted: $isDropTarget) { providers in
            accept(providers)
        }
    }

    /// The stage's own background, at the stage's own inset — which is what makes the card below
    /// read as a recording rather than as a dialog.
    @ViewBuilder private var backdrop: some View {
        let preset = StageBackground.presets.first?.background
        Group {
            switch preset {
            case .linearGradient(let sr, let sg, let sb, let er, let eg, let eb, let angle):
                // **The angle is honoured, not ignored.** `CoreImageFrameRenderer` measures it
                // counter-clockwise from +x and places the two points on the frame's diagonal;
                // the same conversion here is what keeps this a picture of the output rather
                // than a gradient that happens to use the same two colours. `y` is flipped
                // because SwiftUI's unit space runs downward and Core Image's runs up.
                LinearGradient(
                    colors: [Color(red: sr, green: sg, blue: sb),
                             Color(red: er, green: eg, blue: eb)],
                    startPoint: Self.unitPoint(atDegrees: angle + 180),
                    endPoint: Self.unitPoint(atDegrees: angle))
            case .solid(let red, let green, let blue):
                Color(red: red, green: green, blue: blue)
            case nil:
                Color.black
            }
        }
        .ignoresSafeArea()
    }

    /// A unit point on the edge of SwiftUI's 0…1 box at `degrees`, measured counter-clockwise
    /// from +x — the compositor's convention, converted once.
    static func unitPoint(atDegrees degrees: Double) -> UnitPoint {
        let radians = degrees * .pi / 180
        return UnitPoint(x: 0.5 + cos(radians) / 2, y: 0.5 - sin(radians) / 2)
    }

    @ViewBuilder private var card: some View {
        VStack(spacing: Space.section) {
            title
            actions
            hint
        }
        .padding(.horizontal, 56)
        .padding(.vertical, 48)
        .frame(maxWidth: 620)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.white.opacity(isDropTarget ? 0.5 : Glass.edgeOpacity),
                                      lineWidth: isDropTarget ? 2 : 0.5)
                }
                // The same ambient shadow `CoreImageFrameRenderer` draws under the card: no
                // offset, because the style models radius and opacity and nothing else.
                .shadow(color: .black.opacity(0.45), radius: 40)
        }
        .padding(Space.section)
        .animation(.easeOut(duration: 0.15), value: isDropTarget)
    }

    @ViewBuilder private var title: some View {
        VStack(spacing: Space.snug) {
            Text("Soredemo")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text(coordinator.isRecording
                 ? "Recording. The controls are at the bottom of the screen."
                 : "Record your screen, and let the camera follow what you click.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: Space.regular) {
            WelcomeAction(icon: "menubar.arrow.up.rectangle", title: "Record a screen",
                          detail: "\u{2318}R", tint: Signal.record) {
                coordinator.beginRecording(.displaysOnly)
            }
            WelcomeAction(icon: "macwindow", title: "Record a window",
                          detail: "One app", tint: .white.opacity(0.9)) {
                coordinator.beginRecording(.windowsOnly)
            }
            WelcomeAction(icon: "folder", title: "Open a project",
                          detail: "\u{2318}O", tint: .white.opacity(0.9)) {
                coordinator.openProject()
            }
        }
        .disabled(coordinator.isRecording)
        .opacity(coordinator.isRecording ? 0.4 : 1)
    }

    @ViewBuilder private var hint: some View {
        VStack(spacing: Space.tight) {
            if let dropRefusal {
                Label(dropRefusal, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(Signal.paused)
            } else {
                Text(isDropTarget ? "Drop the video to edit it"
                     : "Or drop a video here \u{00B7} Soredemo also lives in the menu bar")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
            if !coordinator.statusText.isEmpty {
                Text(coordinator.statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
            }
        }
    }

    /// **Accepts a video and refuses everything else, out loud.** A drop target that silently
    /// ignores what it was given looks broken; one that says "that is not a video" has answered.
    private func accept(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            Task { @MainActor in
                guard let url else {
                    dropRefusal = "That could not be read as a file."
                    return
                }
                let isMovie = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?
                    .conforms(to: .movie) ?? false
                guard isMovie else {
                    dropRefusal = "\(url.lastPathComponent) is not a video."
                    return
                }
                dropRefusal = nil
                coordinator.openVideo(at: url)
            }
        }
        return true
    }
}

/// One of the three welcome actions.
private struct WelcomeAction: View {
    let icon: String
    let title: String
    let detail: String
    let tint: Color
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: Space.snug) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(tint)
                    .frame(height: 26)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.roomy)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(isHovering ? 0.12 : 0.06))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.white.opacity(Glass.edgeOpacity), lineWidth: 0.5)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
