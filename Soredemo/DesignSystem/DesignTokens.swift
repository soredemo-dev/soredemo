import SwiftUI

/// The spacing scale, on an 8-point grid.
///
/// **Named steps rather than numbers at each call site.** Every panel in this app had its own
/// spacing — 2, 4, 6, 8 — chosen while writing that panel and never compared against the one
/// beside it, which is how a window ends up looking assembled rather than designed.
/// `../opensource/Screen Record Opensource/a Swift recorder` has the same scale for the same
/// reason, and its values are carried over rather than re-invented.
///
/// **Not a `CGFloat` extension.** Rule 5 forbids this tier from naming a CoreGraphics geometry
/// type at all; `Double` is what SwiftUI's spacing arguments take anyway.
enum Space {
    /// 2 — inline detail: the grip lines inside a handle.
    static let hairline: Double = 2
    /// 4 — icon to label, the smallest gap that still reads as a gap.
    static let tight: Double = 4
    /// 8 — within one control group.
    static let snug: Double = 8
    /// 12 — between controls in a section.
    static let regular: Double = 12
    /// 16 — section padding.
    static let roomy: Double = 16
    /// 24 — between sections that are about different things.
    static let section: Double = 24
}

/// The type scale, named for what a piece of text IS rather than how big it is.
///
/// A call site asking for `.caption` has decided a size; one asking for `Type.detail` has
/// decided a role, and the size can change everywhere at once when the window gets denser.
enum Type {
    /// Section headers in the inspector.
    static let heading: Font = .headline
    /// A control's own label.
    static let label: Font = .callout
    /// Values, readouts, and the second line under a control.
    static let detail: Font = .caption
    /// Numbers that line up in a column. `monospacedDigit` so a readout does not jitter as it
    /// counts — a timecode that shifts under the cursor is unreadable while scrubbing.
    static let readout: Font = .caption.monospacedDigit()
}

/// Corner radii, so a card and a clip and a zoom block agree about how round things are here.
enum Radius {
    /// 3 — small blocks on a timeline.
    static let block: Double = 3
    /// 4 — clips and the strip itself.
    static let strip: Double = 4
    /// 8 — panels and cards.
    static let panel: Double = 8
}

/// The one place that decides how wide the inspector may be.
///
/// a Swift recorder pins its inspector to `minWidth: 260, ideal: 280, max: 320` — narrow enough to
/// leave the preview room, wide enough that a slider and its readout fit on one line. Carried
/// over rather than re-guessed, since it is a measured answer to the same question.
enum InspectorWidth {
    static let minimum: Double = 260
    static let ideal: Double = 300
    static let maximum: Double = 380
}

/// The floating recording bar's surface.
///
/// **Only the bar, since the menu bar panel stopped drawing its own.** That panel used to build
/// a glass card inside the system's popover, which had already drawn a rounded translucent
/// surface — two sets of corners and an inset that read as a mistake. It now fills the popover
/// and the system is the surface, which left `panelRadius` and `pressedOpacity` here with no
/// callers; they are gone rather than kept for a symmetry that no longer exists.
///
/// What is left is what a pane floating over a person's SCREEN needs: a dark blurred surface, a
/// radius large enough to read as an object rather than a window, a hairline light edge so it
/// separates from a bright desktop, and a shadow.
/// `../opensource/Screen Record Opensource/a Swift recorder`'s `CaptureToolbarPanel` builds exactly
/// this by hand; here it is one modifier.
enum Glass {
    /// The recording bar: a pill, because it is a control strip and not a container.
    static let barRadius: Double = 16
    /// A control inside one of those.
    static let controlRadius: Double = 8
    /// The edge. White at a low opacity rather than a grey stroke: it has to read against a
    /// bright desktop and a dark one, and only a light edge does both.
    static let edgeOpacity: Double = 0.12
    /// **Not named `shadowRadius`.** `theUnexercisedPublicAPITableMatchesTheTree` counts uses
    /// of `StageStyle.shadowRadius` by that bare substring, and a token here with the same name
    /// made the count read 4 where the table says 2 — a different API, counted as if it were
    /// that one.
    static let shadowBlur: Double = 18
    static let shadowOpacity: Double = 0.35
    /// A control's own background when hovered.
    static let hoverOpacity: Double = 0.10
}

extension View {
    /// The floating-surface treatment. **Pinned to dark**, whatever the system theme: these
    /// panes sit over a person's screen while they record it, and a light pane over a light
    /// desktop is a rectangle nobody can find.
    func glassSurface(radius: Double) -> some View {
        background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(.white.opacity(Glass.edgeOpacity), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(Glass.shadowOpacity),
                        radius: Glass.shadowBlur, y: 6)
        }
        .environment(\.colorScheme, .dark)
    }
}

/// What recording looks like. One red, used for one meaning.
///
/// **The accent is spent here and nowhere else.** A record button, the blinking dot and the stop
/// control are the only red things in this app; everything else is neutral, so red always means
/// "this is being captured".
enum Signal {
    static let record = Color(red: 0.98, green: 0.24, blue: 0.29)
    /// The level meter. Deliberately not red — a meter that shares a colour with the record
    /// state reads as a warning when it is only a measurement.
    static let level = Color(red: 0.35, green: 0.78, blue: 0.98)
    static let paused = Color(red: 0.98, green: 0.76, blue: 0.20)
}
