import Capture
import Geometry
import SwiftUI

/// How the daruma is standing: where its record eye looks, how far each eye is painted, how far
/// it leans. **A value with no drawing in it**, so every place that moves the mark says why in a
/// function with a test (`DarumaPoseTests`), and the view only draws what it is given.
/// `docs/design/2026-10-25-a-daruma-that-answers.md`.
struct DarumaPose: Equatable, Sendable {
    /// −1 … 1: the record eye's glance, left to right.
    var look: Double = 0
    /// 0 … 1: looking down at something below the mark — the panel's cards.
    var attending: Double = 0
    /// 0 … 1: the record eye from a ring to a filled disc.
    var recordFill: Double = 0
    /// The second eye painted in — 目入れ — rather than waiting as a dashed ring.
    var waitingPainted = false
    /// 0 … 1: the countdown's ring round the record eye, the share of this second still to run.
    /// `nil` when nothing is being counted — no ring at all, not an empty one.
    var countRing: Double?

    static let resting = DarumaPose()

    /// The panel's header: the eye looks down at the card the pointer is over — Screen on the
    /// left, Window in the middle, Area on the right — so the mark says what the next press will
    /// capture. No card under the pointer is no glance.
    static func looking(at target: CaptureTarget?) -> DarumaPose {
        switch target {
        case .screen: DarumaPose(look: -1, attending: 1)
        case .window: DarumaPose(look: 0, attending: 1)
        case .area: DarumaPose(look: 1, attending: 1)
        case nil: .resting
        }
    }

    /// The countdown in the middle of the screen: the menu bar's ring round the record eye —
    /// what is left of this second — and in the last second the eye fills as the ring drains,
    /// so it is painted as the recording begins.
    static func counting(remaining: Int, ringRemaining: Double) -> DarumaPose {
        DarumaPose(recordFill: remaining <= 1 ? 1 - ringRemaining : 0, countRing: ringRemaining)
    }

    /// The permissions page: one eye per permission a recording needs. The record eye fills when
    /// Screen Recording is granted; the waiting eye is painted when Accessibility is. Both granted
    /// is the finished daruma.
    static func permissions(screenRecording: Bool, accessibility: Bool) -> DarumaPose {
        DarumaPose(recordFill: screenRecording ? 1 : 0, waitingPainted: accessibility)
    }
}

/// The mark, drawn. **`icon` is passed in, never read here**: a caller that follows the person's
/// choice reads `AppIconChoice` itself, so the drawing depends on nothing but its arguments and
/// the appearance.
///
/// Two styles. **Colour** is the brand kit's large mark — sumi on light, paper on dark, the record
/// eye in the record red, the waiting eye dashed. **Template** is the menu bar's small mark in the
/// foreground's ink, face cut out, no red and no dashed eye — for a place beside text, where a
/// coloured mark would be the loudest thing there and red would claim a recording that is not.
///
/// `Animatable` on the glance and the fill, so a change of pose moves rather than jumps when the
/// caller animates it (and Reduce Motion is the caller's to honour, with the rest of its view).
struct DarumaView: View, Animatable {
    enum Style { case colour, template }

    var pose: DarumaPose = .resting
    var icon: AppIconChoice = .black
    var style: Style = .colour
    /// A washi edge round the body, for a mark drawn over whatever is on screen — over a dark
    /// one a sumi body has no edge of its own.
    var rimmed = false
    @Environment(\.colorScheme) private var scheme

    /// The small mark's record eye, in the 100-unit box. **At rest it is the baked mark's, right
    /// of centre; attending, it travels a row of three looking down** — 40, 52, 64 — because the
    /// large mark's three-unit glance is half a point at the header's 18 and would not be seen.
    static func templateEye(_ pose: DarumaPose) -> (x: Double, y: Double) {
        let a = pose.attending
        return (62 + a * (52 + pose.look * 12 - 62), 47 + a * 4)
    }

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>> {
        get {
            AnimatablePair(AnimatablePair(pose.look, pose.attending),
                           AnimatablePair(pose.recordFill, pose.countRing ?? 0))
        }
        set {
            pose.look = newValue.first.first
            pose.attending = newValue.first.second
            pose.recordFill = newValue.second.first
            // Only a ring that exists is moved: interpolating toward `nil` is not a ring at zero.
            if pose.countRing != nil { pose.countRing = newValue.second.second }
        }
    }

