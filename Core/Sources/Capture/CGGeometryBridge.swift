// For `AXValue`, `AXValueGetTypeID()` and `AXValueGetValue` in the AX decoders
// below; this file is the only one allowed to name the types they decode into.
import ApplicationServices
import CoreGraphics
// For `NSValue`/`NSDictionary` in `pointRect(fromFrameAttachment:)`, whose
// decoded `CGRect` may not escape this file.
import Foundation
import Geometry

/// One of the two files in `Sources/Headless` allowed to name a CoreGraphics geometry
/// type. The app target now names none at all (`noAppSourceNamesACoreGraphicsGeometryType`).
///
/// Architecture rule 2 keeps `CGRect`, `CGPoint`, `CGSize` and `CGFloat` out of
/// the package (`Plugins/ArchitectureCheck`); rule 5 keeps them out of the rest
/// of the app (a package test that allow-lists this path and no other).
/// `HeadlessGeometryBridge.swift`, beside it in this target since Phase 3A-3, is the
/// RENDER tier's bridge and stays a separate file: this one is the capture tier's
/// ENTRY (AX frames, ScreenCaptureKit rects, event taps — points and pixels arriving
/// from the system), that one is the render tier's EXIT (the `CGRect`/`CGSize` Core
/// Image and AVFoundation demand). A test forbids the two from sharing a function
/// signature, which is what keeps "two bridges" from decaying into "one bridge, twice".
///
/// Pixels and points are not interchangeable, so there is no single
/// `convert(_:)` here: `CGDisplayBounds` and AX frames report points, a
/// `ScreenCaptureKit` frame is in pixels, and crossing between the two units is
/// `DisplayGeometry.pixels(from:)` / `.points(from:)` and nothing else.
///
/// Non-finite rectangles trap — `PixelRect.init` and `PointRect.init`
/// `precondition` on `isFinite`, and `CGRect.null` is `(∞, ∞, 0, 0)`. Callers
/// test `rect.isNull` / `rect.isInfinite` where the API hands the value over.
public enum CGGeometryBridge {
    // MARK: - CoreGraphics → package

    /// Interprets `rect` as native pixels. `standardized` first: a `CGRect` may
    /// carry a negative width or height, which `PixelRect` `precondition`s
    /// against.
    public nonisolated static func pixelRect(from rect: CGRect) -> PixelRect {
        let r = rect.standardized
        return PixelRect(x: Double(r.origin.x), y: Double(r.origin.y),
                         width: Double(r.size.width), height: Double(r.size.height))
    }

