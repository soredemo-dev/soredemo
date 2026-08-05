// For `AXValue`, `AXValueGetTypeID()` and `AXValueGetValue` in the AX decoders
// below; this file is the only one allowed to name the types they decode into.
import ApplicationServices
import CoreGraphics
// For `NSValue`/`NSDictionary` in `pointRect(fromFrameAttachment:)`, whose
// decoded `CGRect` may not escape this file.
import Foundation
import Geometry

/// The only file in the app target allowed to name a CoreGraphics geometry type.
///
/// Architecture rule 2 keeps `CGRect`, `CGPoint`, `CGSize` and `CGFloat` out of
/// the package (`Plugins/ArchitectureCheck`); rule 5 keeps them out of the rest
/// of the app (a package test that allow-lists this path and no other).
/// `Sources/Headless/HeadlessGeometryBridge.swift` is the render tier's bridge.
///
/// Pixels and points are not interchangeable, so there is no single
/// `convert(_:)` here: `CGDisplayBounds` and AX frames report points, a
/// `ScreenCaptureKit` frame is in pixels, and crossing between the two units is
/// `DisplayGeometry.pixels(from:)` / `.points(from:)` and nothing else.
///
/// Non-finite rectangles trap — `PixelRect.init` and `PointRect.init`
/// `precondition` on `isFinite`, and `CGRect.null` is `(∞, ∞, 0, 0)`. Callers
/// test `rect.isNull` / `rect.isInfinite` where the API hands the value over.
enum CGGeometryBridge {
    // MARK: - CoreGraphics → package

    /// Interprets `rect` as native pixels. `standardized` first: a `CGRect` may
    /// carry a negative width or height, which `PixelRect` `precondition`s
    /// against.
    nonisolated static func pixelRect(from rect: CGRect) -> PixelRect {
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
    nonisolated static func pointRect(from rect: CGRect) -> PointRect {
        let r = rect.standardized
        return PointRect(x: Double(r.origin.x), y: Double(r.origin.y),
                         width: Double(r.size.width), height: Double(r.size.height))
    }

    /// Interprets `point` as a location in points, in the global
    /// top-left-origin space `CGEventGetLocation` reports in, and returns bare
    /// scalars: no package type describes an un-normalised point, and
    /// `DisplayArrangement.route`, the next step, takes two `Double`s.
    nonisolated static func location(from point: CGPoint) -> (x: Double, y: Double) {
        (Double(point.x), Double(point.y))
    }

    /// Decodes a `PointRect` from a ScreenCaptureKit frame attachment. Both
    /// encodings are handled: `SCStreamFrameInfoContentRect` arrives as a CGRect
    /// dictionary representation, `SCStreamFrameInfoDirtyRects` as an `NSValue`.
    /// Returns `nil` when neither form applies, so the caller can count it.
    nonisolated static func pointRect(fromFrameAttachment attachment: Any?) -> PointRect? {
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
    nonisolated static func point(fromAXValue value: CFTypeRef?) -> (x: Double, y: Double)? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return (Double(point.x), Double(point.y))
    }

    /// Decodes an `AXValue` holding a size into bare scalars, in points — what
    /// `kAXSizeAttribute` reports. Fails as `point(fromAXValue:)` does.
    nonisolated static func size(fromAXValue value: CFTypeRef?) -> (width: Double, height: Double)? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return (Double(size.width), Double(size.height))
    }

    // MARK: - package → CoreGraphics

    /// The render-side exit. Overloaded on the argument type because that type
    /// already carries the unit; a second spelling of it could disagree.
    nonisolated static func rect(from pixels: PixelRect) -> CGRect {
        CGRect(x: pixels.x, y: pixels.y, width: pixels.width, height: pixels.height)
    }

    nonisolated static func rect(from points: PointRect) -> CGRect {
        CGRect(x: points.x, y: points.y, width: points.width, height: points.height)
    }
}
