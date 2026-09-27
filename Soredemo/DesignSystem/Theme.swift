import SwiftUI

import AppKit

/// The app's colours, as SwiftUI sees them — each one the light or dark value from `Palette`,
/// chosen when it is drawn.
///
/// **The default SwiftUI palette is why this window once looked like a settings pane.** `.tint`,
/// `.quaternary`, `.orange`, `.teal` — every one of those is Apple's, and a video editor built out
/// of them is a form with a picture in it.
///
/// **Adaptive since 2026-09-27; it used to say "dark, and not adaptive".** The reason it gave is
/// still right and is still honoured — a light surround makes a recording look darker and less
/// saturated than it is — but it is about the picture's surround, so the preview's backdrop stays
/// black in both themes and the rest of the window follows the appearance. The panes that float
/// over a person's screen, and the notch, pin themselves dark. See
/// `docs/design/2026-09-27-light-and-dark.md`.
enum Theme {
    /// One colour with a value per theme, resolved against whatever appearance draws it — which
    /// includes a SwiftUI `.environment(\.colorScheme, .dark)` pin, measured.
    static func adaptive(_ pick: (Palette.Values) -> Palette.RGB,
                         opacity: Double = 1, lightOpacity: Double? = nil) -> Color {
        func ns(_ rgb: Palette.RGB, _ alpha: Double) -> NSColor {
            NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: alpha)
        }
        let dark = ns(pick(Palette.dark), opacity)
        let light = ns(pick(Palette.light), lightOpacity ?? opacity)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    /// A fill under a white label, and the colour of a selected control.
    static let accent = adaptive(\.accent)

    // MARK: - surfaces, back to front

    enum Surface {
        /// Behind everything — the window's own ground.
        static let base = adaptive(\.base)
        /// A panel sitting on the base: the inspector, the timeline area.
        static let panel = adaptive(\.panel)
        /// A control or a card on a panel.
        static let raised = adaptive(\.raised)
        /// The preview's own backdrop. **Black in both themes**: anything else is a colour cast on
        /// the thing being judged, and a light one makes it look darker than it is.
        static let preview = Color.black
    }

    enum Ink {
        static let primary = adaptive(\.primaryText)
        static let secondary = adaptive(\.secondaryText)
        /// Solid rather than `secondary` at 60 %: that was 2.44:1 on a raised surface.
        static let tertiary = adaptive(\.tertiaryText)
        /// A note that is not an error — a chapter moved past a cut, a cover over nothing.
        /// `.orange` was used, and is 2.2:1 on a light panel.
        static let caution = adaptive(\.caution)
        /// Text on a lane-coloured block: dark on the dark theme's light lanes, light on the
        /// light theme's dark ones.
        static let onLane = Color(nsColor: NSColor(name: nil) { appearance in
            let values = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? Palette.dark : Palette.light
            return NSColor(srgbRed: values.onLane.red, green: values.onLane.green,
                           blue: values.onLane.blue, alpha: values.onLaneOpacity)
        })
    }

    enum Line {
        /// Between two surfaces of the same weight.
        static let hairline = adaptive(\.line, opacity: 0.08)
        /// Between two areas doing different jobs.
        static let divider = adaptive(\.line, opacity: 0.14)
    }

    /// A control's background as it is pointed at and pressed.
    enum Fill {
        static let rest = adaptive(\.line, opacity: 0.05)
        static let hover = adaptive(\.line, opacity: 0.10)
        static let pressed = adaptive(\.line, opacity: 0.16)
        static let track = adaptive(\.line, opacity: 0.07)
    }

    /// **One tint per track, one family.** Every lane is the same OKLCH lightness and chroma with
    /// its hue turned, so the eight stay equally light — which HSB brightness, the first rule
    /// here, claimed and did not deliver. `Palette.Lane` holds the hues.
    enum Lane {
        static func colour(_ lane: Palette.Lane) -> Color { adaptive { $0.lane(lane) } }

        static let video = colour(.video)
        static let audio = colour(.audio)
        static let zoom = colour(.zoom)
        static let text = colour(.text)
        static let caption = colour(.caption)
        static let hide = colour(.hide)
        static let mark = colour(.mark)
        static let chapter = colour(.chapter)

        /// A zoom block's fill: 70 % on dark, 90 % on light. At 70 % the light theme's block put
        /// its white depth label at 3.56:1; at 90 % it is about 5.2 (measured, both composited
        /// over the track the block sits on).
        static let zoomBlock = adaptive({ $0.lane(.zoom) }, opacity: 0.7, lightOpacity: 0.9)
    }
}

extension View {
    /// A panel: the panel ground, in whichever theme is showing.
    func editorPanel() -> some View {
        background(Theme.Surface.panel)
    }
}

extension View {
    /// The inspector's list, with the system's own chrome taken off.
    ///
    /// **`.plain` rather than `.sidebar`.** The sidebar style paints a translucent vibrancy
    /// backdrop and its own selection colour — both of them the system's, both of them the
    /// reason the inspector still looked like System Settings after everything around it had
    /// been themed. Plain draws rows and nothing else, which leaves the panel's background
    /// showing through and the section headers to this file.
    func inspectorList() -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.Surface.panel)
            .environment(\.defaultMinListRowHeight, 26)
    }
}

/// One tab in the inspector's icon row.
struct InspectorTabButton: View {
    let tab: StageWindow.InspectorTab
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: tab.icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? tab.tint : Theme.Ink.secondary)
                .frame(width: 30, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? Theme.Fill.pressed
                              : (isHovering ? Theme.Fill.hover : .clear))
                }
                .overlay(alignment: .leading) {
                    // A bar on the selected section's edge, in its own lane's colour — the
                    // marker a sidebar row uses, which is what a rail is.
                    RoundedRectangle(cornerRadius: 1)
                        .fill(isSelected ? tab.tint : .clear)
                        .frame(width: 2, height: 16)
                        .offset(x: -5)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(LocalizedStringKey(tab.title))
        .accessibilityLabel(LocalizedStringKey(tab.title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
