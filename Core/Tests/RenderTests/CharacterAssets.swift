import Foundation
import Testing
import Geometry
@testable import Render

// **The brand kit's daruma, drawn from the app's own figure.** Not a check: it runs only when
// `SOREDEMO_MAKE_CHARACTER_ASSETS` names a directory (`scripts/make-character-assets.sh` sets it)
// and otherwise passes having done nothing. Writing the kit from `DarumaFigure` means the
// website's mark and the app's cannot drift: there is one geometry. The PNGs are rasterised from
// these SVGs by the script. `docs/design/2026-10-26-a-character-not-a-logo.md`.

private let sumi = "#16171B", washi = "#F4F3EF", shu = "#FA3D4A", shuNuri = "#E8452C", kin = "#C8A24A"

/// A body colour, and the face and eye colours that go with it — `eye` in a window, `bareEye` on
/// the body: the app's `DarumaColour.tones`, each colour designed for both faces.
private struct Tone { let name: String, body: String, face: String, eye: String, bareEye: String }
private let vermilion = Tone(name: "shu", body: shuNuri, face: "#FFFFFF", eye: sumi, bareEye: sumi)
private let ink = Tone(name: "ink", body: "#1F2025", face: "#FFFFFF", eye: sumi, bareEye: "#F7F6F2")
private let paper = Tone(name: "paper", body: washi, face: "#1B1C21", eye: "#F7F6F2", bareEye: sumi)
private let gold = Tone(name: "gold", body: kin, face: "#FFFFFF", eye: sumi, bareEye: sumi)

private func n(_ v: Double) -> String { ((v * 1000).rounded() / 1000).formatted(.number.precision(.fractionLength(0...3)).grouping(.never).locale(Locale(identifier: "en_US_POSIX"))) }

private func bodyPath(_ f: DarumaFigure) -> String {
    let (start, segments) = DarumaBodyCurve.outline(width: f.bodyWidth, height: f.bodyHeight, crown: f.crown)
    var d = "M\(n(start.x)) \(n(start.y))"
    for s in segments {
        d += "C\(n(s.control1.x)) \(n(s.control1.y)) \(n(s.control2.x)) \(n(s.control2.y)) \(n(s.end.x)) \(n(s.end.y))"
    }
    return d + "Z"
}

/// One eye as SVG: a pill, a red disc, or a stroked arc.
private func eyeSVG(_ e: DarumaFigure.EyeMark, ink: String, red: String) -> String {
    switch e.kind {
    case .open, .sad:
        let r = min(e.width, e.height) / 2
        return "<rect x=\"\(n(e.x - e.width / 2))\" y=\"\(n(e.y - e.height / 2))\" width=\"\(n(e.width))\" height=\"\(n(e.height))\" rx=\"\(n(r))\" fill=\"\(ink)\" transform=\"rotate(\(n(e.tilt)) \(n(e.x)) \(n(e.y)))\"/>"
    case .pause:
        return "<rect x=\"\(n(e.x - e.width / 2))\" y=\"\(n(e.y - e.height / 2))\" width=\"\(n(e.width))\" height=\"\(n(e.height))\" rx=\"\(n(e.width * 0.3))\" fill=\"\(ink)\"/>"
    case .record:
        return "<circle cx=\"\(n(e.x))\" cy=\"\(n(e.y))\" r=\"\(n(e.width * 0.8))\" fill=\"\(red)\"/>"

    case .closed:
        return "<path d=\"M\(n(e.x - e.width / 2)) \(n(e.y - 0.5))Q\(n(e.x)) \(n(e.y + 3)) \(n(e.x + e.width / 2)) \(n(e.y - 0.5))\" fill=\"none\" stroke=\"\(ink)\" stroke-width=\"2.6\" stroke-linecap=\"round\"/>"
    case .happy:
        return "<path d=\"M\(n(e.x - e.width / 2)) \(n(e.y + 2))Q\(n(e.x)) \(n(e.y - 5)) \(n(e.x + e.width / 2)) \(n(e.y + 2))\" fill=\"none\" stroke=\"\(ink)\" stroke-width=\"3\" stroke-linecap=\"round\"/>"
    }
}

