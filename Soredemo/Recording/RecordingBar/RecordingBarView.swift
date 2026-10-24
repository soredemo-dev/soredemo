import Capture
import SwiftUI

// MARK: - the bar itself

struct RecordingBarView: View {
    let coordinator: RecordingCoordinator
    /// What moves the window. Owned by the panel; see `WindowDragger` for why the bar cannot be
    /// dragged by AppKit alone.
    let dragger: WindowDragger

    /// Whether it opens collapsed. **Only `--show-recording-bar` passes true**: the check that
    /// drives it has to be able to reach the collapsed state, where the bar is one control and
    /// nothing else — which is exactly where "it cannot be dragged" hid.
    let startCollapsed: Bool

    /// Collapsed to a dot in the corner. **Not hidden entirely**: a recorder with no visible
    /// indicator is one people leave running, and the menu bar item can be pushed off a full
    /// menu bar — which is exactly what happens on a Mac with a notch. Collapsed it is 44 points
    /// wide and still says a recording is happening.
    @State private var isCollapsed = false

    var body: some View {
        Group {
            if isCollapsed { collapsed } else { expanded }
        }
        .onAppear { isCollapsed = startCollapsed }
        // **The window's shadow room, and it is padding rather than a bigger pill.** The panel
        // is the bar plus this on every side; without it the shadow is clipped at the window's
        // edge and reads as a hard rectangle. See `Glass.shadowRoomSides`.
        .padding(.horizontal, Glass.shadowRoomSides)
        .padding(.top, Glass.shadowRoomTop)
        .padding(.bottom, Glass.shadowRoomBottom)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: isCollapsed)
    }

    @ViewBuilder private var expanded: some View {
        HStack(spacing: Space.regular) {
            grip
            // Their own views, so the clock's tick and the level's reading re-run only what
            // shows them — as computed properties of this view, each re-ran the whole bar.
            BarState(coordinator: coordinator)
            Divider().frame(height: 22).opacity(0.25)
            BarMicrophone(guards: coordinator.guards)
            Spacer(minLength: 0)
            BarButton(icon: coordinator.isPaused ? "play.fill" : "pause.fill",
                      label: coordinator.isPaused ? "Resume" : "Pause") {
                coordinator.togglePause()
            }
            BarButton(icon: "chevron.right.2", label: "Collapse — the recording keeps going") {
                isCollapsed = true
            }
            clipButton
            stopButton
        }
        .padding(.horizontal, Space.regular)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { dragSurface }
        .glassSurface(radius: Glass.barRadius)
    }

    /// **Where the drag lives: behind the controls, not over them.** A gesture on the whole bar
    /// competes with every button on it; one on a layer underneath is reached only where no
    /// control is, which is exactly "drag it by its background". Measured: with this in place a
    /// synthesised drag moves the window 88 points AND the Stop button still fires.
    @ViewBuilder private var dragSurface: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { _ in dragger.moved() }
                    .onEnded { _ in dragger.ended() })
    }

    /// **A dot and nothing else.** Clicking it brings the controls back; the recording never
    /// stopped, and nothing here can stop it by accident.
    ///
    /// **Not a `Button`, and that is why the collapsed bar could not be dragged.** A `Button`
    /// takes the mouse for the whole press, so the drag surface behind it never saw one — and
    /// collapsed, the button IS the bar: there is nothing else to grab. A tap and a drag on the
    /// same view lets SwiftUI tell them apart by distance, which is the same thing a person
    /// does with their hand.
    @ViewBuilder private var collapsed: some View {
        HStack {
            HStack(spacing: Space.snug) {
                PulsingDot(isPaused: coordinator.isPaused)
                Image(systemName: "chevron.left.2")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, Space.regular)
            .frame(height: 30)
            .glassSurface(radius: 15)
            .contentShape(Rectangle())
            // Four points rather than the expanded bar's one: collapsed, a click is the
            // primary action and a press that wandered must still open it.
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { _ in dragger.moved() }
                    .onEnded { _ in dragger.ended() })
            .onTapGesture { isCollapsed = false }
            .help("Click to show the controls, drag to move the bar")
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background { dragSurface }
    }

    /// The drag handle. The panel is `isMovableByWindowBackground`, so anywhere on it works —
    /// this says so, which is the whole job of a grip.
    @ViewBuilder private var grip: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.35))
            .help("Drag anywhere on the bar to move it")
    }

    /// Save the last fifteen seconds, while the recording keeps going.
    ///
    /// **Present only while it would work.** `clipReadiness` has three answers and only one of
    /// them is a button: a Mac without the API gets nothing, a buffer that failed to start gets
    /// nothing — the recording is unaffected either way, and a control that refuses when
    /// pressed is worse than one that was never there. The reason is not lost: it is in the
    /// status line if anybody looks.
    ///
    /// **Not a shortcut.** The bar is never made key — the keys a person presses during a take
    /// belong to the app being recorded — so a shortcut on it would fire only after a click on
    /// the bar, for the reason the Stop button records. A system-wide key for this would need
    /// registering beside the stop key, which is a decision about somebody's keyboard and not
    /// one to make on their behalf.
    @ViewBuilder private var clipButton: some View {
        if case .ready(let ceiling) = coordinator.clipReadiness {
            Button { coordinator.saveClip(lastSeconds: ceiling) } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Space.snug)
                    .padding(.vertical, Space.snug)
            }
            .buttonStyle(.plain)
            .help("Save the last \(Int(ceiling)) seconds — the recording keeps going")
        }
    }

    @ViewBuilder private var stopButton: some View {
        Button { coordinator.stop() } label: {
            HStack(spacing: Space.tight + 2) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(.white)
                    .frame(width: 9, height: 9)
                Text("Stop").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Space.regular)
            .padding(.vertical, Space.snug)
            .background(Capsule().fill(Signal.record))
        }
        .buttonStyle(.plain)
        // **No `.keyboardShortcut` here.** The bar is ordered front and never made key
        // (`RecordingBarPresenter.show`), because the keyboard belongs to the app being
        // recorded; a shortcut on it fires only after somebody has clicked the bar, which is
        // what ⎋ was doing — nothing. The key that stops a recording is registered
        // system-wide; see `GlobalHotkey`.
        .help("Stop recording (\(GlobalHotkey.toggleRecordingSpelling))")
    }

}

