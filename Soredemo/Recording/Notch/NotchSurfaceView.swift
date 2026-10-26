import Capture
import Geometry
import SwiftUI

/// The surface's black: a notch assistant's outward-curling top corners, bottom corners that open as it
/// grows. **A `Canvas`, not a `Shape`**: `Shape.path(in:)` would name `CGRect` in the app, which
/// rule 5 forbids, so the outline comes from `CGGeometryBridge.notchOutline`. `Animatable` so the
/// radius springs with the frame instead of jumping when the state changes.
private struct NotchBackground: View, Animatable {
    var bottomRadius: Double
    let flare: Double

    var animatableData: Double {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGGeometryBridge.notchOutline(
                width: Double(size.width), height: Double(size.height),
                flare: flare, bottomRadius: bottomRadius)), with: .color(.black))
        }
    }
}

/// What is drawn in the surface, per state. The shape and its size animate on one spring; the
/// content cross-fades inside it, so text never stretches with the frame.
struct NotchSurfaceView: View {
    let model: NotchSurfaceModel
    let coordinator: RecordingCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// a notch assistant's spring, which the tuning page kept. Reduce Motion gets a short fade instead:
    /// a surface travelling a few hundred points is what that setting exists to stop.
    private var motion: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.84)
    }

    var body: some View {
        let surface = model.localRect
        let panel = model.panelRect
        ZStack(alignment: .top) {
            NotchBackground(bottomRadius: model.bottomRadius, flare: model.flare)
                .frame(width: surface.width + 2 * model.flare, height: surface.height)
            content
                .frame(width: surface.width, height: surface.height, alignment: .top)
                .clipped()
        }
        .frame(width: panel.width, height: panel.height, alignment: .top)
        .animation(motion, value: model.state)
        .environment(\.colorScheme, .dark)
        .onExitCommand { model.send(.escape) }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        // The pointer and the click that wake and open the surface are read by the presenter's
        // monitors, not by views here: see `NotchSurfacePointer` for why hover could not do it.
        case .dormant:
            Color.clear
        // **A take that has just ended says so**, with the daruma's second eye painted in, and
        // settles back on its own (`NotchSurfacePresenter.finishedSeconds`).
        case .finished:
            wings(left: {
                NotchDaruma(pose: DarumaPose.notch(.finished, isPaused: false), glow: Brand.kinColor)
            }, right: {
                Text("Saved").opacity(0.8)
            })
            .transition(.opacity)
        case .glance:
            glanceRow.transition(.opacity)
        case .open:
            VStack(spacing: 0) {
                // **The mode switch sits in the wing, and it is two symbols.** The open surface's
                // depth is fixed — a third row was cut in half at its edge once already — and the
                // wing beside the notch is about 125 points. Measured with the real translations,
                // a worded switch is 84 to 188 points wide: past the wing, under the camera
                // housing, in eight of ten languages. The symbols are 50 in all of them, and the
                // right wing says which mode is on in words.
                wings(left: {
                    // **The mark, where the take-or-picture switch was.** The choice moved to the
                    // act — Record or Screenshot below — as it did in the panel.
                    NotchDaruma(pose: .resting, glow: nil)
                        .accessibilityLabel(Text("Soredemo"))
                }, right: {
                    Text(verbatim: GlobalHotkey.toggleRecordingSpelling).opacity(0.6)
                })
                NotchRecorderControls(coordinator: coordinator) { model.send(.escape) }
                    .padding(.horizontal, Space.regular)
                    .padding(.bottom, Space.regular)
            }
            .transition(.opacity)
        case .live(let expanded):
            VStack(spacing: 0) {
                wings(left: {
                    HStack(spacing: Space.tight + 2) {
                        // The daruma, its record eye lit while the take runs, in a breathing red
                        // glow — the pulsing dot's job, said by the character.
                        NotchDaruma(pose: DarumaPose.notch(model.state, isPaused: coordinator.isPaused),
                                    glow: coordinator.isPaused ? Brand.kinColor : Color(Signal.record),
                                    breathes: !coordinator.isPaused)
                            .accessibilityLabel(coordinator.isPaused ? Text("Paused") : Text("Recording"))
                        Text(verbatim: ElapsedTime.text(coordinator.elapsed))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                    }
                }, right: {
                    NotchSoundWing(coordinator: coordinator)
                })
                if expanded {
                    VStack(spacing: Space.tight) {
                        NotchLiveSteps(steps: coordinator.liveSteps)
                        NotchTakeControls(coordinator: coordinator)
                    }
                    .padding(.horizontal, Space.regular)
                    .padding(.bottom, Space.snug)
                    .transition(.opacity)
                }
            }
        }
    }

    private var glanceRow: some View {
        wings(left: {
            HStack(spacing: Space.tight) {
                NotchDaruma(pose: .resting, glow: nil)
                Text("Record").lineLimit(1).minimumScaleFactor(0.7)
            }
        }, right: {
            Text(verbatim: GlobalHotkey.toggleRecordingSpelling).opacity(0.6)
        })
    }

    /// One row the notch's own height: something on each side of it, nothing over the camera.
    private func wings(@ViewBuilder left: () -> some View, @ViewBuilder right: () -> some View) -> some View {
        HStack(spacing: 0) {
            left().frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: model.notch.width)
            right().frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 12))
        .foregroundStyle(.white)
        .padding(.horizontal, Space.regular)
        .frame(height: model.notch.height)
    }
}

/// The daruma in the notch's wing: the colour mark on the black surface, with a soft glow in its
/// state's colour behind it — red while recording, breathing; gold when paused or done; none when
/// it is only being offered. Each state its own face and light, as in the owner's Grok reference.
private struct NotchDaruma: View {
    let pose: DarumaPose
    let glow: Color?
    var breathes = false
    @AppStorage(AppIconChoice.defaultsKey) private var icon = AppIconChoice.black
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        DarumaView(pose: pose, icon: icon)
            .frame(width: 20, height: 20)
            .background {
                if let glow {
                    Circle()
                        .fill(RadialGradient(colors: [glow.opacity(0.75), glow.opacity(0)],
                                             center: .center, startRadius: 2, endRadius: 18))
                        .frame(width: 36, height: 36)
                        .opacity(breathes && !reduceMotion && dim ? 0.45 : 1)
                        .animation(breathes && !reduceMotion
                                   ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : nil,
                                   value: dim)
                        .onAppear { dim = true }
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: pose)
    }
}

private enum Brand {
    static let kinColor = Palette.Brand.kin.color
}

/// The take's last presses, newest last and in full ink, the earlier ones fading — the checklist
/// of the owner's Grok reference, said in the recording's own steps. Before the first press it
/// says where they will appear.
private struct NotchLiveSteps: View {
    let steps: [String]

    var body: some View {
        HStack(spacing: Space.snug) {
            if steps.isEmpty {
                Text("Steps appear here as you click.")
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, label in
                    let isNewest = index == steps.count - 1
                    if index > 0 {
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    // The interface's own label, drawn as it is.
                    Text(verbatim: label)
                        .fontWeight(isNewest ? .semibold : .regular)
                        .foregroundStyle(.white.opacity(isNewest ? 1 : 0.5 + 0.2 * Double(index)))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .frame(height: 18)
        .animation(.easeOut(duration: 0.2), value: steps)
    }
}