    /// Interprets `rect` as points — what `CGDisplayBounds`,
    /// `CGEventGetLocation` and AX `kAXPositionAttribute` report; standardized
    /// for the same reason as `pixelRect(from:)`.
    ///
    /// `nonisolated` on every function in this file: under this target's
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` they would otherwise be
    /// unreachable from the synchronous, non-`async` `SCStreamOutput` callback.
    public nonisolated static func pointRect(from rect: CGRect) -> PointRect {
        let r = rect.standardized
        return PointRect(x: Double(r.origin.x), y: Double(r.origin.y),
                         width: Double(r.size.width), height: Double(r.size.height))
    }

    /// Interprets `point` as a location in points, in the global
    /// top-left-origin space `CGEventGetLocation` reports in, and returns bare
    /// scalars: no package type describes an un-normalised point, and
    /// `DisplayArrangement.route`, the next step, takes two `Double`s.
    public nonisolated static func location(from point: CGPoint) -> (x: Double, y: Double) {
        (Double(point.x), Double(point.y))
    }

    /// Decodes a `PointRect` from a ScreenCaptureKit frame attachment. Both
    /// encodings are handled: `SCStreamFrameInfoContentRect` arrives as a CGRect
    /// dictionary representation, `SCStreamFrameInfoDirtyRects` as an `NSValue`.
    /// Returns `nil` when neither form applies, so the caller can count it.
    public nonisolated static func pointRect(fromFrameAttachment attachment: Any?) -> PointRect? {
        if let value = attachment as? NSValue { return pointRect(from: value.rectValue) }
        if let dictionary = attachment as? NSDictionary,
           let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary) {
            return pointRect(from: rect)
        }
        return nil
    }

    /// Decodes a scalar frame attachment — `SCStreamFrameInfoContentScale`,
    /// `.scaleFactor` — as a `Double`. `nil` when the attachment is absent or is
    /// neither form, so a caller can count that rather than substitute a number.
    ///
    /// Both forms are handled because `recordContentScale` handled both before this function
    /// existed, and narrowing it here would be a change nobody measured. Which form arrives is
    /// not pinned by anything in this repository; a cast to only one of them would read
    /// nothing whenever the other turned up, and that is indistinguishable from a stream that
    /// never reported the value.
    public nonisolated static func double(fromFrameAttachment attachment: Any?) -> Double? {
        if let value = attachment as? Double { return value }
        if let number = attachment as? NSNumber { return number.doubleValue }
        return nil
    }

    // MARK: - accessibility → package

    /// The current frame of ONE window, by ID — the live value `SCWindow.frame` is not.
    /// `SCWindow` carries the frame the content query saw and never updates it, so a window
    /// moved or resized during a recording leaves the capture cropping the wrong rectangle
    /// and the pointer normalised against it. `WindowFollower` is the only caller.
    ///
    /// `CGWindowListCopyWindowInfo` is banned in the app tier because its usual
    /// shape enumerates every window on the machine and can read `kCGWindowName`.
    /// This shape is different: one specific ID, `kCGWindowBounds` only. The ban
    /// is narrowed to permit this file and no other, so it stays auditable in one
    /// place rather than becoming a habit; `kCGWindowName` remains banned here too.
    ///
    /// `nil` when the window is gone — closed, or moved to another Space. That is
    /// not "unchanged", and the caller must not treat it as such.
    public nonisolated static func windowBounds(_ windowID: CGWindowID) -> PointRect? {
        guard let infoList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID)
                as? [[String: Any]],
              let info = infoList.first,
              let boundsDictionary = info[kCGWindowBounds as String] as? [String: Any]
        else { return nil }
        var rect = CGRect.zero
        // `unsafe`: a C function writing through an `inout` pointer. Safe here — `rect` is
        // a local that outlives the call, and its value is only trusted when the function
        // returns true, which is exactly what the `guard` requires.
        guard unsafe CGRectMakeWithDictionaryRepresentation(boundsDictionary as CFDictionary, &rect),
              !rect.isNull, !rect.isInfinite,
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width > 0, rect.height > 0
        else { return nil }
        return pointRect(from: rect)
    }

    /// Decodes an `AXValue` holding a position into bare scalars, in points, in
    /// the global top-left space `kAXPositionAttribute` reports in. Position and
    /// size stay separate scalars; the caller assembles the `PointRect`.
    ///
    /// `nil` — never a zeroed point, which is a legal position — when the
    /// attribute did not answer, what came back is not an `AXValue`, or
    /// `AXValueGetValue` refuses the type. Non-finite values pass through
    /// unfiltered; the caller checks `isFinite`.
    public nonisolated static func point(fromAXValue value: CFTypeRef?) -> (x: Double, y: Double)? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        // Safe here: the `as!` is guarded by the `CFGetTypeID` check one line up, and
        // `&point` is a local outliving the call. `AXValueGetValue` returns false — not a
        // partial write — when the stored kind is not the requested one, which is what
        // `theAXPointDecoderRefusesAnAXValueOfTheWrongKind` observes.
        guard unsafe AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return (Double(point.x), Double(point.y))
    }

    /// Decodes an `AXValue` holding a size into bare scalars, in points — what
    /// `kAXSizeAttribute` reports. Fails as `point(fromAXValue:)` does.
    public nonisolated static func size(fromAXValue value: CFTypeRef?) -> (width: Double, height: Double)? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        // Safe here: same argument as `point(fromAXValue:)` above.
        guard unsafe AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return (Double(size.width), Double(size.height))
    }

    // MARK: - package → CoreGraphics

    /// The render-side exit. Overloaded on the argument type because that type
    /// already carries the unit; a second spelling of it could disagree.
    public nonisolated static func rect(from pixels: PixelRect) -> CGRect {
        CGRect(x: pixels.x, y: pixels.y, width: pixels.width, height: pixels.height)
    }

    public nonisolated static func rect(from points: PointRect) -> CGRect {
        CGRect(x: points.x, y: points.y, width: points.width, height: points.height)
    }

    /// The notch surface's outline, in top-left points, as the app's SwiftUI shape draws it.
    ///
    /// Full width along the top edge, then each top corner curls INWARD to a body inset by
    /// `flare` — so the shape runs into the menu bar the way the hardware notch does rather than
    /// hanging below it with rounded shoulders (a notch assistant's idea; see the notch design docs).
    /// Here and not in the app because the app names no CoreGraphics geometry type (rule 5).
    public nonisolated static func notchOutline(width: Double, height: Double, flare: Double, bottomRadius: Double) -> CGPath {
        let f = max(0, min(flare, width / 2, height))
        let left = f, right = width - f
        let r = max(0, min(bottomRadius, (right - left) / 2, height - f))
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: width, y: 0))
        path.addQuadCurve(to: CGPoint(x: right, y: f), control: CGPoint(x: right, y: 0))
        path.addLine(to: CGPoint(x: right, y: height - r))
        path.addQuadCurve(to: CGPoint(x: right - r, y: height), control: CGPoint(x: right, y: height))
        path.addLine(to: CGPoint(x: left + r, y: height))
        path.addQuadCurve(to: CGPoint(x: left, y: height - r), control: CGPoint(x: left, y: height))
        path.addLine(to: CGPoint(x: left, y: f))
        path.addQuadCurve(to: CGPoint(x: 0, y: 0), control: CGPoint(x: left, y: 0))
        path.closeSubpath()
        return path
    }

    /// The daruma's body — the brand kit's path, `M50 8C73 8 86 30 86 55C86 77 71 92 50 92C29 92
    /// 14 77 14 55C14 30 27 8 50 8Z` in a 100-unit box — drawn in `box`, top-left points. Here,
    /// like the notch's outline, because the app names no CoreGraphics geometry type (rule 5).
    public nonisolated static func darumaOutline(in box: PointRect) -> CGPath {
        let ux = box.width / 100, uy = box.height / 100
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: box.x + x * ux, y: box.y + y * uy)
        }
        let path = CGMutablePath()
        path.move(to: point(50, 8))
        path.addCurve(to: point(86, 55), control1: point(73, 8), control2: point(86, 30))
        path.addCurve(to: point(50, 92), control1: point(86, 77), control2: point(71, 92))
        path.addCurve(to: point(14, 55), control1: point(29, 92), control2: point(14, 77))
        path.addCurve(to: point(50, 8), control1: point(14, 30), control2: point(27, 8))
        path.closeSubpath()
        return path
    }

    /// The daruma character's body, in `box` (top-left points): `DarumaBodyCurve`'s four curves,
    /// the one statement of the shape. The character morphs by changing its three numbers; the
    /// curve's structure never changes, so any two shapes interpolate.
    public nonisolated static func darumaBody(width w: Double, height h: Double, crown: Double, in box: PointRect) -> CGPath {
        let ux = box.width / 100, uy = box.height / 100
        func p(_ point: DarumaBodyCurve.Point) -> CGPoint { CGPoint(x: box.x + point.x * ux, y: box.y + point.y * uy) }
        let (start, segments) = DarumaBodyCurve.outline(width: w, height: h, crown: crown)
        let path = CGMutablePath()
        path.move(to: p(start))
        for segment in segments { path.addCurve(to: p(segment.end), control1: p(segment.control1), control2: p(segment.control2)) }
        path.closeSubpath()
        return path
    }

    /// An ellipse turned by `tilt` degrees about its own centre.
    public nonisolated static func ellipse(centreX: Double, centreY: Double, radiusX: Double, radiusY: Double, tilt: Double) -> CGPath {
        var turn = turnedAbout(centreX, centreY, tilt)
        let rect = CGRect(x: centreX - radiusX, y: centreY - radiusY, width: 2 * radiusX, height: 2 * radiusY)
        return unsafe CGPath(ellipseIn: rect, transform: &turn)
    }

    /// A pill — a rounded rectangle whose corner radius is half its shorter side — turned by
    /// `tilt` degrees about its own centre.
    public nonisolated static func pill(centreX: Double, centreY: Double, width: Double, height: Double, tilt: Double) -> CGPath {
        var turn = turnedAbout(centreX, centreY, tilt)
        let rect = CGRect(x: centreX - width / 2, y: centreY - height / 2, width: width, height: height)
        let radius = max(min(width, height) / 2 - 0.0001, 0)
        return unsafe CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: &turn)
    }

    /// A quadratic arc stroked into a fillable outline with round caps — an eye drawn as a line
    /// (closed, smiling) that an even-odd fill can still carry.
    public nonisolated static func strokedArc(fromX: Double, fromY: Double, controlX: Double, controlY: Double, toX: Double, toY: Double, lineWidth: Double) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: fromX, y: fromY))
        path.addQuadCurve(to: CGPoint(x: toX, y: toY), control: CGPoint(x: controlX, y: controlY))
        return path.copy(strokingWithWidth: lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 1)
    }

    private nonisolated static func turnedAbout(_ x: Double, _ y: Double, _ degrees: Double) -> CGAffineTransform {
        CGAffineTransform(translationX: x, y: y).rotated(by: degrees * .pi / 180).translatedBy(x: -x, y: -y)
    }

    /// What is left of a countdown's second, as an arc round `(centreX, centreY)` in top-left
    /// points: from twelve o'clock, clockwise, `remaining` of the way round (0 … 1). Empty for 0.
    public nonisolated static func countdownArc(centreX: Double, centreY: Double, radius: Double, remaining: Double) -> CGPath {
        let path = CGMutablePath()
        let share = min(max(remaining, 0), 1)
        guard share > 0 else { return path }
        // In top-left points y grows downward, so a clockwise sweep on screen is an increasing
        // angle — `clockwise: false` in CoreGraphics' own (y-up) terms.
        let start = -Double.pi / 2
        path.addArc(center: CGPoint(x: centreX, y: centreY), radius: radius,
                    startAngle: start, endAngle: start + 2 * .pi * share, clockwise: false)
        return path
    }

    /// An upright bar with rounded corners about its centre, in top-left points: half the pause
    /// symbol the paused daruma's eyes make.
    public nonisolated static func bar(centreX: Double, centreY: Double, width: Double, height: Double, corner: Double) -> CGPath {
        // `unsafe`: the initialiser takes its transform as a pointer, here `nil`.
        unsafe CGPath(roundedRect: CGRect(x: centreX - width / 2, y: centreY - height / 2, width: width, height: height),
                      cornerWidth: corner, cornerHeight: corner, transform: nil)
    }

    /// The brush that paints the record eye, in top-left points: one clockwise sweep from twelve
    /// o'clock at half of `radius`, so a stroke as wide as `radius` covers the disc when drawn
    /// whole — the eye fills like a clock hand, as the countdown's ring drains. `painted` (0 … 1)
    /// is how far round the brush has gone. Empty for 0.
    public nonisolated static func brushSweep(centreX: Double, centreY: Double, radius: Double, painted: Double = 1) -> CGPath {
        let path = CGMutablePath(), share = min(max(painted, 0), 1)
        guard share > 0 else { return path }
        // Clockwise on screen is an increasing angle in top-left points (`countdownArc`).
        let start = -Double.pi / 2
        path.addArc(center: CGPoint(x: centreX, y: centreY), radius: radius / 2,
                    startAngle: start, endAngle: start + 2 * .pi * share, clockwise: false)
        return path
    }

    /// A video track's DISPLAYED size in whole pixels, transform applied.
    ///
    /// **`naturalSize` alone is the encoded size and is not what anybody sees.** A recording made
    /// on a phone held upright is encoded landscape with a rotation in `preferredTransform`;
    /// reporting 1920x1080 for it would describe a sequence turned on its side, and every clip in
    /// it would sit in letterbox bars nobody asked for.
    ///
    /// Absolute values, because a transform that flips an axis produces a negative extent — which
    /// is a direction, not a size.
    ///
    /// Rounded rather than truncated: a track can report a fractional dimension, and `1919` for a
    /// 1920-wide recording is an off-by-one that every downstream size inherits.
    public nonisolated static func displayedPixelSize(of naturalSize: CGSize, transform: CGAffineTransform) -> (width: Int, height: Int) {
        let displayed = naturalSize.applying(transform)
        return (Int(abs(displayed.width).rounded()), Int(abs(displayed.height).rounded()))
    }

    /// The `CGSize` `AVAssetImageGenerator.maximumSize` takes, from plain `Int`s.
    ///
    /// The app tier names no CoreGraphics geometry type at all
    /// (`noAppSourceNamesACoreGraphicsGeometryType`), and a filmstrip has to cap
    /// its thumbnail size or it decodes 4K frames to draw postage stamps.
    /// Distinct from `HeadlessGeometryBridge.renderSize(width:height:)` by name as
    /// well as by tier: a test forbids the two bridges sharing a signature.
    public nonisolated static func thumbnailSize(width: Int, height: Int) -> CGSize {
        CGSize(width: CGFloat(width), height: CGFloat(height))
    }
}
