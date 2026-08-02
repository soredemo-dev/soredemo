import CoreGraphics
import Geometry

/// **The only file in this repository allowed to name a CoreGraphics geometry
/// type.** `AGENTS.md` architecture rule 2 keeps `CGRect`, `CGPoint`, `CGSize`
/// and `CGFloat` out of the package entirely — `Plugins/ArchitectureCheck`
/// fails the build on one — and rule 5 keeps them out of the rest of the app,
/// enforced by a package test that allow-lists this path and no other.
///
/// So: capture converts on entry, render converts on exit, and nothing in
/// between speaks in pixels. Every CoreGraphics rectangle the app receives —
/// `CGDisplayBounds`, `CGEventGetLocation`, an AX frame, a `ScreenCaptureKit`
/// content rect — is turned into a `PixelRect` or a `PointRect` here and never
/// travels further as itself.
///
/// **Pixels and points are not interchangeable, and this file will not pretend
/// they are.** `CGDisplayBounds` and AX frames report *points*; a
/// `ScreenCaptureKit` frame is in *pixels*. They coincide only at `scale == 1`,
/// which is exactly the fixture value that let 97 green tests compare the two
/// directly (`AGENTS.md`, the identity-fixture table). There is therefore no
/// single `convert(_:)` here: the caller names the unit it is holding, because
/// the caller is the only one who knows. Crossing between the two units is
/// `DisplayGeometry.pixels(from:)` / `.points(from:)` and nothing else.
///
/// **Non-finite rectangles trap, deliberately.** `CGRect.null` is
/// `(∞, ∞, 0, 0)` and `CGRect.infinite` is finite in neither field;
/// `PixelRect.init` and `PointRect.init` `precondition` on `isFinite`, so
/// handing either one to this bridge kills the process. That is the intended
/// policy and not an oversight: a null rect reaching geometry conversion means
/// a capture API returned "no rectangle" and the caller did not check, and the
/// alternative — silently substituting zeroes — is a frame recorded at the
/// wrong place with nothing to indicate it. Callers test `rect.isNull` /
/// `rect.isInfinite` at the point where the API hands the value over, where
/// there is still enough context to say what went wrong.
enum CGGeometryBridge {
    // MARK: - CoreGraphics → package

    /// Interprets `rect` as **native pixels**.
    ///
    /// `standardized` first: a `CGRect` may carry a negative width or height to
    /// mean "extends the other way", a representation `PixelRect` does not have
    /// — it `precondition`s on non-negative dimensions — so a drag-selection
    /// rectangle dragged up and to the left would otherwise trap here rather
    /// than convert. Standardizing moves the origin and takes the magnitude,
    /// which is the same rectangle.
    static func pixelRect(from rect: CGRect) -> PixelRect {
        let r = rect.standardized
        return PixelRect(x: Double(r.origin.x), y: Double(r.origin.y),
                         width: Double(r.size.width), height: Double(r.size.height))
    }

    /// Interprets `rect` as **points** — what `CGDisplayBounds`,
    /// `CGEventGetLocation` and AX `kAXPositionAttribute` actually report.
    /// Standardized for the same reason as `pixelRect(from:)`.
    static func pointRect(from rect: CGRect) -> PointRect {
        let r = rect.standardized
        return PointRect(x: Double(r.origin.x), y: Double(r.origin.y),
                         width: Double(r.size.width), height: Double(r.size.height))
    }

    // MARK: - package → CoreGraphics

    /// The render-side exit. Overloaded on the argument type rather than named
    /// `cgRect(fromPixels:)`/`cgRect(fromPoints:)`, because the argument type
    /// already carries the unit and a second spelling of it could disagree.
    static func rect(from pixels: PixelRect) -> CGRect {
        CGRect(x: pixels.x, y: pixels.y, width: pixels.width, height: pixels.height)
    }

    static func rect(from points: PointRect) -> CGRect {
        CGRect(x: points.x, y: points.y, width: points.width, height: points.height)
    }
}
