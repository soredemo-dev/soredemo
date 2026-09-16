import AppKit
import Geometry
import SwiftUI

/// The editor coming out of the notch.
///
/// **What this is covering for.** A window entering native full screen moves to its own Space,
/// and macOS animates that itself: the desktop slides sideways and the window zooms. None of
/// that is ours to animate, and all of it is visible. So a panel goes up first, full-screen
/// from its first frame, and what a person sees is a shape growing out of the notch while
/// AppKit does its work behind it.
///
/// **It animates to the frame the window ACTUALLY reached, read from the window.**
/// `FullScreenEntry` can spend its budget and leave a grown window instead, and a shape that
/// animated to a full-screen rectangle and then handed over to a 900-point window would end in
/// a jump. Asking beats assuming, which is the rule the rest of this codebase runs on.
///
/// Design, measurements and what is still unsettled:
/// docs/design/the-editor-comes-out-of-the-notch.md
@MainActor
final class NotchOpening {
    static let shared = NotchOpening()

    private var panel: NSPanel?
    private var runner: Task<Void, Never>?

    /// What the last run did, so a check does not have to catch it with a screenshot.
    ///
    /// **`--report-window-state` prints this**, which makes the full-screen gate evidence that
    /// the opening played as well as evidence that the window got there. A transition that
    /// silently never ran would otherwise look exactly like one that ran perfectly: the editor
    /// ends up full screen either way, and the only difference is half a second nobody was
    /// watching.
    private(set) var lastRun: Run = .notPlayed

    /// How a run of the opening ended. Never `nil`: before anything plays, `notPlayed` is a
    /// fact about this process rather than an absence of one.
    enum Run: String, Equatable {
        /// Nothing has asked for one.
        case notPlayed
        /// Asked while one was already running, so this one was declined. It runs on a window's
        /// first appearance and a second overlay would be a panel above everything.
        case alreadyRunning
        /// The window had no screen to play on.
        case noScreen
        /// Playing now.
        case playing
        /// The window went away before it could be aimed.
        case windowWentAway
        /// Played to the end.
        case finished
    }

    private init() {}

    /// **How long the overlay will wait for the window to settle before animating to whatever
    /// frame it has.** `FullScreenEntry` spends up to six seconds on a busy machine, and a
    /// backdrop that sat black for six seconds would be worse than the transition it replaces.
    /// Past this the shape grows to the window's current frame, which is the honest answer: it
    /// is where the editor is.
    static let settleBudget: Double = 1.2

    /// The window the shape is aiming at, once there is one. **`nil` is a state, not an
    /// absence**: the cover can go up before SwiftUI has built a window at all.
    private weak var target: NSWindow?

    /// Raises the cover, before anything a person should not see.
    ///
    /// **Before the window exists, which is earlier than it used to be.** The editor is created
    /// at its autosaved size, ordered front, resized to the screen and only then asked for full
    /// screen — three visible steps, and the cover used to arrive at the third. It goes up on
    /// the screen the pointer is on, the same choice the countdown and the recording bar make.
    func beginCovering(on screen: NSScreen, reduceMotion: Bool) {
        guard runner == nil else { return lastRun = .alreadyRunning }
        lastRun = .playing
        let transition = NotchTransition.chosen(reduceMotion: reduceMotion)
        let state = NotchOpeningState(transition: transition,
                                      screenFrame: GlobalRect.topLeft(of: screen))
        show(state, on: screen)
        // **The clock starts NOW, and that was the defect behind "two or three animations".**
        // The panel used to go up immediately and stay fully transparent until the window had
        // settled — up to 1.2 seconds — so AppKit's own full-screen zoom and the desktop
        // sliding to a new Space played in the open, and only then did the ground darken. The
        // backdrop is the part that must be there from the first frame; the shape is the part
        // that has to wait for an answer, and `NotchOpeningState.run` holds the clock at the
        // shape's start until the geometry arrives.
        let clock = Task { @MainActor in await state.run() }
        runner = Task { @MainActor [weak self] in
            defer {
                clock.cancel()
                self?.target = nil
                self?.hide()
                self?.runner = nil
            }
            guard let self else { return }
            guard let settled = await Self.settledFrame(waitingFor: { self.target }) else {
                lastRun = .windowWentAway
                return
            }
            let aimed = target?.screen ?? screen
            state.geometry = NotchGeometry.opening(into: settled, on: Self.metrics(of: aimed))
            await clock.value
            lastRun = .finished
        }
    }

