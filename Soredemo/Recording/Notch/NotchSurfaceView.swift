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
                    Picker("Capture", selection: Binding(get: { coordinator.capturePurpose },
                                                         set: { coordinator.capturePurpose = $0 })) {
                        Image(systemName: "record.circle").accessibilityLabel(Text("Record"))
                            .tag(RecordingCoordinator.CapturePurpose.take)
                        Image(systemName: "camera.viewfinder").accessibilityLabel(Text("Screenshot"))
                            .tag(RecordingCoordinator.CapturePurpose.picture)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .help(coordinator.capturePurpose == .take ? Text("Record") : Text("Screenshot"))
                }, right: {
                    if coordinator.capturePurpose == .take {
                        Text(verbatim: GlobalHotkey.toggleRecordingSpelling).opacity(0.6)
                    } else {
                        Text("Screenshot").lineLimit(1).minimumScaleFactor(0.8)
                    }
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
                        PulsingDot(isPaused: coordinator.isPaused)
                        Text(verbatim: ElapsedTime.text(coordinator.elapsed))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                    }
                }, right: {
                    NotchSoundWing(coordinator: coordinator)
                })
                if expanded {
                    NotchTakeControls(coordinator: coordinator)
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
                Image(systemName: "record.circle.fill").foregroundStyle(Signal.record)
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
