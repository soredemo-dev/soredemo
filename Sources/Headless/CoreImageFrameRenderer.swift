import CoreImage
import CoreVideo
import Foundation
// `CursorArt` and `HeadlessGeometryBridge` need no import: this file moved into the
// `Headless` target itself in Phase 3A-1 Task 3, so both are same-module names now.
// (Through Task 2 this file lived in the app target and reached them via `import
// Headless` — importing your own module is an error, so that line is gone, not
// forgotten.)
import Metal
import Render

/// Today's implementation: Core Image on a Metal-backed context.
///
/// Chosen first because the card and corner radius are built-in filters and one composite. It is
/// **not** chosen permanently — the alternative is a hand-written Metal pass, and the decision
/// belongs to a measured 4K frame time. Both sit behind `FrameRendering`, which is why that
/// measurement can still change the answer when it arrives.
///
/// **No shadow filter — corrected here, code review (Task 8, fix round 1).** This comment used to
/// list "the card, shadow and corner radius" as three built-in filters this class applies; it
/// does not apply a shadow one. `StageStyle.shadowRadius`/`.shadowOpacity` are modelled and
/// persisted (`RenderPlan.swift`) but `render(_:source:into:)` below never reads either — see
/// `docs/ARCHITECTURE.md` D6a's own row on exactly this, added at the same finding.
public nonisolated final class CoreImageFrameRenderer: FrameRendering {
    private let context: CIContext

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw FrameRenderingError.noRenderDevice
        }
        // `.workingColorSpace` pinned, not defaulted: uncontrolled colour handling is the failure
        // that cost this project an evening, and a default is a value nobody chose.
        context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        ])
    }

    public func render(_ plan: RenderPlan, source: CVPixelBuffer, into destination: CVPixelBuffer) throws {
        let background = backgroundImage(plan)
        let card = cardImage(plan, source: source)
        var composed = card.composited(over: background)
        // `plan.pointer` is `nil` for three of `PointerReading`'s four cases — `.blind`,
        // `.suppressedByReviewer`, `.noObservationYet` — and `.drawn` for the fourth
        // (`StageCompositor.startRequest`'s own mapping). Nothing here re-derives that decision;
        // this file only draws what it is handed, or draws nothing at all.
        if let pointer = plan.pointer {
            composed = cursorImage(for: pointer, outputHeight: plan.outputHeight).composited(over: composed)
        }
        // `HeadlessGeometryBridge.outputCanvas`, not a literal `CGRect(...)` here: rule 5
        // (`AppSourceAllowListTests.coreGraphicsGeometryTypesAppearOnlyInTheBridge`) confines
        // `CGRect`/`CGFloat` to one file per tier, and `CIImage.cropped(to:)` is the exit point
        // where this app's own `Int`s become CoreGraphics' unit for Core Image. The function moved
        // to `Sources/Headless/HeadlessGeometryBridge.swift` in Phase 3A-1 Task 2 with the rest of
        // the render-side exits; see its doc comment for why it exists at all.
        let cropped = composed
            .cropped(to: HeadlessGeometryBridge.outputCanvas(width: plan.outputWidth, height: plan.outputHeight))
        context.render(cropped, to: destination,
                       bounds: cropped.extent,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    private func backgroundImage(_ plan: RenderPlan) -> CIImage {
        switch plan.style.background {
        case let .solid(red, green, blue):
            return CIImage(color: CIColor(red: red, green: green, blue: blue))
        }
    }

    private func cardImage(_ plan: RenderPlan, source: CVPixelBuffer) -> CIImage {
        let image = CIImage(cvPixelBuffer: source)
        let scaleX = plan.card.width / image.extent.width
        let scaleY = plan.card.height / image.extent.height
        let placed = image
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(translationX: plan.card.x, y: plan.card.y))
        return rounded(placed, plan: plan)
    }

    /// Rounded corners as a mask, not as a crop: a crop gives square corners and a mask gives the
    /// radius the plan asked for.
    private func rounded(_ image: CIImage, plan: RenderPlan) -> CIImage {
        let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(x: plan.card.x, y: plan.card.y,
                                    z: plan.card.width, w: plan.card.height),
            "inputRadius": plan.cornerRadius,
            "inputColor": CIColor.white,
        ])?.outputImage ?? image
        return image.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask,
        ])
    }

    // MARK: - the drawn pointer

    /// One `CGContext` bitmap PER DISTINCT PIXEL SIZE, reused across frames that ask for the same
    /// size — the cache the task brief's Step 3 asks for. What changes frame to frame is never the
    /// canvas's own dimensions for a fixed output resolution (only the ripple's radius and alpha
    /// do, and those are redrawn into the same buffer each call), so the allocation is the one
    /// thing worth avoiding on the hot path; everything else is cheap 2-D drawing into a buffer
    /// already sized to fit it.
    ///
    /// Guards `cursorCanvases` — a `Dictionary`, whose concurrent mutation is undefined behaviour,
    /// not merely a stale-read risk — and every draw into a `CGContext` this cache hands back,
    /// because two callers asking for the SAME `size` share the identical `CGContext` object, and
    /// two threads drawing into one bitmap concurrently is the same category of fault one layer
    /// up. `cursorImage(for:outputHeight:)` below holds this across the whole fetch-clear-draw-
    /// makeImage sequence for exactly that reason: locking only the dictionary access would leave
    /// the drawing itself unguarded.
    ///
    /// This was previously `nonisolated(unsafe)`, unguarded, resting on "`AVFoundation` drives one
    /// compositor's `startRequest(_:)` — and therefore, transitively, one renderer's `render(_:
    /// source:into:)` — serially." Review round 2 of this task named this exact assumption (raised
    /// against `StageCompositor`'s own cached tracks, but stated as covering this dictionary too)
    /// as one no test, header or scan can prove, and asked for it removed rather than documented.
    /// It is also weaker here than it was for `StageCompositor`: `Self.renderer` is a single
    /// `CoreImageFrameRenderer` instance set once and shared by `StageCompositor.renderer`, so
    /// MULTIPLE compositor instances — plausible under seeking, scrubbing, or more than one
    /// concurrent player — would share this ONE dictionary even if each compositor's own requests
    /// were somehow serialised against itself.
    private nonisolated let cursorCanvasLock = NSLock()
    private nonisolated(unsafe) var cursorCanvases: [Int: CGContext] = [:]

    /// Headroom, in OUTPUT PIXELS, added beyond the pointer/ripple geometry's own extent when
    /// sizing a cursor canvas — an antialiased stroke drawn exactly at a bitmap's edge is clipped,
    /// and this is the margin that keeps it from ever reaching the edge.
    private static let cursorCanvasPadding: Double = 6

    /// `pointerPath`'s uniform scale, as a function of the OUTPUT frame's height: `1.0` at 1080p
    /// and up proportionally for a larger canvas, so a 4K export's pointer does not shrink to
    /// illegible relative to the recording the way a fixed pixel size would. Not scaled down below
    /// `1.0` for a smaller output — a pointer smaller than the size this app's own art was drawn
    /// at is a legibility problem this function chooses not to introduce.
    private static func pointerScale(forOutputHeight height: Int) -> Double {
        max(1, Double(height) / 1080)
    }

    /// Fetches (building on first use) the `CGContext` bitmap for a `size`×`size` canvas, cleared
    /// and ready to draw into.
    ///
    /// **Only ever called from inside `cursorCanvasLock.withLock` — `cursorImage(for:outputHeight:)`
    /// below is this function's one call site, and holds the lock across the whole fetch.** That is
    /// what makes each `unsafe` marker below a true statement and not just a silenced diagnostic:
    /// `cursorCanvases` is `nonisolated(unsafe)` so the compiler cannot see the lock that actually
    /// guards it, and flags every access as though nothing did.
    private func cursorCanvas(size: Int) -> CGContext? {
        if let existing = unsafe cursorCanvases[size] {
            existing.clear(HeadlessGeometryBridge.outputCanvas(width: size, height: size))
            return existing
        }
        // `data: nil` — CGContext allocates and owns its own backing store; no raw pointer from
        // this call site is ever read or written directly, which is what makes the `unsafe`
        // initializer safe to use unsafely here.
        guard let created = unsafe CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        unsafe cursorCanvases[size] = created
        return created
    }

    /// The pointer art for one placement, as a `CIImage` already translated to `placement`'s
    /// OUTPUT PIXEL position — the caller composites it directly over the card, with no further
    /// transform. `nil` only if the `CGContext` bitmap could not be created (never observed; kept
    /// as a graceful skip rather than a thrown error, because a rendering hiccup that loses only
    /// the drawn pointer for one frame is a strictly better failure than one that loses the whole
    /// frame).
    ///
    /// **Drawn into a `CGContext` bitmap and wrapped with `CIImage(cgImage:)`, not through
    /// `CIContext.createCGImage`** — the task brief's own "createCGImage-free path": the source of
    /// the pointer art is this app's own vector paths (`CursorArt`), not an existing `CIImage`
    /// there would be anything to extract a `CGImage` FROM.
    ///
    /// **`cursorCanvasLock` is held across the fetch, the drawing and `makeImage()` — not across
    /// this whole function.** `CIImage(cgImage:)` and the translation below touch no shared state,
    /// so they run unlocked; the caller's own `context.render(...)` GPU call in `render(_:source:
    /// into:)` happens even later, in a different function, well after this one has already
    /// returned and released the lock. Holding a lock across THAT call — which can cost
    /// milliseconds — would serialise frames on a path `AVFoundation` may already be serialising,
    /// which is a performance change and not what this lock exists to buy.
    private func cursorImage(for placement: NormalizedPointerPlacement, outputHeight: Int) -> CIImage {
        let scale = Self.pointerScale(forOutputHeight: outputHeight)
        let halfExtent = max(CursorArt.rippleEndRadius, scale * CursorArt.pointerMaxExtent)
            + Self.cursorCanvasPadding
        let size = Int((halfExtent * 2).rounded(.up))
        // The tip — the path origin both `CursorArt.pointerPath` and `.ripplePath` are built
        // around — sits at the canvas's own centre, so there is equal headroom on every side for
        // both the arrow (which extends only right and down from its tip) and the ripple (which
        // is centred on it and extends every direction).
        let tip = Double(size) / 2

        let image = cursorCanvasLock.withLock { () -> CGImage? in
            guard let bitmap = cursorCanvas(size: size) else { return nil }
            bitmap.saveGState()
            bitmap.translateBy(x: tip, y: tip)

            bitmap.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            bitmap.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            bitmap.setLineWidth(1.5)
            bitmap.addPath(CursorArt.pointerPath(scale: scale))
            bitmap.drawPath(using: .fillStroke)

            // Only when `ripplePhase` is non-`nil` — `NormalizedPointerPlacement`'s own doc
            // comment: `nil` means "not clicking", and the absence of a ripple is exactly what
            // that means drawn.
            if let phase = placement.ripplePhase {
                bitmap.addPath(CursorArt.ripplePath(phase: phase))
                bitmap.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1 - min(max(phase, 0), 1)))
                bitmap.setLineWidth(2)
                bitmap.strokePath()
            }
            bitmap.restoreGState()
            return bitmap.makeImage()
        }
        guard let image else { return CIImage.empty() }
        return CIImage(cgImage: image)
            .transformed(by: CGAffineTransform(translationX: placement.x - tip, y: placement.y - tip))
    }
}