    /// Says which window the shape is growing into. May arrive after `beginCovering`.
    func aim(at window: NSWindow) { target = window }

    /// Both at once, for the path that already has a window.
    func play(over window: NSWindow, reduceMotion: Bool) {
        if runner == nil {
            guard let screen = window.screen ?? NSScreen.main else { return lastRun = .noScreen }
            beginCovering(on: screen, reduceMotion: reduceMotion)
        }
        aim(at: window)
    }

    /// Stops it, wherever it is. **One owner, cancelled on window close**, the way
    /// `CountdownPresenter` is: a panel at `.screenSaver` level that outlives what it was
    /// covering is above everything on the machine.
    func cancel() {
        runner?.cancel()
        runner = nil
        target = nil
        hide()
    }

    /// The frame of the window being aimed at, once it has stopped changing.
    ///
    /// **Waits for the window to EXIST as well as to settle, under one budget.** The cover can
    /// be raised before SwiftUI has built anything, and a wait that assumed a window would give
    /// up immediately on the path that needed it most.
    private static func settledFrame(waitingFor window: @escaping @MainActor () -> NSWindow?)
        async -> PointRect? {
        let steps = Int(settleBudget / 0.05)
        var found: NSWindow?
        for _ in 0..<steps {
            if Task.isCancelled { return nil }
            if let candidate = window() {
                found = candidate
                if candidate.styleMask.contains(.fullScreen) { break }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let found else { return nil }
        return GlobalRect.topLeft(of: found)
    }

    /// Plays it over nothing, against a geometry handed in — `--show-notch-transition`.
    ///
    /// **Separate from `play(over:reduceMotion:)` rather than a flag on it**, because the thing
    /// that makes this a tuning tool is the thing `play` must never do: it does not wait for a
    /// window, so there is no settling and no failure to fall back from. Returns when the
    /// animation is over.
    func playAlone(geometry: NotchGeometry, screen: NSScreen, reduceMotion: Bool,
                   slowdown: Double = 1, hold: Double? = nil) async {
        let state = NotchOpeningState(transition: .chosen(reduceMotion: reduceMotion),
                                      screenFrame: GlobalRect.topLeft(of: screen))
        state.geometry = geometry
        show(state, on: screen)
        defer { hide() }
        // **Frozen at one moment, for looking at the shape.** Chasing a 0.55 s animation with
        // `screencapture` — which takes about a third of a second a frame — failed four times
        // before this existed: every capture landed before or after it. A held frame is the
        // instrument for a SHAPE. Speed still needs a person at 1x.
        if let hold {
            state.time = hold
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(200)) }
            return
        }
        await state.run(slowdown: slowdown)
    }

    /// The five numbers `NotchGeometry` needs, read off a real screen.
    ///
    /// **In global TOP-LEFT points**, which is the space the animation works in — not AppKit's
    /// bottom-left frame. Through `GlobalRect`, which is where that conversion lives and says
    /// why it lives in exactly one place.
    static func metrics(of screen: NSScreen) -> ScreenMetrics {
        ScreenMetrics(
            frame: GlobalRect.topLeft(of: screen),
            safeAreaTop: Double(screen.safeAreaInsets.top),
            menubarHeight: Double(screen.frame.maxY - screen.visibleFrame.maxY),
            auxiliaryLeftWidth: screen.auxiliaryTopLeftArea.map { Double($0.width) },
            auxiliaryRightWidth: screen.auxiliaryTopRightArea.map { Double($0.width) })
    }

