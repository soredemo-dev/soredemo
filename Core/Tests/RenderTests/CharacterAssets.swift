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
    case .record:
        return "<circle cx=\"\(n(e.x))\" cy=\"\(n(e.y))\" r=\"\(n(e.width * 0.8))\" fill=\"\(red)\"/>"

    case .closed:
        return "<path d=\"M\(n(e.x - e.width / 2)) \(n(e.y - 0.5))Q\(n(e.x)) \(n(e.y + 3)) \(n(e.x + e.width / 2)) \(n(e.y - 0.5))\" fill=\"none\" stroke=\"\(ink)\" stroke-width=\"2.6\" stroke-linecap=\"round\"/>"
    case .happy:
        return "<path d=\"M\(n(e.x - e.width / 2)) \(n(e.y + 2))Q\(n(e.x)) \(n(e.y - 5)) \(n(e.x + e.width / 2)) \(n(e.y + 2))\" fill=\"none\" stroke=\"\(ink)\" stroke-width=\"3\" stroke-linecap=\"round\"/>"
    }
}

/// The character in its 100-unit box, as an SVG group.
private func characterGroup(_ face: DarumaFace, _ tone: Tone, shine: Bool = true) -> String {
    let f = DarumaFigure.make(face)
    var g = "<path d=\"\(bodyPath(f))\" fill=\"\(tone.body)\"/>"
    if shine { g += "<ellipse cx=\"40\" cy=\"22\" rx=\"11\" ry=\"5\" fill=\"#FFFFFF\" opacity=\"0.18\" transform=\"rotate(-12 40 22)\"/>" }
    if face.faceWindow {
        g += "<ellipse cx=\"\(n(f.face.x))\" cy=\"\(n(f.face.y))\" rx=\"\(n(f.face.rx))\" ry=\"\(n(f.face.ry))\" fill=\"\(tone.face)\" transform=\"rotate(\(n(f.face.tilt)) \(n(f.face.x)) \(n(f.face.y)))\"/>"
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

/// Where the character sits in Icon Composer's 1024 canvas, which the system masks: centred on its
/// body (50, 52), its height 75% of the canvas, clear of the mask's corners.
private let iconPlace = "translate(512 522) scale(9.3) translate(-50 -52)"
/// The icon's grounds: a deep sumi lifted toward the top, and washi for the ink daruma.
private let iconGroundDark = ("#2A2B32", "#121317"), iconGroundLight = ("#FBFAF7", "#E9E6DE")

/// A 1024 icon: Apple's macOS tile (824 square, radius 185, centred) on its ground, a soft contact
/// shadow — lighter on a light ground — and the character, its height 78% of the tile.
private func appIcon(_ character: String, ground: (String, String)) -> String {
    let defs = "<defs><linearGradient id=\"g\" x1=\"0\" y1=\"0\" x2=\"0\" y2=\"1\"><stop offset=\"0\" stop-color=\"\(ground.0)\"/><stop offset=\"1\" stop-color=\"\(ground.1)\"/></linearGradient>"
        + "<filter id=\"s\" x=\"-50%\" y=\"-50%\" width=\"200%\" height=\"200%\"><feGaussianBlur stdDeviation=\"1.6\"/></filter>"
        + "<filter id=\"t\" x=\"-10%\" y=\"-10%\" width=\"120%\" height=\"130%\"><feDropShadow dx=\"0\" dy=\"10\" stdDeviation=\"12\" flood-opacity=\"0.3\"/></filter></defs>"
    let back = "<rect x=\"100\" y=\"100\" width=\"824\" height=\"824\" rx=\"185\" fill=\"url(#g)\" filter=\"url(#t)\"/>"
    let place = "translate(512 520) scale(7.8) translate(-50 -52)"
    let depth = ground == iconGroundLight ? "0.16" : "0.35"
    let shadow = "<ellipse cx=\"50\" cy=\"93.5\" rx=\"30\" ry=\"3.2\" fill=\"#000000\" opacity=\"\(depth)\" filter=\"url(#s)\"/>"
    return svg(1024, defs + back + "<g transform=\"\(place)\">\(shadow)\(character)</g>", viewBox: "0 0 1024 1024")
}

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
                                         ("paused", DarumaFace(openness: 0.3)), ("done", DarumaFace(left: .happy, right: .happy)),
                                         ("asleep", DarumaFace(left: .closed, right: .closed)), ("sad", DarumaFace(left: .sad, right: .sad))]
    for (name, face) in faces {
        try write("svg/expressions/soredemo-character-\(name).svg", svg(100, characterGroup(face, vermilion)))
    }
    // The app icons, after the owner's reference (Grok Bot's): the character flat and large,
    // nearly filling the tile, on one deep ground. The face window is the bundle's icon; the eyes
    // on the body and the ink daruma are the alternatives a person can choose (AppIconChoice).
    // On the macOS tile, for the fallback set, the Dock and Settings' thumbnails; Icon
    // Composer's layers below are the bundle's icon on macOS 26.
    let icons: [(String, DarumaFace, Tone)] = [("", recording, vermilion),
                                               ("-bare", DarumaFace(right: .record, faceWindow: false), vermilion),
                                               ("-ink", recording, ink)]
    for (suffix, face, tone) in icons {
        let ground = tone.name == "ink" ? iconGroundLight : iconGroundDark
        try write("svg/soredemo-app-icon\(suffix).svg", appIcon(characterGroup(face, tone), ground: ground))
    }
    // The app icon's layers for Icon Composer: the body with its window, and the eyes — two
    // groups so the system can give the eyes their own depth. Same placement as the square icon.
    let place = iconPlace
    let figure = DarumaFigure.make(recording)
    var bodyLayer = "<path d=\"\(bodyPath(figure))\" fill=\"\(shuNuri)\"/>"
    bodyLayer += "<ellipse cx=\"\(n(figure.face.x))\" cy=\"\(n(figure.face.y))\" rx=\"\(n(figure.face.rx))\" ry=\"\(n(figure.face.ry))\" fill=\"#FFFFFF\"/>"
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