/// An icon button on the bar. Hover feedback rather than a permanent border: a strip of bordered
/// buttons over a person's screen is a strip of clutter.
private struct BarButton: View {
    let icon: String
    let label: LocalizedStringKey
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(isHovering ? 1 : 0.8))
                .frame(width: 30, height: 30)
                .background {
                    RoundedRectangle(cornerRadius: Glass.controlRadius, style: .continuous)
                        .fill(.white.opacity(isHovering ? Glass.hoverOpacity : 0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The dot and the clock. **`monospacedDigit`, and it is not cosmetic**: a timecode whose
/// digits change width jitters the two controls beside it every second.
private struct BarState: View {
    let coordinator: RecordingCoordinator

    var body: some View {
        HStack(spacing: Space.snug) {
            PulsingDot(isPaused: coordinator.isPaused)
            Text(verbatim: ElapsedTime.text(coordinator.elapsed))
                .font(.system(size: 15, weight: .medium).monospacedDigit())
                .foregroundStyle(.white)
            if coordinator.isPaused {
                Text("PAUSED")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Signal.paused)
                    .padding(.horizontal, Space.tight + 2)
                    .padding(.vertical, Space.hairline)
                    .background(Capsule().fill(Signal.paused.opacity(0.16)))
            }
        }
    }
}

/// The microphone, with its level under it — a surveyed recorder puts a two-pixel meter inside
/// the mic button for the same reason: the question a person has during a recording is not "is the
/// microphone on" but "is it hearing me", and only a moving bar answers that.
private struct BarMicrophone: View {
    let guards: TakeGuards

    var body: some View {
        VStack(spacing: Space.tight) {
            if guards.microphoneHearsNothing {
                // **The meter is replaced, not joined.** A meter at the bottom of its track looks
                // exactly like a quiet room; this is the one state it cannot show.
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Signal.paused)
            } else {
                Image(systemName: guards.microphoneLevel == nil ? "mic.slash" : "mic.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(guards.microphoneLevel == nil ? 0.45 : 0.95))
            }
            LevelMeter(level: guards.microphoneLevel)
        }
        .frame(width: 34)
        .help(guards.microphoneHearsNothing ? Text("The microphone hears nothing")
              : guards.microphoneLevel == nil
              ? Text("No microphone in this recording") : Text("Microphone level"))
    }
}
