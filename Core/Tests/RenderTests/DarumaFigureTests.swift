import Testing
import Geometry
@testable import Render

// The daruma character's figure: the geometry one face draws. Pure, so what it looks like at any
// gaze is a test. `docs/design/2026-10-26-a-character-not-a-logo.md`.

private let gazes: [(Double, Double)] = [(-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 0), (0, 1),
                                         (1, -1), (1, 0), (1, 1), (0.4, -0.7)]

/// Resting, the face is centred and the eyes mirror each other.
@Test func atRestTheFaceIsCentredAndTheEyesMirror() {
    let f = DarumaFigure.make(.resting)
    #expect(abs(f.face.x - 50) < 0.001 && abs(f.face.tilt) < 0.001)
    #expect(abs((f.eyes[0].x + f.eyes[1].x) / 2 - 50) < 0.001)
    #expect(abs(f.eyes[0].width - f.eyes[1].width) < 0.001 && f.eyes[0].y == f.eyes[1].y)
}

/// **The face turns with the gaze, not only the eyes** (the owner, 2026-10-26: the face window
/// moves on the sphere too). Looking right moves the face right and narrows it; the eye on the
/// side it turns toward narrows more than the other; looking down moves it down and shortens it.
@Test func lookingAsideTurnsTheWholeFace() {
    let rest = DarumaFigure.make(.resting)
    let right = DarumaFigure.make(DarumaFace(yaw: 1))
    #expect(right.face.x > rest.face.x + 5, "the face travels: \(right.face.x)")
    #expect(right.face.rx < rest.face.rx, "and narrows")
    #expect(right.eyes[1].width < right.eyes[0].width, "the far eye narrows more")
    #expect(right.eyes.allSatisfy { $0.x > 50 })
    let left = DarumaFigure.make(DarumaFace(yaw: -1))
    #expect(left.face.x < rest.face.x - 5 && left.eyes[0].width < left.eyes[1].width)
    let down = DarumaFigure.make(DarumaFace(pitch: 1))
    #expect(down.face.y > rest.face.y + 3 && down.face.ry < rest.face.ry)
}

/// At every gaze, eyes wide, the face stays on the body and the eyes in the face — sampled round
/// each outline, not tested at a centre.
@Test func atEveryGazeTheFaceStaysOnTheBodyAndTheEyesInTheFace() {
    for (yaw, pitch) in gazes {
        let f = DarumaFigure.make(DarumaFace(yaw: yaw, pitch: pitch, openness: 1.18))
        let off = stride(from: 0.0, to: 2 * .pi, by: .pi / 24).filter { t in
            let (x, y) = f.face.point(at: t)
            return !f.bodyContains(x: x, y: y, margin: 1.5)
        }
        #expect(off.isEmpty, "the face leaves the body at gaze \(yaw), \(pitch)")
        for (i, eye) in f.eyes.enumerated() {
            let out = eye.outline().filter { !f.face.contains(x: $0.x, y: $0.y, margin: 1) }
            #expect(out.isEmpty, "eye \(i) leaves the face at gaze \(yaw), \(pitch): \(eye)")
        }
        // Without a window the larger eyes are on the body, and still clear of its edge.
        let bare = DarumaFigure.make(DarumaFace(yaw: yaw, pitch: pitch, openness: 1.18, faceWindow: false))
        for (i, eye) in bare.eyes.enumerated() {
            let off = eye.outline().filter { !bare.bodyContains(x: $0.x, y: $0.y, margin: 3) }
            #expect(off.isEmpty, "a bare eye \(i) leaves the body at gaze \(yaw), \(pitch)")
        }
    }
}

/// A blink flattens the open eyes; a closed eye is a line.
@Test func aBlinkFlattensTheEyesAndAClosedEyeIsALine() {
    let open = DarumaFigure.make(.resting)
    let blinking = DarumaFigure.make(.resting, blink: 0.1)
    #expect(blinking.eyes[0].height < open.eyes[0].height * 0.2)
    let asleep = DarumaFigure.make(DarumaFace(left: .closed, right: .closed))
    #expect(asleep.eyes.allSatisfy { $0.kind == .closed && $0.height < 4 })
}

