import AppKit
import Capture
import Geometry
import Render
import SwiftUI
import Timeline

/// How the daruma is standing: `DarumaFace`'s numbers, with the app's reason for each pose as a
/// function beside the state it answers (`DarumaPoseTests`). The geometry a pose draws is
/// `DarumaFigure`, pure, in Core. `docs/design/2026-10-26-a-character-not-a-logo.md`.
typealias DarumaPose = DarumaFace

extension DarumaFace {
    /// The panel's header looks down at the card the pointer is over — Screen on the left,
    /// Window in the middle, Area on the right — so the character says what the next press will
    /// capture.
    static func looking(at target: CaptureTarget?) -> DarumaPose {
        switch target {
        case .screen: DarumaPose(yaw: -0.8, pitch: 0.7)
        case .window: DarumaPose(yaw: 0, pitch: 0.8)
        case .area: DarumaPose(yaw: 0.8, pitch: 0.7)
        case nil: .resting
        }
    }

    /// The countdown: a ring round the right eye drains each second, and the last second lights
    /// the eye — painted as the recording begins.
    /// Poked: its open eyes squeezed shut. A lit record eye stays lit and a smile stays a smile.
    func squeezed() -> DarumaPose {
        var pose = self
        if [.open, .sad].contains(pose.left) { pose.left = .closed }
        if [.open, .sad].contains(pose.right) { pose.right = .closed }
        return pose
    }

    static func counting(remaining: Int, ringRemaining: Double) -> DarumaPose {
        // The brush runs over the last 0.4 of the last second (`docs/design/2026-10-27-…-paints.md`).
        let paint = min(1, max(0, (0.4 - ringRemaining) / 0.4))
        return DarumaPose(openness: 1.15, right: remaining <= 1 ? .record : .open, countRing: ringRemaining,
                          recordPaint: remaining <= 1 ? paint : 1)
    }

    /// The notch, per state: resting when offered; the record eye lit while a take runs; the
    /// pause symbol for eyes while it is paused; both eyes smiling when it is done.
    static func notch(_ state: NotchSurfaceState, isPaused: Bool) -> DarumaPose {
        switch state {
        case .dormant, .glance, .open: .resting
        case .live: isPaused ? DarumaPose(left: .pause, right: .pause) : DarumaPose(openness: 0.9, right: .record)
        case .finished: DarumaPose(left: .happy, right: .happy)
        }
    }

    /// The permissions page: one eye per permission. The left opens with Accessibility, the
    /// right — the record eye — lights with Screen Recording; neither is a sleeping daruma.
    static func permissions(screenRecording: Bool, accessibility: Bool) -> DarumaPose {
        DarumaPose(left: accessibility ? .open : .closed, right: screenRecording ? .record : .closed)
    }
}

/// The character's face: the daruma's window, or its eyes straight on the body — the person's
/// choice in Settings, the window by default.
enum DarumaFaceStyle: String, CaseIterable, Sendable {
    case window, bare
    static let defaultsKey = "darumaFaceStyle"

    var displayName: String {
        switch self {
        case .window: "Face window"
        case .bare: "Eyes on the body"
        }
    }
}

/// The colour the character is drawn in — the person's choice in Settings; vermilion, the
/// traditional daruma's, by default (the owner, 2026-10-26).
enum DarumaColour: String, CaseIterable, Sendable {
    case vermilion, ink, paper, gold, appearance
    static let defaultsKey = "darumaColour"

    var displayName: String {
        switch self {
        case .appearance: "Match Appearance"
        case .vermilion: "Vermilion"
        case .ink: "Ink"
        case .paper: "Paper"
        case .gold: "Gold"
        }
    }

