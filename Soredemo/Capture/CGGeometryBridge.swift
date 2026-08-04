// For `AXValue`, `AXValueGetTypeID()` and `AXValueGetValue` in
// `point(fromAXValue:)`/`size(fromAXValue:)`. An accessibility element's
// position and size arrive as `AXValue`s that decode into a `CGPoint` and a
// `CGSize`, and this is the only file allowed to name either — so the import
// belongs here rather than in `AXObserver`, which would then be holding the
// decoded CoreGraphics values.
import ApplicationServices
import CoreGraphics
// For `NSValue`/`NSDictionary` in `pointRect(fromFrameAttachment:)`. A
// ScreenCaptureKit frame attachment arrives as one of those two Objective-C
// types, and this file is the only place allowed to name the CoreGraphics
// type either of them decodes into — so the import belongs here rather than
// at a call site that would then be handling a `CGRect`.
import Foundation
import Geometry

/// **The only file in the APP TARGET allowed to name a CoreGraphics geometry
/// type.**
///
/// It used to say "in this repository", and Phase 3A-1 Task 2 made that false in
/// the same commit that corrected it: `Sources/Headless/HeadlessGeometryBridge
/// .swift` is now the RENDER tier's bridge, holding the three exits that moved out
/// of this file with `CursorArt`. **There are two because the tiers' ENTRANCES
/// differ** — the AX decoders and the ScreenCaptureKit attachment decoder below
/// need `ApplicationServices`, and the render exits need nothing — not because one
/// bridge was inconvenient. When `Capture` moves to the package in 3A-2 the two are
/// reconsidered together, and the expected outcome is one bridge again.
///
/// Architecture **rule 2** keeps `CGRect`, `CGPoint`, `CGSize` and
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

    /// Interprets `point` as a location in **points** — what
    /// `CGEventGetLocation` (`CGEvent.location`) reports, in the global,
    /// top-left-origin space — and hands back bare scalars.
    ///
    /// **Scalars, not a package type, and this is the one place in the
    /// repository where that is the *right* answer rather than a shortcut.**
    /// There is no package type for an un-normalised point: `NormalizedPoint`
    /// is 0…1 bottom-left and would be a lie at this end of the pipeline, and
    /// `PointRect` is a rectangle — `DisplayArrangement`'s own documentation
    /// rejects wrapping a routed point in a zero-size rect for exactly this
    /// reason ("a point is not a degenerate rect"). `DisplayArrangement
    /// .route`, the very next step, takes two `Double`s. So the honest return
    /// type here is the pair, labelled, with the unit stated in this comment
    /// and nowhere else to state it.
    ///
    /// That is also this boundary's known weakness, named rather than
    /// papered over: nothing in the type system distinguishes these points
    /// from pixels, and `route` cannot either (Task 10.5 left that gap
    /// deliberately). The check that catches a caller feeding pixels where
    /// points belong is `§ 7`'s `scale: 2` fixture in
    /// `scripts/cross-boundary-digest-probe.swift`, where the wrong unit
    /// changes the answer by exactly the scale factor. At `scale: 1` — the
    /// identity element — nothing catches it at all.
    ///
    /// **Why the argument is a `CGPoint` and not a `CGEvent`.** Taking the
    /// event would keep one more CoreGraphics name out of the call site, but
    /// it would put event handling inside a geometry bridge, and the next
    /// caller (AX frames, Task 10) has a point and no event. `CGEvent
    /// .location` is passed straight in, which is the same shape
    /// `CaptureSource.destinationRect` already uses for `window.frame`: the
    /// CG value is produced and consumed in one expression and is never bound
    /// to a name outside this file.
    nonisolated static func location(from point: CGPoint) -> (x: Double, y: Double) {
        (Double(point.x), Double(point.y))
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

    // MARK: - accessibility → package (Task 10)

    /// Decodes an `AXValue` holding a position into bare scalars, in
    /// **points**, in the global top-left space — what `kAXPositionAttribute`
    /// reports, the same space `CGEventGetLocation` reports in.
    ///
    /// **This is the hardest case rule 5 has had, and it is solved here rather
    /// than at the call site.** An AX frame is a `CGRect` in two halves:
    /// `kAXFrameAttribute` is not exposed to Swift, so `AXObserver` reads
    /// `kAXPositionAttribute` and `kAXSizeAttribute` separately — two IPC
    /// round trips per element, not one — and each answer arrives as an
    /// `AXValue` that only `AXValueGetValue` can open, into a `CGPoint` or a
    /// `CGSize`. Every route into those two types therefore passes through the
    /// two functions below, and `AXObserver` never names one.
    ///
    /// **Scalars, not `PointRect`, and the two halves stay separate.** Pairing
    /// them into a rectangle here would hide the fact that they are two
    /// distinct reads at two distinct moments — which is precisely what the
    /// per-element interval in `AXElementRecord` exists to expose (D2-2a), and
    /// what makes the call count in `AXChainRecord.axCalls` add up. The caller
    /// assembles the `PointRect`, guarding the dimensions, because the caller
    /// is the one holding both readings and their timing.
    ///
    /// `nil` when the attribute did not answer, when what came back is not an
    /// `AXValue` at all, or when `AXValueGetValue` refuses the requested type
    /// — three ways for one call to fail that a caller counts as one absence.
    /// A zeroed `CGPoint` would be an element at the top-left corner of the
    /// main display, which is a legal answer and would be wrong.
    ///
    /// **Non-finite values are returned as they are, not filtered.** This
    /// file's own header says a non-finite rectangle traps in
    /// `PointRect.init`; the caller checks `isFinite` where it still has the
    /// context to say which element misreported itself, exactly as the header
    /// prescribes for `CGRect.null`.
    nonisolated static func point(fromAXValue value: CFTypeRef?) -> (x: Double, y: Double)? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return (Double(point.x), Double(point.y))
    }

    /// Decodes an `AXValue` holding a size into bare scalars, in **points** —
    /// what `kAXSizeAttribute` reports. See `point(fromAXValue:)` for why the
    /// two halves of an AX frame are decoded separately and why the result is
    /// scalars.
    nonisolated static func size(fromAXValue value: CFTypeRef?) -> (width: Double, height: Double)? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return (Double(size.width), Double(size.height))
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

    // **The render-side exits that used to sit here — `outputCanvas(width:height:)`,
    // `renderSize(width:height:)` and `point(x:y:)` — are now
    // `Sources/Headless/HeadlessGeometryBridge.swift`** (Phase 3A-1 Task 2), moved
    // with `CursorArt`, their heaviest caller. They took plain scalars and touched
    // neither accessibility nor ScreenCaptureKit, so nothing about them needed this
    // file's `ApplicationServices` import; what remains here is the entrances, which
    // do. They were MOVED, not copied: measured at the split, their seventeen call
    // sites included not one in `Soredemo/Capture/`, so this file has nothing to
    // delegate and `import Headless` here would be an edge carrying no call.
    // `HeadlessEntryRuleTests.theTwoGeometryBridgesShareNoFunctionName` is what keeps
    // that true while two bridges exist.
}
