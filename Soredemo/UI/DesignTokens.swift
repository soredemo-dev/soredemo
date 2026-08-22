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
