import CoreGraphics
// For `NSValue`/`NSDictionary` in `pointRect(fromFrameAttachment:)`. A
// ScreenCaptureKit frame attachment arrives as one of those two Objective-C
// types, and this file is the only place allowed to name the CoreGraphics
// type either of them decodes into — so the import belongs here rather than
// at a call site that would then be handling a `CGRect`.
import Foundation
import Geometry

/// **The only file in this repository allowed to name a CoreGraphics geometry
/// type.** Architecture **rule 2** keeps `CGRect`, `CGPoint`, `CGSize` and
/// `CGFloat` out of the package entirely — `Plugins/ArchitectureCheck` fails the
/// build on one. Keeping them out of the rest of the **app** is a different rule
/// with a different mechanism: **rule 5**, enforced by a package **test** rather
/// than by the plugin, because the plugin attaches to SwiftPM targets and cannot
/// see the Xcode app target at all. That test allow-lists this path and no other.
///
/// Both numbers are `ARCHITECTURE.md` D6's, which is now the only numbering.
/// This comment used to carry a parenthetical distinguishing that rule 5 from a
/// different rule 5 in `AGENTS.md`; the second scheme is gone, and a rule that
/// needs its source document named to be identified was the reason.
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
    nonisolated static func pixelRect(from rect: CGRect) -> PixelRect {
        let r = rect.standardized
        return PixelRect(x: Double(r.origin.x), y: Double(r.origin.y),
                         width: Double(r.size.width), height: Double(r.size.height))
    }

    /// Interprets `rect` as **points** — what `CGDisplayBounds`,
    /// `CGEventGetLocation` and AX `kAXPositionAttribute` actually report.
    /// Standardized for the same reason as `pixelRect(from:)`.
    ///
    /// **`nonisolated` on every function in this file, added in Task 8, not
    /// part of this file's original shape.** Unannotated, each of these four
    /// functions is implicitly `@MainActor` under this target's
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — harmless while every
    /// caller was itself MainActor, which stopped being true once
    /// `CaptureSession` (Task 8) needed to bridge a `ScreenCaptureKit`
    /// frame's `ContentRect`/`ScreenRect` attachment from inside an
    /// `SCStreamOutput` callback, which `ScreenCaptureKit` delivers on a
    /// queue this app owns and which must stay synchronous, non-`async`.
    /// Verified by compiling `CaptureSession.swift`: `xcrun swiftc` rejected
    /// `CGGeometryBridge.pointRect(from:)` called from a `nonisolated`
    /// function with the identical error shape `Minting.swift` hit for the
    /// same reason — see that file's own note on `newIdentifier()`. None of
    /// these four functions reads AppKit or UI state; they are pure
    /// coordinate math, so `nonisolated` matches what was already true of
    /// the implementation.
    nonisolated static func pointRect(from rect: CGRect) -> PointRect {
        let r = rect.standardized
        return PointRect(x: Double(r.origin.x), y: Double(r.origin.y),
                         width: Double(r.size.width), height: Double(r.size.height))
    }

    /// Decodes a `PointRect` from a ScreenCaptureKit frame attachment,
    /// whichever way ScreenCaptureKit encoded it.
    ///
    /// **This lives here and not at the call site because the architecture
    /// check said so, and the check was right.** The first version sat in
    /// `CaptureSession` and returned a `CGRect`;
    /// `AppSourceAllowListTests.coreGraphicsGeometryTypesAppearOnlyInTheBridge`
    /// failed it immediately. Decoding a platform representation into a
    /// package type is exactly what this file is for, and a `CGRect` briefly
    /// held elsewhere is how that boundary erodes.
    ///
    /// **Two encodings, deliberately.** The prior code was `as? NSValue`
    /// alone and it never once succeeded: a rect attachment arrives as a
    /// CGRect *dictionary representation*, so the cast failed silently on
    /// every frame of a whole recording. `SCStream.h` distinguishes the two
    /// in the same header — `SCStreamFrameInfoDirtyRects` is documented as
    /// "an array of CGRect **in NSValue**", `SCStreamFrameInfoContentRect`
    /// is not — which is the difference the original cast read past.
    /// Returns `nil` when neither form applies, so the caller can count it.
    nonisolated static func pointRect(fromFrameAttachment attachment: Any?) -> PointRect? {
        if let value = attachment as? NSValue { return pointRect(from: value.rectValue) }
        if let dictionary = attachment as? NSDictionary,
           let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary) {
            return pointRect(from: rect)
        }
        return nil
    }

    // MARK: - package → CoreGraphics

    /// The render-side exit. Overloaded on the argument type rather than named
    /// `cgRect(fromPixels:)`/`cgRect(fromPoints:)`, because the argument type
    /// already carries the unit and a second spelling of it could disagree.
    nonisolated static func rect(from pixels: PixelRect) -> CGRect {
        CGRect(x: pixels.x, y: pixels.y, width: pixels.width, height: pixels.height)
    }

    nonisolated static func rect(from points: PointRect) -> CGRect {
        CGRect(x: points.x, y: points.y, width: points.width, height: points.height)
    }
}
