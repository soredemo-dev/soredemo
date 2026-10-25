import AppKit
import SwiftUI

// Builds every bitmap of the mark — a daruma — from the geometry the website draws
// (`soredemo-web/src/components/Daruma.tsx`), so the app and the site cannot drift:
//
//   swift scripts/make-daruma-marks.swift Soredemo/Resources
//
// writes the menu bar's images (idle, paused and finished as templates; the recording and
// countdown states' red layers, drawn over a tinted body by `MenuBarMark`), the coloured mark the
// permissions window shows, the app icon's bitmap sizes, and the Icon Composer file's layers. Every path is in the SVG's own units (a 100 × 100 box, y down);
// the context is flipped and scaled once, so the numbers below are the site's numbers.
//
// The menu bar's mark is cut smaller in body and larger in face and eye, as type is cut for
// small sizes, and has no waiting eye: a dashed ring at 15 points is noise. SwiftUI scales a
// menu bar image to the bar's height whatever frame it is given, so the mark's apparent size is
// the share of the canvas its ink fills — 88% of the height, 15.8pt beside the system's own
// symbols' 12 to 13pt (`MenuBarRecorderLabel` has the measurement).

let resources = URL(fileURLWithPath: CommandLine.arguments[1])
let catalog = resources.appending(path: "Assets.xcassets")

// MARK: - colours

let sumi = CGColor(srgbRed: 0x16 / 255, green: 0x17 / 255, blue: 0x1b / 255, alpha: 1)
let washi = CGColor(srgbRed: 0xf4 / 255, green: 0xf3 / 255, blue: 0xef / 255, alpha: 1)
let record = CGColor(srgbRed: 0xfa / 255, green: 0x3d / 255, blue: 0x4a / 255, alpha: 1)
/// The vermilion daruma's body (the brand kit's shu-nuri), for the icon a person can choose.
let shuNuri = CGColor(srgbRed: 0xe8 / 255, green: 0x45 / 255, blue: 0x2c / 255, alpha: 1)
let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
/// The body of the dark-background mark (the brand kit's `soredemo-logomark-dark.svg`).
let paper = CGColor(srgbRed: 0xf4 / 255, green: 0xf4 / 255, blue: 0xf5 / 255, alpha: 1)
let ink = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

// MARK: - geometry, in the SVG's units

let body: CGPath = {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 50, y: 8))
    path.addCurve(to: CGPoint(x: 86, y: 55), control1: CGPoint(x: 73, y: 8), control2: CGPoint(x: 86, y: 30))
    path.addCurve(to: CGPoint(x: 50, y: 92), control1: CGPoint(x: 86, y: 77), control2: CGPoint(x: 71, y: 92))
    path.addCurve(to: CGPoint(x: 14, y: 55), control1: CGPoint(x: 29, y: 92), control2: CGPoint(x: 14, y: 77))
    path.addCurve(to: CGPoint(x: 50, y: 8), control1: CGPoint(x: 14, y: 30), control2: CGPoint(x: 27, y: 8))
    path.closeSubpath()
    return path
}()

struct Face { let cx: Double, cy: Double, rx: Double, ry: Double, eyeX: Double, eyeR: Double, eyeWidth: Double }
let large = Face(cx: 50, cy: 46, rx: 25, ry: 19.5, eyeX: 60, eyeR: 7.5, eyeWidth: 3.4)
let small = Face(cx: 50, cy: 47, rx: 29, ry: 22, eyeX: 62, eyeR: 9, eyeWidth: 4.6)

func ellipse(_ f: Face) -> CGRect { CGRect(x: f.cx - f.rx, y: f.cy - f.ry, width: f.rx * 2, height: f.ry * 2) }

/// A circle drawn as SVG draws one: from three o'clock, in the direction of increasing angle in a
/// y-down space — so a dash pattern starts where the site's does.
func circle(cx: Double, cy: Double, r: Double) -> CGPath {
    let path = CGMutablePath()
    path.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
    path.closeSubpath()
    return path
}

// MARK: - drawing

