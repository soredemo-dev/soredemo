import CoreGraphics
import Foundation
import Project

/// A cursor's own picture, as macOS draws it, handed in by the app tier.
///
/// **The drawn art in `CursorArt` is an approximation and looks like one.** Its
/// header says the real shape is "lost and unrecoverable" because capture runs
/// with `showsCursor = false` — which was true of the FRAME and was never true of
/// the cursor itself: `NSCursor` has the image the whole time, and
/// `SystemCursorShape` already reads it on every sample to classify the shape.
/// Only the bytes were being thrown away.
///
/// Measured on macOS 26, and the numbers decide the design:
///
///     arrow            280×400 px for  28×40 pt   →  10×
///     iBeam            230×220 px for  23×22 pt   →  10×
///     pointingHand      64×64  px for  32×32 pt   →   2×
///     crosshair         48×48  px for  24×24 pt   →   2×
///
/// The arrow ships at TEN times density — sharper than any export this app
/// produces — so the usual argument for vector art, that a bitmap softens when
/// magnified, does not apply to the shape that is on screen almost all the time.
/// The 2× ones are exactly the density of the recording they sit on, which is the
/// honest answer rather than a compromise: a cursor sharper than the screen under
/// it reads as pasted on.
///
/// **The pixels are kept as macOS drew them.** No trimming, no re-rendering at a
/// reference size, no nearest-neighbour upscale — each of those is a decision
/// about somebody else's artwork, and the padding is transparent PNG that costs
/// nothing (the arrow is 13 KB). One scale, at draw time, and nothing else.
///
/// **Handed in rather than bundled**, for `SystemCursorShape`'s reason: artwork
/// baked into this app is a fact about one macOS version pinned inside a binary,
/// and it goes stale silently. Asking the running system means a macOS that
/// redraws its cursors is followed rather than contradicted.
///
/// `@unchecked Sendable`: `CGImage` is immutable and this type only reads it.
public struct CursorArtwork: @unchecked Sendable {
    public let image: CGImage
    /// The artwork's size in POINTS — its pixel size divided by its own density,
    /// so a 10× arrow and a 2× hand come out the same size on screen.
    public let pointWidth: Double
    public let pointHeight: Double
    /// Where inside the artwork the pointer actually is, in points from the
    /// image's TOP-LEFT — the convention `NSCursor.hotSpot` uses.
    public let hotspotX: Double
    public let hotspotY: Double

    public init(image: CGImage, pointWidth: Double, pointHeight: Double,
                hotspotX: Double, hotspotY: Double) {
        self.image = image
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.hotspotX = hotspotX
        self.hotspotY = hotspotY
    }

    /// How far the artwork reaches from its hotspot, in points, in the worst
    /// direction. The canvas the cursor is drawn on is sized from this: the arrow
    /// is 40 points tall with its hotspot 5 points down, so it reaches 35 points
    /// below — well past the 24.5 the drawn art needs, and a canvas sized for the
    /// path alone would clip it.
    public var maxExtentFromHotspot: Double {
        max(hotspotX, pointWidth - hotspotX, hotspotY, pointHeight - hotspotY)
    }
}

/// The artwork for each shape this app can classify, or empty.
///
/// A dictionary rather than a function: an absent shape falls back to the drawn
/// path, which is what headless tests and any future shape get, and absence has
/// to be cheap to ask about on every frame.
public enum SystemCursorArtwork {
    /// Set by the app tier before a preview or an export composes anything.
    /// Empty in every headless context, where the drawn art is the answer.
    public nonisolated(unsafe) static var byShape: [PointerShape: CursorArtwork] = [:]

    /// The artwork for a placement's shape, or `nil` to draw the path instead.
    ///
    /// `nil` and `.other` both fall through: `nil` is "unrecorded" and `.other` is
    /// "recorded, and not a shape this schema names", and neither has artwork to
    /// look up. Both draw the arrow's PATH rather than the arrow's ARTWORK, which
    /// keeps them visibly distinguishable from a genuine arrow in a review.
    public static func artwork(for shape: PointerShape?) -> CursorArtwork? {
        guard let shape, shape != .other else { return nil }
        return unsafe byShape[shape]
    }
}
