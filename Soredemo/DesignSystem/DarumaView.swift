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
    @Environment(\.colorScheme) private var scheme

    /// The small mark's record eye, in the 100-unit box. **At rest it is the baked mark's, right
    /// of centre; attending, it travels a row of three looking down** — 40, 52, 64 — because the
    /// large mark's three-unit glance is half a point at the header's 18 and would not be seen.
    static func templateEye(_ pose: DarumaPose) -> (x: Double, y: Double) {
        let a = pose.attending
        return (62 + a * (52 + pose.look * 12 - 62), 47 + a * 4)
    }

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, Double> {
        get { AnimatablePair(AnimatablePair(pose.look, pose.attending), pose.recordFill) }
        set {
            pose.look = newValue.first.first
            pose.attending = newValue.first.second
            pose.recordFill = newValue.second
        }
    }

    var body: some View {
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
            switch style {
            case .colour:
                let dark = scheme == .dark
                let ink = dark ? Palette.Brand.paper : Palette.Brand.sumi
                let body = icon == .vermilion ? Palette.Brand.shuNuri : ink
                let face = dark ? Palette.Brand.sumi : Palette.RGB(hex: 0xFFFFFF)
                context.fill(outline, with: .color(body.color))
                context.fill(Path(ellipseIn: CGGeometryBridge.rect(from: box(25, 26.5, 50, 39))),
                             with: .color(face.color))
                let red = Color(Signal.record)
                context.stroke(circle(60 + shift, 46 + drop, 7.5), with: .color(red), lineWidth: 3.4 * unit)
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
            case .template:
                // The small mark's numbers: a larger face and eye, legible at a header's size.
                let ink = GraphicsContext.Shading.style(.foreground)
                context.drawLayer { layer in
                    layer.fill(outline, with: ink)
                    layer.blendMode = .destinationOut
                    layer.fill(Path(ellipseIn: CGGeometryBridge.rect(from: box(21, 25, 58, 44))),
                               with: .color(.black))
                }
                // **The ring's hole closes as it fills — one path, never a disc over a ring.** The
                // foreground ink is translucent: a disc over its ring darkened the overlap, and a
                // union of the two cancelled to a white seam between them.
                let eye = Self.templateEye(pose)
                var marks = circle(eye.x, eye.y, 11.3)
                if pose.recordFill < 1 { marks.addPath(circle(eye.x, eye.y, 6.7 * (1 - pose.recordFill))) }
                if pose.waitingPainted { marks.addPath(circle(38, eye.y, 9)) }
                context.fill(marks, with: ink, style: FillStyle(eoFill: true))
            }
        }
        .accessibilityHidden(true)
    }
}