/// A context over `pixels` × `pixels` whose user space is the SVG's: `viewBox` is the region of
/// SVG units shown, `inkHeight` the share of the canvas the body's height fills (nil: fit the
/// view box), y down.
func render(pixels: Int, viewBox: CGRect, inkHeight: Double? = nil, centreY: Double? = nil,
            _ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    // sRGB in, sRGB out: the colours above are the site's sRGB values, and a context in the
    // display's space would write different numbers into the file.
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let side = Double(pixels)
    let scale: Double
    let originX: Double
    let originY: Double
    if let inkHeight {
        // The body is 84 units tall (8…92): it fills `inkHeight` of the canvas, centred.
        scale = side * inkHeight / 84
        originX = side / 2 - 50 * scale
        originY = side / 2 - 50 * scale
    } else {
        scale = side / max(viewBox.width, viewBox.height)
        originX = (side - viewBox.width * scale) / 2 - viewBox.minX * scale
        originY = (side - viewBox.height * scale) / 2 - viewBox.minY * scale
            + ((centreY ?? 50) - 50) * scale
    }
    // CoreGraphics is y up; flip once so every number below is the SVG's.
    context.translateBy(x: 0, y: side)
    context.scaleBy(x: 1, y: -1)
    context.translateBy(x: originX, y: originY)
    context.scaleBy(x: scale, y: scale)
    draw(context)
    return NSBitmapImageRep(cgImage: context.makeImage()!)
}

enum MenuState { case idle, paused, recordingBody, recordingEye, done, countdownEye }

/// The menu bar's mark: the body solid and the face cut out (even-odd), everything one colour, so
/// macOS can tint it — except the two red layers drawn over a tinted body: `recordingEye`, the
/// filled eye, and `countdownEye`, the eye faint while the count runs. `done` paints the second
/// eye in, where the larger mark's dashed one waits.
func drawMenu(_ state: MenuState, _ c: CGContext) {
    let f = small
    if state != .recordingEye && state != .countdownEye {
        c.addPath(body)
        c.addEllipse(in: ellipse(f))
        c.setFillColor(ink)
        c.fillPath(using: .evenOdd)
    }
    switch state {
    case .idle, .done:
        c.addPath(circle(cx: f.eyeX, cy: f.cy, r: f.eyeR))
        c.setStrokeColor(ink)
        c.setLineWidth(f.eyeWidth)
        c.strokePath()
        if state == .done {
            c.addPath(circle(cx: 100 - f.eyeX, cy: f.cy, r: f.eyeR))
            c.setFillColor(ink)
            c.fillPath()
        }
    case .countdownEye:
        c.addPath(circle(cx: f.eyeX, cy: f.cy, r: f.eyeR))
        c.setStrokeColor(record.copy(alpha: 0.35)!)
        c.setLineWidth(f.eyeWidth)
        c.strokePath()
    case .recordingEye:
        c.addPath(circle(cx: f.eyeX, cy: f.cy, r: f.eyeR + 1))
        c.setFillColor(record)
        c.fillPath()
    case .paused:
        c.setStrokeColor(ink)
        c.setLineWidth(f.eyeWidth + 0.8)
        c.setLineCap(.round)
        for x in [f.eyeX - 3.5, f.eyeX + 3.5] {
            c.move(to: CGPoint(x: x, y: f.cy - f.eyeR + 1))
            c.addLine(to: CGPoint(x: x, y: f.cy + f.eyeR - 1))
        }
        c.strokePath()
    case .recordingBody:
        break
    }
}

/// The large mark: sumi body, white face, the record eye on the viewer's right as a red ring, the
/// waiting eye on the left as a dashed ring — ten dashes, as `pathLength="20"` with a `1 1` dash.
/// On a dark background the body and face trade places, as the brand kit's dark logomark does.
func drawLarge(_ c: CGContext, dark: Bool = false, body bodyOverride: CGColor? = nil,
               parts: Set<String> = ["body", "eyes"]) {
    let f = large
    let bodyColour = bodyOverride ?? (dark ? paper : sumi)
    if parts.contains("body") {
        c.addPath(body)
        c.setFillColor(bodyColour)
        c.fillPath()
        c.addEllipse(in: ellipse(f))
        c.setFillColor(dark ? sumi : white)
        c.fillPath()
    }
    if parts.contains("eyes") {
        c.addPath(circle(cx: f.eyeX, cy: f.cy, r: f.eyeR))
        c.setStrokeColor(record)
        c.setLineWidth(f.eyeWidth)
        c.strokePath()
        let dash = 2 * .pi * 7.5 / 20
        c.addPath(circle(cx: 40, cy: f.cy, r: 7.5))
        // The waiting eye is ink — sumi, or paper on the dark mark — whatever the body is painted.
        c.setStrokeColor(dark ? paper : sumi)
        c.setLineWidth(2.6)
        c.setLineDash(phase: 0, lengths: [dash, dash])
        c.strokePath()
        c.setLineDash(phase: 0, lengths: [])
    }
}

