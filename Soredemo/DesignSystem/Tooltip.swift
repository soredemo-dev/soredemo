import AppKit
import SwiftUI

/// A tooltip this app draws, rather than the one AppKit draws.
///
/// **Because AppKit's does not appear on a disabled control, and a disabled control is the one
/// whose name you most need.** Half the editor toolbar is disabled at any moment — nothing to
/// undo, nothing selected, no silence found — and hovering those icons said nothing at all.
/// Reported as "the cursor on a function button doesn't show the button's name", and on the
/// disabled half that is exactly right. This project already wrote the principle down once, on
/// the Save button: *a button that cannot be pressed cannot explain that.*
///
/// **And because AppKit's is too slow for a row of icons.** Its delay is a system setting with
/// no public control, and it is tuned for occasional help on a labelled control, not for
/// scanning a strip of glyphs. `delay` here is 400 ms: long enough not to flash while the
/// pointer crosses the row, short enough to be an answer rather than a reward for waiting.
///
/// The bubble is drawn OUTSIDE the button and never hit-tests, so it cannot eat the click it is
/// explaining.
struct Tooltip: ViewModifier {
    let text: LocalizedStringKey
    /// Where the pointer has to rest before this is help rather than flicker.
    static let delay = Duration.milliseconds(400)
    /// Wide enough for a sentence, narrow enough to stay a tooltip.
    static let maximumWidth: Double = 260

    @State private var isHovering = false
    @State private var isShown = false
    /// How wide the bubble turned out. **Measured, not assumed.** Clamping a three-word label
    /// as if it were the full 260 points pushes it further from the edge than it needs to be,
    /// which reads as a tooltip pointing at the wrong button.
    @State private var bubbleWidth = Tooltip.maximumWidth
    /// Where the button is on the screen, so the bubble can be kept on it.
    @State private var anchor: Anchor?

    /// Where the control is, in plain numbers. **Not a `CGRect`** — see the capture below.
    ///
    /// `nonisolated` because `onGeometryChange` takes a `Sendable` type, and this file builds
    /// with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — which would otherwise give even a
    /// struct of three `Double`s a main-actor conformance that cannot satisfy it.
    nonisolated struct Placement: Equatable, Sendable {
        let midX: Double
        let minY: Double
        let height: Double
    }

    struct Anchor: Equatable {
        let centreX: Double
        let top: Double
        let height: Double
        let screenX: Double
        let screenWidth: Double
        let screenTop: Double
    }

