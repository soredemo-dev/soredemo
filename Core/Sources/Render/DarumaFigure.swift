import Foundation
import Geometry

/// What the daruma character's face is doing: where it looks, how open its eyes are, each eye's
/// expression, and the countdown's ring. Numbers only — the app's reasons for each pose live
/// beside the app's states (`DarumaPose` there).
public struct DarumaFace: Equatable, Sendable {
    /// One eye's expression. `record` is the right eye lit in the record red — the painted eye.
    public enum Eye: Equatable, Sendable { case open, closed, happy, sad, record }

    /// −1 … 1: where it looks, left to right.
    public var yaw: Double
    /// −1 … 1: where it looks, up to down.
    public var pitch: Double
    /// The eyes' height against an ordinary open eye: wide when curious, low when drowsy.
    public var openness: Double
    public var left: Eye
    public var right: Eye
    /// 0 … 1: the countdown's ring round the right eye, what is left of this second. `nil` when
    /// nothing is being counted — no ring at all, not an empty one.
    public var countRing: Double?
    /// The daruma's face window, or the eyes straight on the body — the person's choice.
    public var faceWindow: Bool

    public init(yaw: Double = 0, pitch: Double = 0, openness: Double = 1,
                left: Eye = .open, right: Eye = .open, countRing: Double? = nil, faceWindow: Bool = true) {
        self.faceWindow = faceWindow
        self.yaw = yaw
        self.pitch = pitch
        self.openness = openness
        self.left = left
        self.right = right
        self.countRing = countRing
    }

    public static let resting = DarumaFace()
}

/// The geometry one face draws, in the character's 100-unit box, y down. **Pure**, so what the
/// character looks like at any gaze is a test rather than an impression.
///
/// **The face turns on the body's sphere, and the eyes on the face's.** Looking aside moves the
/// face window toward that side, narrows it and tips it along the curve; the eyes do the same
/// inside it, the far one narrowing more. That is what makes a flat shape read as a head that
/// turns — the owner's Grok reference does it, and asked for the face window to do it too.
/// `docs/design/2026-10-26-a-character-not-a-logo.md`.
public struct DarumaFigure: Equatable, Sendable {
    /// An ellipse turned `tilt` degrees about its centre.
    public struct Oval: Equatable, Sendable {
        public var x: Double, y: Double, rx: Double, ry: Double, tilt: Double

        public func point(at t: Double) -> (x: Double, y: Double) {
            let a = tilt * .pi / 180, px = rx * cos(t), py = ry * sin(t)
            return (x + px * cos(a) - py * sin(a), y + px * sin(a) + py * cos(a))
        }

        /// Inside, with `margin` units to spare.
        public func contains(x px: Double, y py: Double, margin: Double = 0) -> Bool {
            let a = -tilt * .pi / 180, dx = px - x, dy = py - y
            let u = dx * cos(a) - dy * sin(a), v = dx * sin(a) + dy * cos(a)
            return pow(u / max(rx - margin, 0.001), 2) + pow(v / max(ry - margin, 0.001), 2) <= 1
        }
    }

    /// One eye: a pill (open, sad, record) or a line (closed, happy), turned `tilt` degrees.
    public struct EyeMark: Equatable, Sendable {
        public var x: Double, y: Double, width: Double, height: Double, tilt: Double
        public var kind: DarumaFace.Eye

        /// Points round the pill's outline — its two end caps — for checking it sits in the face.
        public func outline() -> [(x: Double, y: Double)] {
            let r = min(width, height) / 2, a = tilt * .pi / 180
            let reach = max(height, width) / 2 - r, upright = height >= width
            return [-1.0, 1].flatMap { end in
                stride(from: 0.0, to: 2 * .pi, by: .pi / 8).map { t in
                    let cx = upright ? 0 : end * reach, cy = upright ? end * reach : 0
                    let px = cx + r * cos(t), py = cy + r * sin(t)
                    return (x + px * cos(a) - py * sin(a), y + px * sin(a) + py * cos(a))
                }
            }
        }
    }

    public var bodyWidth: Double, bodyHeight: Double, crown: Double
    public var face: Oval
    /// Left, then right.
    public var eyes: [EyeMark]

    /// Whether a point is on the body, with `margin` units to spare on every side.
    public func bodyContains(x: Double, y: Double, margin: Double = 0) -> Bool {
        [(0.0, 0.0), (margin, 0), (-margin, 0), (0, margin), (0, -margin)].allSatisfy { d in
            DarumaBodyCurve.contains(x: x + d.0, y: y + d.1, width: bodyWidth, height: bodyHeight, crown: crown)
        }
    }

    /// `blink` is 1 open … 0 shut; `breath` a small swell of the body, ±0.015.
    public static func make(_ pose: DarumaFace, blink: Double = 1, breath: Double = 0) -> DarumaFigure {
        let w = 1 - breath, h = 1 + breath, crown = 1.15
        let yaw = max(-1, min(1, pose.yaw)), pitch = max(-1, min(1, pose.pitch))
        // The face on the body's sphere.
        // Up is shorter than down: the crown narrows, and a face looking up and aside as far as it
        // looks down would leave the body (`atEveryGazeTheFaceStaysOnTheBodyAndTheEyesInTheFace`).
        let faceYaw = yaw * 0.55, facePitch = pitch * (pitch < 0 ? 0.24 : 0.42)
        let top = 93 - 82 * h, restY = top + 82 * h * 0.47
        let face = Oval(x: 50 + 39 * w * 0.6 * sin(faceYaw),
                        y: restY + 41 * h * 0.5 * sin(facePitch),
                        rx: 27 * w * cos(faceYaw), ry: 21 * h * cos(facePitch),
                        tilt: sin(faceYaw) * sin(facePitch) * 22)
        // The eyes on the face's.
        let eyes = [(pose.left, -1.0), (pose.right, 1.0)].map { eye, side -> EyeMark in
            // **Apart, not touching**: the gap between the eyes about one and a half eye-widths,
            // as the owner's reference sets them — the first set, 0.28, left them nearly touching
            // and the lit record eye over its neighbour (seen on the brand sheet, 2026-10-26).
            let ax = side * 0.55 + yaw * 0.5, ay = pitch * 0.4
            let spread = pose.faceWindow ? 0.66 : 0.8
            let x = face.x + face.rx * spread * sin(ax), y = face.y + 1 + face.ry * 0.45 * sin(ay)
            // Without a window the eyes are the face — about a quarter of the body's height, as the
            // reference's are — and set wider apart to keep the same gap.
            let size = pose.faceWindow ? 1.0 : 1.55
            var width = 7.4 * size * w * max(0.4, cos(ax))
            var height = 13 * size * h * pose.openness * max(0.6, cos(ay))
            var tilt = face.tilt + sin(ax) * sin(ay) * 18
            switch eye {
            case .open: height *= max(blink, 0.08)
            case .sad: height *= 0.75; tilt += side * -14
            case .record: height = width * 1.5
            // A line eye's width is its arc's whole span, a little wider than a pill so it reads —
            // and no wider, or a smile's two arcs meet in the middle (seen 2026-10-26).
            case .closed, .happy: height = 3.4 * size; width *= 1.2
            }
            return EyeMark(x: x, y: y, width: width, height: max(height, 1.2), tilt: tilt, kind: eye)
        }
        return DarumaFigure(bodyWidth: w, bodyHeight: h, crown: crown, face: face, eyes: eyes)
    }
}