// MARK: - writing

func write(_ rep: NSBitmapImageRep, to url: URL) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.path(percentEncoded: false).replacingOccurrences(of: resources.path(percentEncoded: false), with: ""))")
}

func imageset(_ name: String, template: Bool, images: [(file: String, scale: String, dark: Bool)]) -> String {
    let entries = images.map { image in
        let appearance = image.dark
            ? #", "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ]"# : ""
        return #"    { "filename" : "\#(image.file)", "idiom" : "universal", "scale" : "\#(image.scale)"\#(appearance) }"#
    }.joined(separator: ",\n")
    let properties = template ? #",\#n  "properties" : { "template-rendering-intent" : "template" }"#
                              : #",\#n  "properties" : { "template-rendering-intent" : "original" }"#
    return "{\n  \"images\" : [\n\(entries)\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\(properties)\n}\n"
}

let menuBox = CGRect(x: 4, y: 4, width: 92, height: 92)
for (name, state) in [("LogomarkTemplate", MenuState.idle),
                      ("LogomarkPausedTemplate", .paused), ("LogomarkRecordingBody", .recordingBody),
                      ("LogomarkRecordingEye", .recordingEye), ("LogomarkDoneTemplate", .done),
                      ("LogomarkCountdownEye", .countdownEye)] {
    let folder = catalog.appending(path: "\(name).imageset")
    try? FileManager.default.removeItem(at: folder)
    var images: [(String, String, Bool)] = []
    for (scale, px) in [(1, 18), (2, 36), (3, 54)] {
        let file = "menubar-\(scale)x.png"
        write(render(pixels: px, viewBox: menuBox, inkHeight: 0.88) { drawMenu(state, $0) },
              to: folder.appending(path: file))
        images.append((file, "\(scale)x", false))
    }
    try! imageset(name, template: state != .recordingEye && state != .countdownEye, images: images)
        .write(to: folder.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
}

// The coloured mark, 56 points in the permissions window; the dark logomark in the dark.
do {
    let folder = catalog.appending(path: "Logomark.imageset")
    try? FileManager.default.removeItem(at: folder)
    var images: [(String, String, Bool)] = []
    for (scale, px) in [(1, 56), (2, 112), (3, 168)] {
        for dark in [false, true] {
            let file = "logomark-\(px)\(dark ? "-dark" : "").png"
            write(render(pixels: px, viewBox: CGRect(x: 10, y: 4, width: 80, height: 92)) {
                drawLarge($0, dark: dark)
            }, to: folder.appending(path: file))
            images.append((file, "\(scale)x", dark))
        }
    }
    try! imageset("Logomark", template: false, images: images)
        .write(to: folder.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
}

// MARK: - the app icon

/// The icon's artwork as the brand kit's `soredemo-app-icon.svg` places it on its square 1024
/// canvas — 9.6 units to the point, the body four fifths of the tile, as other apps' glyphs are —
/// with that square mapped onto `square` (the whole canvas, or the icon grid's 824 shape).
func iconArtwork(_ c: CGContext, square: CGRect, body: CGColor? = nil, parts: Set<String>) {
    let unit = square.width / 1024
    c.saveGState()
    c.translateBy(x: square.minX + 512 * unit, y: square.minY + 514 * unit)
    c.scaleBy(x: 9.6 * unit, y: 9.6 * unit)
    c.translateBy(x: -50, y: -50)
    drawLarge(c, body: body, parts: parts)
    c.restoreGState()
}

/// The fallback bitmaps for systems that do not read the Icon Composer file: washi on Apple's
/// continuous-corner shape at the macOS icon grid's 824 of 1024, with the grid's shadow.
@MainActor func appIcon(pixels: Int, body: CGColor? = nil) -> NSBitmapImageRep {
    render(pixels: pixels, viewBox: CGRect(x: 0, y: 0, width: Double(pixels), height: Double(pixels))) { c in
        // `render` mapped 0…pixels onto the canvas with y down; draw in pixels here.
        let side = Double(pixels)
        let unit = side / 1024
        let shape = CGRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
        let squircle = Path(roundedRect: shape, cornerRadius: 185.4 * unit, style: .continuous).cgPath
        c.saveGState()
        // A shadow's offset is in device space, which the flip does not reach: down is negative.
        c.setShadow(offset: CGSize(width: 0, height: -10 * unit), blur: 20 * unit,
                    color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.3))
        c.addPath(squircle)
        c.setFillColor(washi)
        c.fillPath()
        c.restoreGState()
        iconArtwork(c, square: shape, body: body, parts: ["body", "eyes"])
    }
}

MainActor.assumeIsolated {
    let folder = catalog.appending(path: "AppIcon.appiconset")
    try? FileManager.default.removeItem(at: folder)
    var entries: [String] = []
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = points * scale
            let file = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
            write(appIcon(pixels: px), to: folder.appending(path: file))
            entries.append(#"    { "filename" : "\#(file)", "idiom" : "mac", "scale" : "\#(scale)x", "size" : "\#(points)x\#(points)" }"#)
        }
    }
    try! "{\n  \"images\" : [\n\(entries.joined(separator: ",\n"))\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
        .write(to: folder.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
}

// The vermilion icon, for Settings → App icon: drawn as the fallback bitmaps are — washi on the
// icon grid's shape, with its shadow — because `NSApplication.applicationIconImage` is shown as
// given, not masked by the system.
MainActor.assumeIsolated {
    let folder = catalog.appending(path: "AppIconVermilion.imageset")
    try? FileManager.default.removeItem(at: folder)
    var images: [(String, String, Bool)] = []
    for (scale, px) in [(1, 512), (2, 1024)] {
        let file = "app-icon-vermilion-\(px).png"
        write(appIcon(pixels: px, body: shuNuri), to: folder.appending(path: file))
        images.append((file, "\(scale)x", false))
    }
    try! imageset("AppIconVermilion", template: false, images: images)
        .write(to: folder.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
}

// MARK: - the Icon Composer file

/// The layers as SVG on Icon Composer's 1024 canvas — the brand kit's square, which the system masks.
/// The system draws the background, the shape, Liquid Glass and the dark and tinted looks.
func layerSVG(_ inner: String) -> String {
    """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
    <g transform="translate(512 514) scale(9.6) translate(-50 -50)">\(inner)</g>
    </svg>

    """
}

do {
    let icon = resources.appending(path: "AppIcon.icon")
    try? FileManager.default.removeItem(at: icon)
    let assets = icon.appending(path: "Assets")
    try! FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    try! layerSVG("""
        <path d="M50 8C73 8 86 30 86 55C86 77 71 92 50 92C29 92 14 77 14 55C14 30 27 8 50 8Z" fill="#16171b"/>\
        <path d="M25 46a25 19.5 0 1 0 50 0a25 19.5 0 1 0 -50 0Z" fill="#ffffff"/>
        """).write(to: assets.appending(path: "body.svg"), atomically: true, encoding: .utf8)
    try! layerSVG("""
        <circle cx="60" cy="46" r="7.5" fill="none" stroke="#fa3d4a" stroke-width="3.4"/>\
        <circle cx="40" cy="46" r="7.5" fill="none" stroke="#16171b" stroke-width="2.6" pathLength="20" stroke-dasharray="1 1"/>
        """).write(to: assets.appending(path: "eyes.svg"), atomically: true, encoding: .utf8)
    let json = """
        {
          "fill" : {
            "solid" : "srgb:0.95686,0.95294,0.93725,1.00000"
          },
          "groups" : [
            {
              "layers" : [
                {
                  "image-name" : "eyes.svg",
                  "name" : "eyes"
                }
              ],
              "name" : "Eyes",
              "shadow" : {
                "kind" : "neutral",
                "opacity" : 0.5
              },
              "translucency" : {
                "enabled" : false,
                "value" : 0.5
              }
            },
            {
              "layers" : [
                {
                  "image-name" : "body.svg",
                  "name" : "body"
                }
              ],
              "name" : "Body",
              "shadow" : {
                "kind" : "neutral",
                "opacity" : 0.5
              },
              "translucency" : {
                "enabled" : false,
                "value" : 0.5
              }
            }
          ],
          "supported-platforms" : {
            "squares" : [
              "macOS"
            ]
          }
        }

        """
    try! json.write(to: icon.appending(path: "icon.json"), atomically: true, encoding: .utf8)
    print("wrote AppIcon.icon")
}