/// The character in its 100-unit box, as an SVG group.
/// `bodyFill` and `faceFill` replace the flat colours — the app icon's shading, by gradient id.
private func characterGroup(_ face: DarumaFace, _ tone: Tone, shine: Bool = true,
                            bodyFill: String? = nil, faceFill: String? = nil) -> String {
    let f = DarumaFigure.make(face)
    var g = "<path d=\"\(bodyPath(f))\" fill=\"\(bodyFill ?? tone.body)\"/>"
    if shine { g += "<ellipse cx=\"40\" cy=\"22\" rx=\"11\" ry=\"5\" fill=\"#FFFFFF\" opacity=\"0.18\" transform=\"rotate(-12 40 22)\"/>" }
    if face.faceWindow {
        g += "<ellipse cx=\"\(n(f.face.x))\" cy=\"\(n(f.face.y))\" rx=\"\(n(f.face.rx))\" ry=\"\(n(f.face.ry))\" fill=\"\(faceFill ?? tone.face)\" transform=\"rotate(\(n(f.face.tilt)) \(n(f.face.x)) \(n(f.face.y)))\"/>"
    }
    for eye in f.eyes {
        // On the body the record eye has a washi ring, or red on vermilion is lost — as the app.
        if eye.kind == .record, !face.faceWindow {
            g += "<circle cx=\"\(n(eye.x))\" cy=\"\(n(eye.y))\" r=\"\(n(eye.width * 0.8 * 1.3))\" fill=\"\(washi)\"/>"
        }
        g += eyeSVG(eye, ink: face.faceWindow ? tone.eye : tone.bareEye, red: shu)
    }
    return g
}

/// One colour, the face cut out: the menu bar's template and the one-colour marks.
private func oneColourGroup(_ face: DarumaFace, _ colour: String) -> String {
    let f = DarumaFigure.make(face)
    let fx = f.face
    // The face as a hole: an ellipse subpath under even-odd, turned by hand into the path's own
    // coordinates — an SVG transform cannot apply to one subpath.
    var hole = ""
    for step in 0...72 {
        let (x, y) = fx.point(at: Double(step) / 72 * 2 * .pi)
        hole += (step == 0 ? "M" : "L") + "\(n(x)) \(n(y))"
    }
    var g = "<path d=\"\(bodyPath(f))\(hole)Z\" fill=\"\(colour)\" fill-rule=\"evenodd\"/>"
    for eye in f.eyes { g += eyeSVG(eye, ink: colour, red: colour) }
    return g
}

private func svg(_ size: Int, _ content: String, viewBox: String = "0 0 100 100", background: String? = nil) -> String {
    let bg = background.map { "<rect x=\"-1000\" y=\"-1000\" width=\"3000\" height=\"3000\" fill=\"\($0)\"/>" } ?? ""
    return "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(size)\" height=\"\(size)\" viewBox=\"\(viewBox)\">\(bg)\(content)</svg>\n"
}

/// The app icon's shading per body colour — lit from the upper left, as Grok Bot's — light, body,
/// shadow; and the ground, the dark corner the body does not cover.
private let iconShade = ["shu": ("#FF7A5C", "#E8452C", "#9E2412"), "ink": ("#5A5B63", "#24252B", "#08080A")]
private let iconGround = ["shu": "#17181C", "ink": "#ECE9E2"]

