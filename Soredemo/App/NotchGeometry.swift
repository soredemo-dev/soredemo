import Geometry

/// Where the editor's opening animation starts and where it ends, on any Mac.
///
/// **Nothing here is a constant, and that is the whole point of the type.** The first version of
/// this design was written from one machine — a 14-inch MacBook Pro at 1512 x 982, notch
/// 185 x 32, full screen 949 — and every one of those numbers is a property of that machine in
/// that display mode rather than of "the notch". The same panel offers eleven scaled modes from
/// 960 x 600 to 1800 x 1169 points, and the notch is a fixed number of PIXELS, so its size in
/// points moves with the scale: about 117 points wide at the smallest and 220 at the largest.
///
/// **A notched Mac can report no notch.** macOS offers each mode twice — 1512 x 982 includes the
/// notch strip, 1512 x 945 does not — and in the second kind the screen has no auxiliary areas
/// and no top safe-area inset. So "MacBook Pro" is not the question; "does this screen, right
/// now, have a notch" is, and it is asked of the screen every time.
struct NotchGeometry: Equatable {
    /// Where the shape starts: the notch, or the strip that stands in for it.
    let start: PointRect
    /// Where it ends: the frame the window actually reached, which the caller reads from the
    /// window rather than predicting.
    let end: PointRect
    /// Whether `start` is a real notch. The fallback strip is rounded evenly on all four
    /// corners; a real notch keeps its own radius on the top two so the shape stays attached to
    /// it.
    let isNotch: Bool

    /// The distance between the bottom of `start` and the top of `end`.
    ///
    /// **Measured at 1 point on the machine this was designed on, and not assumed to be 1
    /// anywhere else.** A native full-screen window's top edge sits `menubarHeight` below the
    /// screen's top; the notch's bottom edge sits `safeAreaInsets.top` below it. The two are one
    /// point apart on a 14-inch at 1512 x 982 and there is no published guarantee that they are
    /// one point apart on any other Mac, in any other mode, in any future release. So the shape
    /// travels whatever this says, and `startsFlush` decides how it is drawn.
    var gap: Double { end.y - (start.y + start.height) }

    /// Whether the shape can grow straight out of the notch with nothing showing between them.
    ///
    /// Two points of tolerance rather than exact equality: these are points on a scaled display
    /// and a half-point of rounding is not a seam anybody can see.
    var startsFlush: Bool { gap <= 2 }
}

/// A screen, reduced to the five numbers this decision needs.
///
/// A value rather than an `NSScreen` so every Mac shape can be built in a test — the geometry is
/// the part worth checking, and no test can attach a 16-inch panel.
struct ScreenMetrics: Equatable {
    /// The screen's frame in global TOP-LEFT points, which is the space this animation works in
    /// and the space `CGDisplayBounds` reports. Not AppKit's bottom-left frame.
    let frame: PointRect
    /// `NSScreen.safeAreaInsets.top`. Zero on a screen with no notch.
    let safeAreaTop: Double
    /// `frame.maxY - visibleFrame.maxY` in AppKit terms: how tall the menu bar is.
    let menubarHeight: Double
    /// `NSScreen.auxiliaryTopLeftArea?.width` / `...Right...`. Both `nil` on a screen with no
    /// notch — which includes a notched panel in a mode that excludes the notch strip.
    let auxiliaryLeftWidth: Double?
    let auxiliaryRightWidth: Double?

    /// Whether this screen has a notch, asked the way the screen answers it.
    var hasNotch: Bool { auxiliaryLeftWidth != nil && auxiliaryRightWidth != nil && safeAreaTop > 0 }

    /// The notch's own rectangle in global top-left points, or `nil`.
    var notch: PointRect? {
        guard hasNotch, let left = auxiliaryLeftWidth, let right = auxiliaryRightWidth else {
            return nil
        }
        let width = frame.width - left - right
        guard width > 0, safeAreaTop > 0 else { return nil }
        return PointRect(x: frame.x + (frame.width - width) / 2, y: frame.y,
                         width: width, height: safeAreaTop)
    }
}

extension NotchGeometry {
    /// **The fallback strip's width, as a fraction of the screen rather than a number of
    /// points.** A fixed 300 points is a third of a small external display and a sixth of a
    /// large one; the same fraction reads the same on both. Chosen to sit near the notch's own
    /// share of a 14-inch — 185 of 1512 is 12.2% — so the gesture is the same shape whether or
    /// not there is a notch to come out of.
    static let fallbackWidthFraction: Double = 0.122

    /// **The fallback strip's height when there is no menu bar to borrow.** Only reachable on a
    /// screen reporting a zero-height menu bar, which is not a configuration anybody has seen;
    /// a named value beats a zero-height rectangle that animates from nothing.
    static let fallbackHeight: Double = 24

    /// The start and end of the editor's opening animation.
    ///
    /// `windowFrame` is what the window ACTUALLY reached, read from it after it settled — not a
    /// predicted full-screen rectangle. `FullScreenEntry` can spend its budget and leave a grown
    /// window instead, and a shape that animated to a full-screen rectangle and then handed over
    /// to a smaller window would end in a jump.
    static func opening(into windowFrame: PointRect, on screen: ScreenMetrics) -> NotchGeometry {
        if let notch = screen.notch {
            return NotchGeometry(start: notch, end: windowFrame, isNotch: true)
        }
        // No notch: the same gesture from the same place. The idea is "the editor comes out of
        // the top of the screen", and the notch is only its most literal form.
        let width = max(1, screen.frame.width * fallbackWidthFraction)
        let height = max(screen.menubarHeight, fallbackHeight)
        return NotchGeometry(
            start: PointRect(x: screen.frame.x + (screen.frame.width - width) / 2,
                             y: screen.frame.y, width: width, height: height),
            end: windowFrame, isNotch: false)
    }
}