    /// Body, face and eye, for a face window or for eyes on the body. Following the appearance it
    /// is the theme's ink: paper on dark, sumi on light — the accent's rule.
    ///
    /// **Each colour is designed for both faces**, not only its body swapped. With a window: a
    /// white window and sumi eyes, except paper, whose window is sumi and eyes paper. On the body:
    /// sumi eyes on vermilion, gold and paper — the reference's dark eyes on a coloured body — and
    /// paper eyes on ink.
    func tones(dark: Bool, window: Bool = true) -> (body: Palette.RGB, face: Palette.RGB, eye: Palette.RGB) {
        let sumi = Palette.Brand.sumi, white = Palette.RGB(hex: 0xFFFFFF), paperEye = Palette.RGB(hex: 0xF7F6F2)
        switch self {
        case .appearance: return dark ? Self.paper.tones(dark: dark, window: window) : Self.ink.tones(dark: dark, window: window)
        case .vermilion: return (Palette.Brand.shuNuri, white, sumi)
        case .ink: return (Palette.RGB(hex: 0x1F2025), white, window ? sumi : paperEye)
        case .paper: return (Palette.RGB(hex: 0xF4F3EF), Palette.RGB(hex: 0x1B1C21), window ? paperEye : sumi)
        case .gold: return (Palette.Brand.kin, white, sumi)
        }
    }
}

/// The character, drawn from a figure. **The colour is passed in, never read here**: a caller
/// that follows the person's choice reads it (`LivingDaruma` does), so a drawing depends on its
/// arguments and the appearance alone.
///
/// **Colour** is the flat character with its face window, the record eye red. **Template** is the
/// same figure as one even-odd path in the foreground's ink — the menu bar, the panel header, the
/// empty editor — filled as a view rather than in a Canvas, which drew nothing in the menu bar's
/// vibrant popover (2026-10-25).
struct DarumaView: View, Animatable {
    enum Style { case colour, template }

    var pose: DarumaPose = .resting
    var colour: DarumaColour = .appearance
    var style: Style = .colour
    /// A washi edge round the body, for a mark drawn over whatever is on screen.
    var rimmed = false
    var blink = 1.0
    var breath = 0.0
    @Environment(\.colorScheme) private var scheme

    /// The gaze and the eyes' openness ease; the count's ring does not — it is a clock, and a
    /// spring behind it left the countdown's ring unfinished as the panel went.
    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, Double> {
        get { AnimatablePair(AnimatablePair(pose.yaw, pose.pitch), pose.openness) }
        set {
            pose.yaw = newValue.first.first
            pose.pitch = newValue.first.second
            pose.openness = newValue.second
        }
    }