/// A 1024 icon after the owner's reference, Grok Bot's: the body too big for the tile, coming in
/// from the lower left and cut by its edge, turned toward the upper right where it looks; shaded
/// as a ball; the ground only in the corner it leaves. `tile` clips to Apple's macOS tile (824
/// square, radius 185, centred) for the fallback set and the Dock; otherwise the canvas bleeds
/// for Icon Composer, which masks it. `place` is the character's centre, turn and scale.
private func appIcon(_ face: DarumaFace, _ tone: Tone, tile: Bool,
                     place: (x: Double, y: Double, turn: Double, scale: Double) = iconPlacement) -> String {
    let shade = iconShade[tone.name] ?? (tone.body, tone.body, tone.body)
    let ground = iconGround[tone.name] ?? sumi
    let defs = "<defs><clipPath id=\"c\"><rect x=\"100\" y=\"100\" width=\"824\" height=\"824\" rx=\"185\"/></clipPath>"
        + "<radialGradient id=\"b\" cx=\"0.34\" cy=\"0.26\" r=\"0.85\"><stop offset=\"0\" stop-color=\"\(shade.0)\"/><stop offset=\"0.5\" stop-color=\"\(shade.1)\"/><stop offset=\"1\" stop-color=\"\(shade.2)\"/></radialGradient>"
        + "<radialGradient id=\"f\" cx=\"0.35\" cy=\"0.25\" r=\"0.9\"><stop offset=\"0\" stop-color=\"#FFFFFF\"/><stop offset=\"1\" stop-color=\"#DCD8CF\"/></radialGradient>"
        + "<filter id=\"r\" x=\"-20%\" y=\"-20%\" width=\"140%\" height=\"140%\"><feGaussianBlur stdDeviation=\"0.9\"/></filter></defs>"
    let f = DarumaFigure.make(face)
    // The rim: the body's edge lit faintly, as a ball against a dark ground.
    let rim = "<path d=\"\(bodyPath(f))\" fill=\"none\" stroke=\"#FFFFFF\" stroke-opacity=\"0.28\" stroke-width=\"1.4\" filter=\"url(#r)\"/>"
    let character = characterGroup(face, tone, shine: false, bodyFill: "url(#b)", faceFill: "url(#f)") + rim
    let turned = "<g transform=\"translate(\(n(place.x)) \(n(place.y))) rotate(\(n(place.turn))) scale(\(n(place.scale))) translate(-50 -52)\">\(character)</g>"
    let content = tile
        ? "<g clip-path=\"url(#c)\"><rect x=\"100\" y=\"100\" width=\"824\" height=\"824\" fill=\"\(ground)\"/>\(turned)</g>"
        : "<rect width=\"1024\" height=\"1024\" fill=\"\(ground)\"/>\(turned)"
    return svg(1024, defs + content, viewBox: "0 0 1024 1024")
}
private let iconPlacement = (x: 440.0, y: 760.0, turn: 28.0, scale: 11.5)
/// The same in Icon Composer's canvas, whose whole 1024 the system masks: the tile's 824 scaled up.
private let bleed = 1024.0 / 824
private let iconPlace = "translate(\(n((iconPlacement.x - 100) * bleed)) \(n((iconPlacement.y - 100) * bleed))) rotate(\(n(iconPlacement.turn))) scale(\(n(iconPlacement.scale * bleed))) translate(-50 -52)"
/// The icon's face: looking up and to the right, out of the tile.
private let iconFace = DarumaFace(yaw: 0.3, pitch: -0.6, right: .record)

private let looking = DarumaFace(yaw: 0.45, pitch: 0.2)
private let recording = DarumaFace(right: .record)