    func body(content: Content) -> some View {
        content
            // **`onGeometryChange`, not a `GeometryReader` writing `@State`.** The old shape
            // wrote state during every layout pass on every control with a tooltip, which is a
            // layout cycle — macOS 27 reported it as "laid out reentrantly … the current layout
            // pass will be skipped", and a skipped layout is a frame the editor does not draw.
            // See docs/design/what-macos-27-changed.md.
            // **Four `Double`s, not the rectangle.** D6 rule 5 is zero-permit in the app target:
            // no app source names a CoreGraphics geometry type at all, because a type that
            // crosses freely is how a coordinate space crosses with it unnoticed.
            .onGeometryChange(for: Placement.self) {
                Placement(midX: Double($0.frame(in: .global).midX),
                          minY: Double($0.frame(in: .global).minY),
                          height: Double($0.size.height))
            } action: { frame in
                // The transform runs during layout and writes nothing; the action runs after it
                // and is where the state moves. Skipped entirely unless the pointer is here,
                // because the only use of this value is placing a bubble about to appear.
                guard isHovering else { return }
                // **`.global` in SwiftUI is the WINDOW's space, not the screen's.** Clamping
                // window coordinates against screen coordinates only agrees while the window is
                // at the origin, which it is on the machine this was written on and nowhere
                // else. The window's own frame is what converts them.
                let origin = NSApp.keyWindow?.frame.origin ?? .zero
                let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0,
                                                                   width: 1e6, height: 1e6)
                anchor = Anchor(centreX: frame.midX + Double(origin.x),
                                top: frame.minY,
                                height: frame.height,
                                screenX: Double(visible.minX),
                                screenWidth: Double(visible.width),
                                screenTop: 0)
            }
            .onHover { hovering in
                isHovering = hovering
                guard hovering else { isShown = false; return }
                Task {
                    try? await Task.sleep(for: Self.delay)
                    // Re-read rather than capture: the pointer may have left during the wait,
                    // and a tooltip for a button nobody is pointing at is a tooltip in the way.
                    guard isHovering else { return }
                    isShown = true
                }
            }
            .overlay(alignment: .top) {
                if isShown, let anchor {
                    bubble
                        .offset(x: Self.shift(centreX: anchor.centreX,
                                              width: bubbleWidth,
                                              screenX: anchor.screenX,
                                              screenWidth: anchor.screenWidth),
                                // **Below when there is no room above.** The canvas bar is the
                                // top row of the window; a bubble drawn upward from it lands on
                                // the title bar or off the window entirely.
                                y: Self.placesBelow(top: anchor.top, windowTop: anchor.screenTop)
                                    ? anchor.height + 6
                                    : -28)
                        .allowsHitTesting(false)
                        // Above every sibling in the row, or the button to the right of this one
                        // draws over the bubble.
                        .zIndex(1)
                        .transition(.opacity)
                }
            }
    }

    @ViewBuilder private var bubble: some View {
        // **`.fixedSize()` AFTER the width cap, and without it the bubble is one character
        // wide.** An overlay is proposed its host's size, and the host here is a 24-point icon
        // button — so `maxWidth` capped a proposal that was already tiny and the text wrapped to
        // a vertical column of single letters. Reported as "why is it vertical", and it was.
        // `.fixedSize()` makes the frame ignore the proposal and take its own ideal width, which
        // the cap then limits; the text wraps against THAT, which is what a tooltip is.
        Text(text)
            .font(Type.detail)
            .foregroundStyle(Theme.Ink.primary)
            .lineLimit(3)
            .multilineTextAlignment(.center)
            .frame(maxWidth: Self.maximumWidth)
            .fixedSize()
            .padding(.horizontal, Space.snug)
            .padding(.vertical, Space.hairline)
            // Same reason as the anchor above: a width written from inside a layout pass is a
            // layout pass that can be asked to run again.
            .onGeometryChange(for: Double.self) { $0.size.width } action: { bubbleWidth = $0 }
            .background {
                RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
                    .fill(Theme.Surface.raised)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
                    .strokeBorder(Theme.Line.hairline, lineWidth: 1)
            }
    }

    /// How far to slide the bubble sideways so it stays on the screen.
    ///
    /// **Pure, and tested, because the failure is invisible in the place it happens.** The
    /// leftmost button in the toolbar is Undo and the rightmost is the timeline collapse; a
    /// bubble centred on either runs off the edge of the screen, where it is clipped rather
    /// than moved, and nobody notices while writing the code because the window is in the
    /// middle of a large display.
    ///
    /// Returns an offset from CENTRED, which is what `.overlay(alignment: .top)` gives.
    static func shift(centreX: Double, width: Double,
                      screenX: Double, screenWidth: Double) -> Double {
        let margin: Double = 8
        let leftEdge = centreX - width / 2
        let rightEdge = centreX + width / 2
        if leftEdge < screenX + margin { return screenX + margin - leftEdge }
        let limit = screenX + screenWidth - margin
        if rightEdge > limit { return limit - rightEdge }
        return 0
    }

    /// Whether the bubble goes under the control instead of over it.
    ///
    /// **The top row of the window has nothing above it.** A bubble drawn upward from the canvas
    /// bar lands on the title bar, where the window clips it — and clipping is silent.
    static func placesBelow(top: Double, windowTop: Double, room: Double = 32) -> Bool {
        top - windowTop < room
    }
}

extension View {
    /// The name of this control, shown on hover — including while it is disabled.
    ///
    /// Replaces `.help(_:)` on icon-only controls. `.help` is kept nowhere alongside it: two
    /// tooltips for one button, arriving 1.5 seconds apart, is worse than either.
    func tooltip(_ text: LocalizedStringKey) -> some View {
        modifier(Tooltip(text: text))
    }
}