    var body: some View {
        let figure = DarumaFigure.make(pose, blink: blink, breath: breath)
        Group {
            switch style {
            case .colour: colourBody(figure)
            case .template:
                GeometryReader { proxy in
                    Self.templatePath(figure, mapping: Mapping(width: Double(proxy.size.width), height: Double(proxy.size.height)),
                                      window: pose.faceWindow)
                        .fill(style: FillStyle(eoFill: true))
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// Maps the 100-unit box onto a canvas, centred, its shorter side filled.
    struct Mapping {
        let unit: Double, left: Double, top: Double
        init(width: Double, height: Double) {
            unit = min(width, height) / 100
            left = (width - 100 * unit) / 2
            top = (height - 100 * unit) / 2
        }
        init(unit: Double, left: Double, top: Double) {
            self.unit = unit
            self.left = left
            self.top = top
        }
        func x(_ v: Double) -> Double { left + v * unit }
        func y(_ v: Double) -> Double { top + v * unit }
    }

    static func bodyPath(_ f: DarumaFigure, _ m: Mapping) -> Path {
        Path(CGGeometryBridge.darumaBody(width: f.bodyWidth, height: f.bodyHeight, crown: f.crown,
                                         in: PointRect(x: m.left, y: m.top, width: 100 * m.unit, height: 100 * m.unit)))
    }

    static func facePath(_ f: DarumaFigure, _ m: Mapping) -> Path {
        Path(CGGeometryBridge.ellipse(centreX: m.x(f.face.x), centreY: m.y(f.face.y),
                                      radiusX: f.face.rx * m.unit, radiusY: f.face.ry * m.unit, tilt: f.face.tilt))
    }

    /// One eye as a fillable shape: a pill, a disc for the record eye, a band along an arc for a
    /// closed or smiling one.
    static func eyePath(_ e: DarumaFigure.EyeMark, _ m: Mapping) -> Path {
        let x = m.x(e.x), y = m.y(e.y), u = m.unit
        switch e.kind {
        case .open, .sad:
            return Path(CGGeometryBridge.pill(centreX: x, centreY: y, width: e.width * u, height: e.height * u, tilt: e.tilt))
        case .pause:
            return Path(CGGeometryBridge.bar(centreX: x, centreY: y, width: e.width * u, height: e.height * u, corner: e.width * 0.3 * u))
        case .record:
            let r = e.width * 0.8 * u
            return Path(CGGeometryBridge.ellipse(centreX: x, centreY: y, radiusX: r, radiusY: r, tilt: 0))
        case .closed:
            return Path(CGGeometryBridge.strokedArc(fromX: x - e.width / 2 * u, fromY: y - 0.5 * u, controlX: x, controlY: y + 3 * u,
                                                    toX: x + e.width / 2 * u, toY: y - 0.5 * u, lineWidth: 2.6 * u))
        case .happy:
            return Path(CGGeometryBridge.strokedArc(fromX: x - e.width / 2 * u, fromY: y + 2 * u, controlX: x, controlY: y - 5 * u,
                                                    toX: x + e.width / 2 * u, toY: y + 2 * u, lineWidth: 3 * u))
        }
    }

    /// The small mark as one even-odd path: the body, the face cut out of it, the eyes inside the
    /// face. Each lies inside the last, so even-odd alternates ink and paper without drawing ink
    /// twice — the foreground ink is translucent.
    static func templatePath(_ f: DarumaFigure, width: Double, height: Double) -> Path {
        templatePath(f, mapping: Mapping(width: width, height: height))
    }

    /// The same at any mapping, with the eye at `omitting` left out — the menu bar draws the lit
    /// record eye itself, in red.
    static func templatePath(_ f: DarumaFigure, mapping m: Mapping, omitting: Int? = nil, window: Bool = true) -> Path {
        var path = bodyPath(f, m)
        // With a window the eyes are ink in a hole; without one they are holes in the body.
        if window { path.addPath(facePath(f, m)) }
        for (i, eye) in f.eyes.enumerated() where i != omitting { path.addPath(eyePath(eye, m)) }
        return path
    }

    private func colourBody(_ f: DarumaFigure) -> some View {
        Canvas { context, size in
            let m = Mapping(width: Double(size.width), height: Double(size.height))
            let tones = colour.tones(dark: scheme == .dark, window: pose.faceWindow)
            let body = Self.bodyPath(f, m)
            context.fill(body, with: .color(tones.body.color))
            // A flat character with one soft highlight on its crown, as light falls on a lacquered
            // daruma — no gradient, which a Canvas would need a point type for.
            let shine = Path(CGGeometryBridge.ellipse(centreX: m.x(40), centreY: m.y(22 + (1 - f.bodyHeight) * 82),
                                                      radiusX: 11 * m.unit, radiusY: 5 * m.unit, tilt: -12))
            context.fill(shine, with: .color(.white.opacity(0.18)))
            if rimmed {
                context.stroke(body, with: .color(Palette.Brand.washi.color), lineWidth: 1.6 * m.unit)
            }
            if pose.faceWindow { context.fill(Self.facePath(f, m), with: .color(tones.face.color)) }
            let red = Color(Signal.record)
            for eye in f.eyes {
                if eye.kind == .record {
                    // **Painted, as a daruma's eye is**: while the countdown's brush runs, the ink eye
                    // goes at once and a band of red sweeps round like a clock hand, clipped to the eye.
                    let paint = min(max(pose.recordPaint, 0), 1)
                    if paint < 0.12, let open = f.eyes.first(where: { $0.kind != .record }) {
                        var ink = eye
                        (ink.kind, ink.height) = (.open, open.height)
                        context.fill(Self.eyePath(ink, m), with: .color(tones.eye.color.opacity(1 - paint / 0.12)))
                    }
                    // The lit eye glows a little, as the record light does.
                    let r = eye.width * 0.8 * m.unit
                    let halo = Path(CGGeometryBridge.ellipse(centreX: m.x(eye.x), centreY: m.y(eye.y),
                                                             radiusX: r * 1.6, radiusY: r * 1.6, tilt: 0))
                    context.fill(halo, with: .color(red.opacity(0.22 * paint)))
                    // On the body there is no white window behind it, and red on vermilion is
                    // lost: a washi ring holds the record eye apart from any body.
                    if !pose.faceWindow {
                        let ring = Path(CGGeometryBridge.ellipse(centreX: m.x(eye.x), centreY: m.y(eye.y),
                                                                 radiusX: r * 1.3, radiusY: r * 1.3, tilt: 0))
                        context.fill(ring, with: .color(Palette.Brand.washi.color.opacity(paint)))
                    }
                    if paint < 1 {
                        let brush = CGGeometryBridge.brushSweep(centreX: m.x(eye.x), centreY: m.y(eye.y), radius: r, painted: paint)
                        context.drawLayer { layer in
                            layer.clip(to: Self.eyePath(eye, m))
                            layer.stroke(Path(brush), with: .color(red), style: StrokeStyle(lineWidth: r * 1.02, lineCap: .butt))
                        }
                    } else {
                        context.fill(Self.eyePath(eye, m), with: .color(red))
                    }
                } else {
                    context.fill(Self.eyePath(eye, m), with: .color(tones.eye.color))
                }
            }
            // The countdown's ring round the right eye: a faint track, and what is left of this
            // second in full red, from twelve o'clock, clockwise.
            if let ring = pose.countRing, let eye = f.eyes.last {
                let radius = (max(eye.width, eye.height) / 2 + 3.2) * m.unit
                let track = Path(CGGeometryBridge.ellipse(centreX: m.x(eye.x), centreY: m.y(eye.y),
                                                          radiusX: radius, radiusY: radius, tilt: 0))
                context.stroke(track, with: .color(red.opacity(0.28)), lineWidth: 2.2 * m.unit)
                let arc = CGGeometryBridge.countdownArc(centreX: m.x(eye.x), centreY: m.y(eye.y), radius: radius, remaining: ring)
                context.stroke(Path(arc), with: .color(red), style: StrokeStyle(lineWidth: 2.2 * m.unit, lineCap: .round))
            }
        }
    }
}

/// When the character blinks and how it breathes, as functions of time — **deterministic**, so
/// the app reads no randomness: each 3.6-second period blinks once at an offset hashed from the
/// period's index, and one period in five blinks twice.
enum DarumaLife {
    static func blink(at t: Double) -> Double {
        let period = 3.6, n = (t / period).rounded(.down)
        func hash(_ seed: Double) -> Double { let v = sin(n * seed) * 43_758.5453; return v - v.rounded(.down) }
        var d = t - (n * period + hash(12.9898) * 2.2)
        if hash(78.233) < 0.2, d > 0.32 { d -= 0.32 }
        let x = d / 0.13
        guard x >= 0, x < 2 else { return 1 }
        return max(x < 1 ? 1 - x : x - 1, 0.06)
    }

    static func breath(at t: Double) -> Double { sin(t * 1.8) * 0.012 }

    /// Where to look for a pointer at screen point (`px`, `py`, y up) from a character whose frame
    /// on screen is `frame` (y up): toward it, harder the farther it is, up to 1.
    static func gaze(pointerX px: Double, pointerY py: Double, from frame: PointRect) -> (yaw: Double, pitch: Double) {
        let dx = px - (frame.x + frame.width / 2), dy = (frame.y + frame.height / 2) - py
        let d = max((dx * dx + dy * dy).squareRoot(), 0.001), k = min(1, d / 320)
        return (dx / d * k, dy / d * k)
    }
}

/// The character alive: it blinks, breathes, and — where it is asked to — looks at the pointer
/// when nothing else tells it where to look. Its colour is the person's choice unless the caller
/// gives one. Under Reduce Motion it is still: no blink, no breath, eyes that move without
/// travelling. `pokeable`, a click tips it and it rocks back upright (`DarumaRock`) — under Reduce
/// Motion it only squeezes its eyes. `docs/design/2026-10-27-the-daruma-tips-flies-and-paints.md`.
struct LivingDaruma: View {
    var pose: DarumaPose = .resting
    var style: DarumaView.Style = .colour
    var colour: DarumaColour?
    var followsPointer = false
    var rimmed = false
    var pokeable = false
    @State private var poke: (rock: DarumaRock, at: Nanoseconds)?
    @State private var width = 0.0
    @AppStorage(DarumaColour.defaultsKey) private var chosen = DarumaColour.vermilion
    @AppStorage(DarumaFaceStyle.defaultsKey) private var faceStyle = DarumaFaceStyle.window
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var place = ScreenPlace()

    var body: some View {
        // The timeline only says WHEN to redraw; the time itself is minted, as the app's every
        // clock reading is (`Minting`, rule 3).
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion && poke == nil)) { _ in
            let now = Minting.continuousNow(), t = Double(now.rawValue) / 1_000_000_000
            let since = poke.map { Double((now - $0.at).rawValue) / 1_000_000_000 } ?? -1
            let face = poke?.rock.isSqueezing(at: since) == true ? shown().squeezed() : shown()
            DarumaView(pose: face, colour: colour ?? chosen, style: style, rimmed: rimmed,
                       blink: reduceMotion ? 1 : DarumaLife.blink(at: t),
                       breath: reduceMotion ? 0 : DarumaLife.breath(at: t))
                .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.78), value: face)
                // On its round base, the bottom of the body (93 of the box's 100 units).
                .rotationEffect(.degrees(reduceMotion ? 0 : poke?.rock.angle(at: since) ?? 0),
                                anchor: UnitPoint(x: 0.5, y: 0.93))
        }
        .background(ScreenPlaceReader(place: place))
        .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { width = $0 }
        // Simultaneous, so a caller's own tap (Settings' preview chooses the colour) still fires.
        .simultaneousGesture(SpatialTapGesture().onEnded { tap in
            let at = Minting.continuousNow()
            poke = (DarumaRock(touchedAt: Double(tap.location.x), width: width), at)
            Task {
                try? await Task.sleep(for: .seconds(2.4))
                if poke?.at == at { poke = nil }
            }
        }, including: pokeable ? .all : .subviews)
    }