@Test func makeCharacterAssets() throws {
    guard let directory = ProcessInfo.processInfo.environment["SOREDEMO_MAKE_CHARACTER_ASSETS"] else { return }
    let out = URL(fileURLWithPath: directory)
    func write(_ name: String, _ text: String) throws {
        let url = out.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    // The character — vermilion by default (the owner, 2026-10-26) — the record eye lit, as the
    // mark has always shown it; every colour with a face window and with its eyes on the body.
    try write("svg/soredemo-character.svg", svg(100, characterGroup(recording, vermilion)))
    for tone in [vermilion, ink, paper, gold] {
        try write("svg/colours/soredemo-character-\(tone.name).svg", svg(100, characterGroup(recording, tone)))
        try write("svg/colours/soredemo-character-\(tone.name)-bare.svg",
                  svg(100, characterGroup(DarumaFace(right: .record, faceWindow: false), tone)))
    }
    try write("svg/soredemo-character-black.svg", svg(100, oneColourGroup(.resting, sumi)))
    try write("svg/soredemo-character-white.svg", svg(100, oneColourGroup(.resting, "#FFFFFF")))
    // Expressions, in the default colour.
    let faces: [(String, DarumaFace)] = [("resting", .resting), ("looking", looking), ("recording", recording),
                                         ("paused", DarumaFace(left: .pause, right: .pause)), ("done", DarumaFace(left: .happy, right: .happy)),
                                         ("asleep", DarumaFace(left: .closed, right: .closed)), ("sad", DarumaFace(left: .sad, right: .sad))]
    for (name, face) in faces {
        try write("svg/expressions/soredemo-character-\(name).svg", svg(100, characterGroup(face, vermilion)))
    }
    // The app icons, after the owner's reference (Grok Bot's): the character flat and large,
    // nearly filling the tile, on one deep ground. The face window is the bundle's icon; the eyes
    // on the body and the ink daruma are the alternatives a person can choose (AppIconChoice).
    // On the macOS tile, for the fallback set, the Dock and Settings' thumbnails; Icon
    // Composer's layers below are the bundle's icon on macOS 26.
    // Every icon keeps the record eye — the owner: the eye is the recording. On the body it has
    // the app's washi ring, or red is lost on vermilion.
    let bare = DarumaFace(yaw: iconFace.yaw, pitch: iconFace.pitch, right: .record, faceWindow: false)
    for (suffix, face, tone) in [("", iconFace, vermilion), ("-bare", bare, vermilion), ("-ink", iconFace, ink)] {
        try write("svg/soredemo-app-icon\(suffix).svg", appIcon(face, tone, tile: true))
    }
    // The app icon's layers for Icon Composer: the body with its window, and the eyes — two
    // groups so the system can give the eyes their own depth. The tile's placement, on the bleed.
    let place = iconPlace
    let figure = DarumaFigure.make(iconFace)
    var bodyLayer = "<path d=\"\(bodyPath(figure))\" fill=\"\(shuNuri)\"/>"
    bodyLayer += "<ellipse cx=\"\(n(figure.face.x))\" cy=\"\(n(figure.face.y))\" rx=\"\(n(figure.face.rx))\" ry=\"\(n(figure.face.ry))\" fill=\"#FFFFFF\" transform=\"rotate(\(n(figure.face.tilt)) \(n(figure.face.x)) \(n(figure.face.y)))\"/>"
    try write("icon/body.svg", svg(1024, "<g transform=\"\(place)\">\(bodyLayer)</g>", viewBox: "0 0 1024 1024"))
    let eyesLayer = figure.eyes.map { eyeSVG($0, ink: sumi, red: shu) }.joined()
    try write("icon/eyes.svg", svg(1024, "<g transform=\"\(place)\">\(eyesLayer)</g>", viewBox: "0 0 1024 1024"))
    // The menu bar's template: one colour, the body 88% of an 18-point canvas, as `DarumaMark`.
    let unit = 18 * 0.88 / 82
    let menubar = "<g transform=\"translate(9 9) scale(\(n(unit))) translate(-50 -52)\">\(oneColourGroup(.resting, "#000000"))</g>"
    try write("svg/soredemo-menubar-template.svg", svg(18, menubar, viewBox: "0 0 18 18"))
    // The favicon: vermilion reads on a light tab bar and a dark one alike.
    try write("svg/soredemo-favicon.svg", svg(100, characterGroup(recording, vermilion, shine: false), viewBox: "4 4 92 92"))
}