    private func show(_ state: NotchOpeningState, on screen: NSScreen) {
        let panel = NSPanel(contentRect: screen.frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // **Click-through.** This is scenery over a window somebody is about to use, and half a
        // second of a panel eating clicks is half a second of an editor that ignores them.
        panel.ignoresMouseEvents = true
        let hosting = NSHostingView(rootView: NotchOpeningView(state: state))
        hosting.frame = NSRect(origin: .zero, size: screen.frame.size)
        panel.contentView = hosting
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// The animation's clock and what it is drawing, as an object the panel's view watches.
///
/// **Driven by one value, not by SwiftUI animating a rectangle.** The shape's width grows 8.2x
/// and its height 29.7x on the machine this was designed on; handing those to one animation
/// would stretch anything drawn inside nearly four times more vertically than horizontally.
/// `NotchGeometry.rect(atProgress:)` interpolates every edge itself, and this feeds it.
@MainActor
@Observable
final class NotchOpeningState {
    let transition: NotchTransition
    /// Where the shape starts and ends. `nil` until the window has settled and said where it
    /// landed — the backdrop is already up by then, which is the whole point of the ordering.
    var geometry: NotchGeometry?
    /// Seconds since the shape began.
    var time: Double = 0
    /// The screen this is playing on, in global top-left points. **The panel covers exactly
    /// this**, and SwiftUI measures from the panel's own top-left, so it is what turns a global
    /// rectangle into one the view can place.
    let screenFrame: PointRect

    init(transition: NotchTransition, screenFrame: PointRect) {
        self.transition = transition
        self.screenFrame = screenFrame
    }

    /// Runs the clock. **Sixty steps a second, driven here rather than by a `TimelineView`**,
    /// because the view must not re-evaluate its body to decide anything — it reads one number
    /// and draws.
    ///
    /// `slowdown` stretches the wall-clock time each step waits without changing the animation's
    /// own timeline, so the SHAPE can be inspected frame by frame. It is 1 everywhere but
    /// `--show-notch-transition`: `screencapture` takes about a third of a second a frame and
    /// the whole gesture is half a second, so six shots aimed at it caught nothing twice.
    /// **It cannot settle the durations** — those are a judgement about speed and the only
    /// instrument for them is somebody watching at 1x.
    func run(slowdown: Double = 1) async {
        let step = 1.0 / 60
        let wait = max(1, Int(step * 1000 * max(1, slowdown)))
        var elapsed = 0.0
        while elapsed < transition.total {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(wait))
            // **Held at the shape's start until somebody says where the shape ends.** The
            // backdrop runs on the same clock and must not wait for that: it is what covers
            // AppKit's own full-screen transition, and a backdrop that arrives after it has
            // finished has covered nothing. A held clock rather than two is what keeps the
            // phases' overlaps meaning what `NotchTransition` says they mean once it moves
            // again.
            if transition.drawsShape, geometry == nil, elapsed >= transition.shape.start {
                continue
            }
            elapsed += step
            time = elapsed
        }
        time = transition.total
    }
}

private struct NotchOpeningView: View {
    let state: NotchOpeningState

    /// **Near-black rather than a blur of the desktop.** Black is honest about what is
    /// happening — the screen is changing Space — and it is the one treatment that cannot look
    /// wrong over an unknown desktop. A heavy blur is prettier and has not been looked at.
    private static let backdropOpacity: Double = 0.92

    var body: some View {
        ZStack {
            Color.black
                .opacity(Self.backdropOpacity * state.transition.backdrop.progress(at: state.time))
                .ignoresSafeArea()
            if state.transition.drawsShape, let geometry = state.geometry {
                shape(geometry)
            }
        }
        .opacity(1 - state.transition.reveal.progress(at: state.time))
        .ignoresSafeArea()
    }

    @ViewBuilder private func shape(_ geometry: NotchGeometry) -> some View {
        // **Eased here, not by SwiftUI.** The clock is linear; the gesture is not. A spring over
        // this distance overshoots by enough that a window appears to bounce past its own edge,
        // which reads as a bug rather than a flourish — so this is a curve that decelerates and
        // does not overshoot.
        let linear = state.transition.shape.progress(at: state.time)
        let eased = 1 - pow(1 - linear, 3)
        let rect = geometry.rect(atProgress: eased)
        // Global top-left to the panel's own space. The panel covers exactly one screen, so the
        // offset is that screen's origin — and on a second display it is not zero, which is the
        // case a subtraction left out would get wrong only there.
        let x = rect.x - state.screenFrame.x
        let y = rect.y - state.screenFrame.y
        // **`UnevenRoundedRectangle`, not a hand-written `Shape`.** A custom one would have to
        // name `CGRect` in `path(in:)`, which D6 rule 5 forbids in the app target — and the
        // built-in does exactly the thing that makes this read as the notch getting larger
        // rather than a new rectangle appearing: the top corners keep their radius while only
        // the bottom two open.
        UnevenRoundedRectangle(
            topLeadingRadius: geometry.topRadius(atProgress: eased),
            bottomLeadingRadius: geometry.bottomRadius(atProgress: eased),
            bottomTrailingRadius: geometry.bottomRadius(atProgress: eased),
            topTrailingRadius: geometry.topRadius(atProgress: eased),
            style: .continuous)
            // **The editor's own ground, not black.** The panel hands over to a real window at
            // the end, and a shape that is not the colour of the thing it becomes hands over
            // with a step in it. `Theme.Surface.base` is what the editor paints behind
            // everything.
            .fill(Theme.Surface.base)
            // **A hairline edge that fades as it grows.** At notch size, against a desktop the
            // backdrop has barely started to darken, a near-black shape on a dark strip is
            // invisible — the first tenth of the gesture would be nothing happening. The same
            // light edge `Glass` uses, and for the same reason: it is what separates a dark
            // surface from a dark ground. It goes as the shape takes over the screen, because
            // by then there is nothing to separate it from.
            .overlay {
                UnevenRoundedRectangle(
                    topLeadingRadius: geometry.topRadius(atProgress: eased),
                    bottomLeadingRadius: geometry.bottomRadius(atProgress: eased),
                    bottomTrailingRadius: geometry.bottomRadius(atProgress: eased),
                    topTrailingRadius: geometry.topRadius(atProgress: eased),
                    style: .continuous)
                    .strokeBorder(.white.opacity(Glass.edgeOpacity * (1 - eased)), lineWidth: 1)
            }
            .frame(width: rect.width, height: rect.height)
            // The two corners curling outward into the menu bar. Drawn beside the body rather
            // than as one path, because a custom `Shape`'s `path(in:)` names `CGRect` and D6
            // rule 5 forbids that in the app target.
            .overlay(alignment: .topLeading) { flare(geometry, at: eased, leading: true) }
            .overlay(alignment: .topTrailing) { flare(geometry, at: eased, leading: false) }
            .position(x: x + rect.width / 2, y: y + rect.height / 2)
    }

    /// One top corner curling outward, so the shape reads as the notch getting larger rather
    /// than a panel hanging below it.
    ///
    /// **A square with a quarter-disc taken out of it**, offset just outside the body's corner.
    /// The disc is centred on the square's INNER-bottom corner, which leaves the concave wedge
    /// against the menu bar — the shape the hardware notch has. `compositingGroup` is what makes
    /// `destinationOut` cut only this square rather than everything behind it.
    @ViewBuilder private func flare(_ geometry: NotchGeometry, at progress: Double,
                                    leading: Bool) -> some View {
        let size = geometry.topFlare(atProgress: progress)
        if size > 0.5 {
            Theme.Surface.base
                .frame(width: size, height: size)
                .overlay(alignment: leading ? .topLeading : .topTrailing) {
                    Circle()
                        .frame(width: size * 2, height: size * 2)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
                .offset(x: leading ? -size : size)
        }
    }
}