    /// The pose, its gaze taken from the pointer when it is asked to follow and the pose itself
    /// looks straight ahead.
    private func shown() -> DarumaPose {
        var pose = pose
        pose.faceWindow = faceStyle == .window
        guard followsPointer, pose.yaw == 0, pose.pitch == 0, let frame = place.frame else { return pose }
        let pointer = NSEvent.mouseLocation
        (pose.yaw, pose.pitch) = DarumaLife.gaze(pointerX: Double(pointer.x), pointerY: Double(pointer.y), from: frame)
        return pose
    }
}

/// Where a view is on screen, kept in an object so reading it does not redraw anything.
@MainActor final class ScreenPlace { var frame: PointRect? }

/// Writes its own frame on screen (y up) into a `ScreenPlace` whenever it is laid out.
private struct ScreenPlaceReader: NSViewRepresentable {
    let place: ScreenPlace

    func makeNSView(context: Context) -> Reader { Reader(place: place) }
    func updateNSView(_ view: Reader, context: Context) { view.record() }

    final class Reader: NSView {
        let place: ScreenPlace
        init(place: ScreenPlace) { self.place = place; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func layout() { super.layout(); record() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); record() }
        func record() {
            guard let window else { return }
            place.frame = CGGeometryBridge.pointRect(from: window.convertToScreen(convert(bounds, to: nil)))
        }
    }
}
