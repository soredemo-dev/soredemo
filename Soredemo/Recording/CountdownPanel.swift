import AppKit
import Capture
import Geometry
import ScreenCaptureKit
import SwiftUI

/// The three seconds between choosing what to record and the recording starting.
///
/// **Without it the first second of every recording is a hand moving away from the mouse.** The
/// picker closes and the capture is already running; there is nowhere to put the pointer and no
/// moment to compose. It is a variant of the recording state rather than a separate mode, and
/// it is on by default.
///
/// **It counts on the screen being recorded, and it is excluded from the recording** — the
/// capture filter leaves this process out, which is what `CaptureSource.filter(excluding:)` is
/// for. A countdown that appeared in the file would be worse than none.
///
/// **What these three seconds are actually for decides what is in them.** They were a number in
/// a circle. A person watching that number has two questions — *did I pick the right thing* and
/// *how long have I got* — and the count answered neither: it names nothing, and between ticks
/// it is a still picture. So the panel now says what is about to be recorded, drains a ring
/// continuously rather than in whole seconds, and takes ⎋. The last of those is the one that
/// matters most: picking the wrong window and being unable to stop is the failure this whole
/// pause exists to prevent, and until now the only way out was to record the mistake.
@MainActor
@Observable
final class CountdownPresenter {
    static let shared = CountdownPresenter()
    @ObservationIgnored private var panel: NSPanel?
    /// The count while it runs — the menu bar's mark watches it. `nil` before and after.
    private(set) var running: CountdownState?

    private init() {}