/// The body's own curve answers inside and outside: its middle, and the box's corners.
@Test func theBodyCurveKnowsItsInside() {
    #expect(DarumaBodyCurve.contains(x: 50, y: 55, width: 1, height: 1, crown: 1.15))
    #expect(!DarumaBodyCurve.contains(x: 13, y: 14, width: 1, height: 1, crown: 1.15), "the top-left corner")
    #expect(!DarumaBodyCurve.contains(x: 50, y: 96, width: 1, height: 1, crown: 1.15), "below the base")
    #expect(DarumaBodyCurve.contains(x: 85, y: 56, width: 1, height: 1, crown: 1.15), "near the widest point")
}

/// **The eyes are apart** (the owner, 2026-10-26: "are the eyes too close?" — they were nearly
/// touching). At rest the gap between them is at least one eye-width and the lit record eye does
/// not reach its neighbour.
@Test func theEyesStandApart() {
    let rest = DarumaFigure.make(.resting)
    let gap = (rest.eyes[1].x - rest.eyes[1].width / 2) - (rest.eyes[0].x + rest.eyes[0].width / 2)
    #expect(gap >= rest.eyes[0].width, "gap \(gap) against an eye \(rest.eyes[0].width) wide")
    // A smile's two arcs do not join (the owner, 2026-10-26: they ran together).
    let smile = DarumaFigure.make(DarumaFace(left: .happy, right: .happy))
    let between = (smile.eyes[1].x - smile.eyes[1].width / 2) - (smile.eyes[0].x + smile.eyes[0].width / 2)
    #expect(between >= smile.eyes[0].width * 0.6, "the smile's arcs are \(between) apart")
    let bare = DarumaFigure.make(DarumaFace(faceWindow: false))
    #expect(bare.eyes[0].width > rest.eyes[0].width * 1.2, "the eyes are the face without a window")
    let bareGap = (bare.eyes[1].x - bare.eyes[1].width / 2) - (bare.eyes[0].x + bare.eyes[0].width / 2)
    #expect(bareGap >= bare.eyes[0].width, "bare eyes stand apart too: \(bareGap)")
    let lit = DarumaFigure.make(DarumaFace(right: .record))
    let disc = lit.eyes[1].width * 0.8
    #expect(lit.eyes[1].x - disc > lit.eyes[0].x + lit.eyes[0].width / 2 + 2, "the record eye reaches the other")
}

/// Paused, both eyes are the pause symbol: two upright bars, taller than an open eye, that stay
/// upright and do not blink wherever it looks — and stay in the face and on the body.
@Test func pausedTheEyesAreTwoUprightBars() {
    let open = DarumaFigure.make(.resting).eyes[0]
    for (yaw, pitch) in gazes {
        for window in [true, false] {
            let f = DarumaFigure.make(DarumaFace(yaw: yaw, pitch: pitch, left: .pause, right: .pause, faceWindow: window), blink: 0.1)
            for eye in f.eyes {
                #expect(eye.tilt == 0, "a bar tips at gaze \(yaw), \(pitch)")
                let off = eye.outline().filter { window ? !f.face.contains(x: $0.x, y: $0.y, margin: 1) : !f.bodyContains(x: $0.x, y: $0.y, margin: 3) }
                #expect(off.isEmpty, "a bar leaves the \(window ? "face" : "body") at gaze \(yaw), \(pitch)")
            }
        }
    }
    let bar = DarumaFigure.make(DarumaFace(left: .pause, right: .pause), blink: 0.1).eyes[0]
    #expect(bar.height > open.height && bar.width > open.width, "taller and wider than an open eye, and unblinking")
}