    var body: some View {
        Group {
            switch style {
            case .colour: colour
            // **A path filled as a view, not drawn in a Canvas.** The Canvas's foreground shading
            // drew nothing in the menu bar's vibrant popover (seen by the owner, 2026-10-25) while
            // an offscreen render showed it; a filled path takes the foreground style the way the
            // template image it replaced did.
            case .template:
                GeometryReader { proxy in
                    Self.templatePath(width: Double(proxy.size.width), height: Double(proxy.size.height), pose: pose)
                        .fill(style: FillStyle(eoFill: true))
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// The small mark as one even-odd path: the body, the face cut out of it, the eye's ring
    /// inside the face, and the ring's hole closing as it fills. Each lies inside the last, so
    /// even-odd alternates ink and paper without ever drawing ink twice — the foreground ink is
    /// translucent, and a disc over its own ring darkened the overlap.
    static func templatePath(width: Double, height: Double, pose: DarumaPose) -> Path {
        let unit = min(width, height) / 100
        let left = (width - 100 * unit) / 2, top = (height - 100 * unit) / 2
        func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> PointRect {
            PointRect(x: left + x * unit, y: top + y * unit, width: w * unit, height: h * unit)
        }
        func circle(_ x: Double, _ y: Double, _ r: Double) -> Path {
            Path(ellipseIn: CGGeometryBridge.rect(from: box(x - r, y - r, 2 * r, 2 * r)))
        }
        var path = Path(CGGeometryBridge.darumaOutline(in: box(0, 0, 100, 100)))
        path.addPath(Path(ellipseIn: CGGeometryBridge.rect(from: box(21, 25, 58, 44))))
        let eye = templateEye(pose)
        path.addPath(circle(eye.x, eye.y, 11.3))
        if pose.recordFill < 1 { path.addPath(circle(eye.x, eye.y, 6.7 * (1 - pose.recordFill))) }
        if pose.waitingPainted { path.addPath(circle(38, eye.y, 9)) }
        return path
    }

    private var colour: some View {
        Canvas { context, size in
            let unit = min(Double(size.width), Double(size.height)) / 100
            let left = (Double(size.width) - 100 * unit) / 2, top = (Double(size.height) - 100 * unit) / 2
            /// A rectangle in the mark's 100-unit box, on this canvas.
            func box(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> PointRect {
                PointRect(x: left + x * unit, y: top + y * unit, width: width * unit, height: height * unit)
            }
            func circle(_ x: Double, _ y: Double, _ r: Double) -> Path {
                Path(ellipseIn: CGGeometryBridge.rect(from: box(x - r, y - r, 2 * r, 2 * r)))
            }
            let outline = Path(CGGeometryBridge.darumaOutline(in: box(0, 0, 100, 100)))
            // The eyes glance together, three units at most — inside the face at any glance.
            let shift = pose.look * 3, drop = pose.attending * 2
            let dark = scheme == .dark
            let ink = dark ? Palette.Brand.paper : Palette.Brand.sumi
            let body = icon == .vermilion ? Palette.Brand.shuNuri : ink
            let face = dark ? Palette.Brand.sumi : Palette.RGB(hex: 0xFFFFFF)
            context.fill(outline, with: .color(body.color))
            context.fill(Path(ellipseIn: CGGeometryBridge.rect(from: box(25, 26.5, 50, 39))),
                         with: .color(face.color))
            let red = Color(Signal.record)
            if rimmed {
                context.stroke(outline, with: .color(Palette.Brand.washi.color), lineWidth: 1.6 * unit)
            }
            // **Counting, the eye's own ring is the timer**: a faint track, and in full red what
            // is left of this second. A second ring round the eye, the menu bar's arrangement,
            // read as a target at this size and crowded the face's edge (seen 2026-10-25).
            if let ring = pose.countRing {
                context.stroke(circle(60 + shift, 46 + drop, 7.5), with: .color(red.opacity(0.3)),
                               lineWidth: 3.4 * unit)
                let arc = CGGeometryBridge.countdownArc(centreX: left + (60 + shift) * unit,
                                                        centreY: top + (46 + drop) * unit,
                                                        radius: 7.5 * unit, remaining: ring)
                context.stroke(Path(arc), with: .color(red),
                               style: StrokeStyle(lineWidth: 3.4 * unit, lineCap: .round))
            } else {
                context.stroke(circle(60 + shift, 46 + drop, 7.5), with: .color(red), lineWidth: 3.4 * unit)
            }
            if pose.recordFill > 0 {
                context.fill(circle(60 + shift, 46 + drop, 7.5 * pose.recordFill), with: .color(red))
            }
            let waiting = circle(40 + shift, 46 + drop, 7.5)
            if pose.waitingPainted {
                context.fill(waiting, with: .color(ink.color))
            } else {
                let dash = 2 * Double.pi * 7.5 * unit / 20
                context.stroke(waiting, with: .color(ink.color),
                               style: StrokeStyle(lineWidth: 2.6 * unit, dash: [dash, dash]))
            }
        }
    }
}
