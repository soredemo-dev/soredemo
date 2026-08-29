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

    // MARK: - accessibility → package

    /// Decodes an `AXValue` holding a position into bare scalars, in points, in
    /// the global top-left space `kAXPositionAttribute` reports in. Position and
    /// size stay separate scalars; the caller assembles the `PointRect`.
    ///
    /// `nil` — never a zeroed point, which is a legal position — when the
    /// attribute did not answer, what came back is not an `AXValue`, or
    /// `AXValueGetValue` refuses the type. Non-finite values pass through
    /// unfiltered; the caller checks `isFinite`.
    /// **The current frame of ONE window, by ID** — the live value `SCWindow.frame` is not.
    /// `SCWindow` carries the frame the content query saw and never updates it, so a window
    /// moved or resized during a recording leaves the capture cropping the wrong rectangle
    /// and the pointer normalised against it. `WindowFollower` is the only caller.
    ///
    /// **Why the scoped call is here and not there.** `CGWindowListCopyWindowInfo` is on
    /// `noAppSourceReadsUserContent`'s ban list, because in its usual shape — `.optionAll`
    /// with `kCGNullWindowID` — it enumerates every window on the machine, including the
    /// unrecorded ones, and can read `kCGWindowName`. That concern is real and the ban is
    /// right. This call is a different shape: `.optionIncludingWindow` with a specific ID
    /// returns exactly one window, the one already being recorded, and reads only
    /// `kCGWindowBounds` — a rectangle, which an observation log may carry. The ban is
    /// narrowed to permit this file and no other, so the shape stays auditable in one place
    /// rather than becoming a habit; `kCGWindowName` remains banned everywhere including here.
    ///
    /// Returns `nil` when the window is gone — closed, or moved to another Space. That is
    /// not the same as "unchanged" and the caller must not treat it as such.
    ///
    /// `kCGWindowBounds` is a dictionary representation of a `CGRect` in global top-left
    /// points. `CGRectMakeWithDictionaryRepresentation` is the documented way back, rather
    /// than picking the four keys out by hand — and it belongs in this file because the
    /// `CGRect` it produces may not escape it.
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

    /// The `CGSize` `AVAssetImageGenerator.maximumSize` takes, from plain `Int`s.
    ///
    /// **The app tier names no CoreGraphics geometry type at all** — a zero-permit claim
    /// (`noAppSourceNamesACoreGraphicsGeometryType`), and a filmstrip has to cap its thumbnail
    /// size or it decodes 4K frames to draw postage stamps. Distinct from
    /// `HeadlessGeometryBridge.renderSize(width:height:)` by name as well as by tier, because a
    /// test forbids the two bridges from sharing a function signature.
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

    public nonisolated static func thumbnailSize(width: Int, height: Int) -> CGSize {
        CGSize(width: CGFloat(width), height: CGFloat(height))
    }
}
