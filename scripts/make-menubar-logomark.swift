import AppKit

// Builds a menu-bar template asset: the logomark's INK scaled to a fraction of a square
// canvas, the rest transparent. SwiftUI scales a menu bar image to the bar's height whatever
// frame it is given, so the only way to control the mark's apparent size is the proportion of
// the canvas its ink occupies.
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let outDir = URL(fileURLWithPath: CommandLine.arguments[2])
let inkFraction = Double(CommandLine.arguments[3])!

guard let art = NSImage(contentsOf: source) else { exit(1) }

func inkBounds(_ rep: NSBitmapImageRep) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
    var minX = rep.pixelsWide, minY = rep.pixelsHigh, maxX = -1, maxY = -1
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.04 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    return maxX >= minX ? (minX, minY, maxX, maxY) : nil
}

// Measure the source's ink once, at its own resolution.
let probeSize = 512
guard let probe = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: probeSize, pixelsHigh: probeSize,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: probe)
art.draw(in: NSRect(x: 0, y: 0, width: probeSize, height: probeSize))
NSGraphicsContext.restoreGraphicsState()
guard let ink = inkBounds(probe) else { exit(1) }
let inkW = Double(ink.maxX - ink.minX + 1) / Double(probeSize)
let inkH = Double(ink.maxY - ink.minY + 1) / Double(probeSize)
let inkX = Double(ink.minX) / Double(probeSize)
let inkY = Double(ink.minY) / Double(probeSize)
print(String(format: "source ink: %.3f x %.3f at (%.3f, %.3f)", inkW, inkH, inkX, inkY))

for (scale, px) in [(1, 18), (2, 36), (3, 54)] {
    guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: px, height: px).fill()
    // The ink's longest edge becomes `inkFraction` of the canvas; the whole art is drawn at
    // the scale that achieves it, positioned so the ink lands centred.
    let longest = max(inkW, inkH)
    let drawSide = Double(px) * inkFraction / longest
    let originX = (Double(px) - drawSide * inkW) / 2 - inkX * drawSide
    let originY = (Double(px) - drawSide * inkH) / 2 - inkY * drawSide
    art.draw(in: NSRect(x: originX, y: originY, width: drawSide, height: drawSide))
    NSGraphicsContext.restoreGraphicsState()
    let name = outDir.appending(path: "menubar-\(scale)x.png")
    try! out.representation(using: .png, properties: [:])!.write(to: name)
    print("wrote \(name.lastPathComponent) \(px)x\(px)")
}
