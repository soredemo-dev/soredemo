import SwiftUI

/// The spacing scale, on an 8-point grid.
///
/// Named steps rather than numbers at each call site. Every panel in this app had
/// its own spacing — 2, 4, 6, 8 — chosen while writing that panel and never
/// compared against the one beside it, which is how a window ends up looking
/// assembled rather than designed. An 8-point grid is the conventional answer and
/// its steps are used as they are rather than re-invented.
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

    // MARK: the editor's bars — the toolbar, the canvas bar, the transport

    /// **Four roles for everything on the three bars, and nothing else.** They picked their own
    /// sizes — 10, 11, 12 and 13 points across seventeen places — and read as three different
    /// bars rather than one editor (reported 2026-09-28). `theEditorsBarsUseOnlyTheirTypeRoles`
    /// keeps a hard-coded size off them.
    /// A word on a bar: Crop, Guides, Edited, a speed.
    static let barLabel: Font = .system(size: 11, weight: .medium)
    /// A number on a bar — a timecode, a size, a span — in the same size, with digits that do not
    /// move as they count.
    static let barReadout: Font = .system(size: 11, weight: .medium).monospacedDigit()
    /// A bar button's glyph.
    static let barIcon: Font = .system(size: 12, weight: .medium)
    /// The one primary action's glyph — play and pause — a size up, on purpose.
    static let barPrimaryIcon: Font = .system(size: 14, weight: .medium)
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
/// An inspector wants `minWidth: 260, ideal: 280, max: 320` — narrow enough to
/// leave the preview room, wide enough that a slider and its readout fit on one line. Carried
/// over rather than re-guessed, since it is a measured answer to the same question.
enum InspectorWidth {
    static let minimum: Double = 260
    static let ideal: Double = 300
    /// **How far a person may drag it, set by the widest thing the inspector has to show.**
    ///
    /// That is a caption row, and it was measurably too narrow. `CaptionBuilder` breaks lines at
    /// 42 characters, and the line being edited is the one thing that must be readable whole —
    /// measured at the 13pt body font, a 42-character line is 263pt, beside a 35pt timecode, a
    /// 59pt reading-speed column and a 42pt fault label. With the spacing and the list's insets
    /// that is about 437pt of content, and 380 could not show it: the row this panel exists to
    /// edit was truncated at every width it could be dragged to.
    ///
    /// **The maximum only, not the ideal.** 300 is still what it opens at — this is how far it
    /// GOES, and a panel that opened wide would take the width from the picture for the sake of
    /// one tab.
    static let maximum: Double = 440
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
/// Built by hand everywhere else; here it is one modifier.
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
    /// How far below the surface the shadow sits. Named because the room it needs is not
    /// symmetrical: the offset takes the extent off the top and adds it to the bottom.
    static let shadowOffsetY: Double = 6

    /// **Transparent room a window must leave around a `glassSurface` for its own shadow.**
    ///
    /// A blurred shadow is drawn OUTSIDE the shape, and a window clips at its frame. The
    /// recording bar was a 400 x 52 panel with four points of padding around an eighteen-point
    /// blur, so the shadow was sliced off flat on all four sides: what showed was a hard-edged
    /// rectangle the size of the window, which is the one thing a soft shadow exists not to be.
    /// The window is now the bar plus this, and the bar is where it always was.
    static let shadowRoomSides: Double = shadowBlur
    static let shadowRoomTop: Double = shadowBlur - shadowOffsetY
    static let shadowRoomBottom: Double = shadowBlur + shadowOffsetY
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
                        radius: Glass.shadowBlur, y: Glass.shadowOffsetY)
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