    /// Runs the countdown and returns whether it finished.
    ///
    /// `false` means somebody pressed ⎋ and the recording must not start. Returns `true`
    /// immediately for zero, which is what "off" is — a person who turned it off is not waiting
    /// for a frame of it, and they have not cancelled anything either.
    func run(seconds: Int, subject: String) async -> Bool {
        guard seconds > 0 else { return true }
        let state = CountdownState(total: seconds, subject: subject)
        show(state)
        running = state
        defer {
            running = nil
            hide()
        }

        for value in stride(from: seconds, through: 1, by: -1) {
            guard !state.isCancelled else { return false }
            state.remaining = value
            // Woken in slices so ⎋ is answered within a tenth of a second rather than at the
            // next whole one. A person who has seen the wrong window has already decided.
            for tenth in 0..<10 {
                guard !state.isCancelled else { return false }
                state.tenthsGone = tenth
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        return !state.isCancelled
    }

    private func show(_ state: CountdownState) {
        let size = PointRect(x: 0, y: 0, width: CountdownView.width, height: CountdownView.height)
        let panel = CountdownKeyPanel(contentRect: CGGeometryBridge.rect(from: size),
                                      styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
        // **`isFloatingPanel` FIRST: setting it overwrites `level`.** The same two lines in
        // the wrong order put the notch cover at `.floating` (3) when it had asked for
        // `.screenSaver` (1000), measured. The countdown had it too, so a floating window over
        // whatever was being recorded could sit on top of the count.
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // **Click-through.** The whole point of the countdown is the seconds before recording,
        // and a person using them to position a window must not be blocked by the count. Key
        // events are a separate stream from mouse events, so ⎋ still arrives.
        panel.ignoresMouseEvents = true

        let hosting = NSHostingView(rootView: CountdownView(state: state))
        hosting.frame = CGGeometryBridge.rect(from: size)
        panel.contentView = hosting

        // Centred on the screen the pointer is on — the one about to be recorded.
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrame(CGGeometryBridge.rect(from: PointRect(
                x: Double(visible.midX) - CountdownView.width / 2,
                y: Double(visible.midY) - CountdownView.height / 2,
                width: CountdownView.width, height: CountdownView.height)), display: true)
        }
        // **Key, never main** — `RecordingBarPanel`'s arrangement and for its reason: ⎋ has to
        // reach this panel, and a `.nonactivatingPanel` can take the keyboard without bringing
        // the app forward and covering the thing somebody is composing.
        panel.orderFrontRegardless()
        panel.makeKey()
        self.panel = panel
    }

    private func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// A panel that can hold the keyboard without taking the app forward.
///
/// **`canBecomeKey` is false by default for a borderless window, and that is why ⎋ did
/// nothing.** The first version called `makeKey()` on a plain `NSPanel` and the countdown ran to
/// the end with the key pressed — observed, not reasoned about, by driving the panel with
/// `--show-countdown` and watching the exit code stay 0. `RecordingBarPanel` overrides the same
/// pair for the same reason; never main, so the window behind keeps its main status and nothing
/// somebody is composing loses focus.
private final class CountdownKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The count, as an object the panel's view can watch. A plain value would need the hosting view
/// rebuilt each second, which recreates the animation from scratch.
@MainActor
@Observable
final class CountdownState {
    var remaining: Int
    /// What the count started at — the ring needs it to know how much of itself to draw, and it
    /// does not change.
    let total: Int
    /// What is about to be recorded, in a person's words: an application's name, "Whole display",
    /// or "Region". **Never a window's title** — that is the contents of somebody's work, and
    /// the application name answers "did I pick the right thing" just as well.
    let subject: String
    /// Set by ⎋. Read by the presenter between slices of the wait.
    var isCancelled = false
    /// Tenths of the current second already waited, 0…9 — the presenter's own slices.
    var tenthsGone = 0
    /// The share of the current second still to run: the menu bar's ring, drained in tenths.
    var ringRemaining: Double { Double(10 - tenthsGone) / 10 }

    init(total: Int, subject: String) {
        self.remaining = total
        self.total = total
        self.subject = subject
    }
}

private struct CountdownView: View {
    let state: CountdownState

    static let width: Double = 280
    static let height: Double = 300
    private static let ring: Double = 168

    /// **Drawn from the ring rather than from `remaining`.** A ring that stepped once a second
    /// would say the same thing as the number and say it at the same moments; one that drains
    /// continuously answers "how long have I got" in between, which is the question the number
    /// cannot answer at all.
    ///
    /// Animated in one pass on appearance instead of per frame: a timer here would wake the main
    /// actor sixty times a second to move a shape SwiftUI can interpolate itself.
    @State private var drained = false

    /// The final second reads differently, because "now" is a different thing to know than
    /// "soon". The ring takes `Signal.record` — red means "this is being captured" everywhere
    /// else in this app, and one second out is close enough to mean it here.
    private var isFinalSecond: Bool { state.remaining <= 1 }

    var body: some View {
        VStack(spacing: Space.regular) {
            ZStack {
                // **A dark scrim UNDER the material, because this has to be legible over
                // anything.** Material alone samples what is behind it, and what is behind it is
                // whatever somebody is about to record — measured over a white web page, the
                // circle came out light grey with white text on it and the digit was barely
                // readable. The scrim fixes the floor; the material still carries the blur that
                // keeps it from looking like a sticker.
                Circle()
                    .fill(.black.opacity(0.62))
                    .background(Circle().fill(.ultraThinMaterial))
                    .environment(\.colorScheme, .dark)
                    .overlay { Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1) }
                    .shadow(color: .black.opacity(0.45), radius: 26)

                // The track, so the drained part of the ring is still readable as a ring.
                Circle()
                    .strokeBorder(.white.opacity(0.22), lineWidth: 4)
                    .padding(6)

                Circle()
                    .trim(from: 0, to: drained ? 0 : 1)
                    .stroke(isFinalSecond ? Signal.record : .white,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    // From the top, clockwise: the direction every timer on this platform drains.
                    .rotationEffect(.degrees(-90))
                    .padding(6)
                    .animation(.easeInOut(duration: 0.25), value: isFinalSecond)

                Text(verbatim: "\(state.remaining)")
                    .font(.system(size: 84, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    // Keyed on the value so each number gets its own transition rather than the
                    // digits morphing into one another.
                    .id(state.remaining)
                    .transition(.scale(scale: 1.35).combined(with: .opacity))
                    .scaleEffect(isFinalSecond ? 1.08 : 1)
            }
            .frame(width: Self.ring, height: Self.ring)

            VStack(spacing: Space.tight) {
                Text(verbatim: state.subject)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("esc to cancel")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, Space.regular)
            .padding(.vertical, Space.snug)
            .background {
                Capsule().fill(.black.opacity(0.62))
                    .background(Capsule().fill(.ultraThinMaterial))
                    .environment(\.colorScheme, .dark)
            }
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
        }
        .frame(width: Self.width, height: Self.height)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: state.remaining)
        .onAppear {
            // One animation for the whole count, started once.
            withAnimation(.linear(duration: Double(state.total))) { drained = true }
        }
        // **A zero-sized `Button`, because ⎋ needs a control to hang on.** The panel takes the
        // keyboard but SwiftUI's shortcut machinery needs something focusable; the same shape
        // `TimelineEditor.shortcutLayer` uses, and for the same reason.
        .overlay {
            Button("Cancel") { state.isCancelled = true }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}

extension CaptureSource {
    /// What the countdown says is about to be recorded.
    ///
    /// **An application's name, never a window's title.** A title is the contents of somebody's
    /// work — the document they have open, the message they are reading — and it would be on
    /// screen in a panel for three seconds and in every screenshot of this app. The application
    /// name answers "did I pick the right thing" just as well, which is the only question these
    /// three seconds are asking.
    var countdownSubject: String {
        switch self {
        case .display:
            return String(localized: "Whole display")
        case .window(let capture):
            return capture.window.owningApplication?.applicationName
                ?? String(localized: "A window")
        case .region:
            return String(localized: "Region")
        }
    }
}
