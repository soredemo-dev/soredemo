import SwiftUI

/// The editor's colours, from `assets/tokens/colors.json` rather than from the system.
///
/// **The default SwiftUI palette is why this window looked like a settings pane.** `.tint`,
/// `.quaternary`, `.orange`, `.teal` — every one of those is Apple's, and a video editor built
/// out of them is a form with a picture in it. The brand already had a palette;
/// The shape below is the one for using
/// one, and this is that shape with our values in it.
///
/// **Dark, and not adaptive.** A video editor is dark by default, and the
/// reason is not fashion: chrome around a picture shifts how its colours read, and a light
/// surround makes a recording look darker and less saturated than it is. A person grading a
/// background gradient in a light window is judging it wrong. The menu bar panel stays adaptive
/// — it lives in the system's menu bar, where a dark panel in a light system is the thing that
/// looks broken.
enum Theme {
    // MARK: - the brand's own six

    static let ink = Color(red: 0x10 / 255, green: 0x11 / 255, blue: 0x14 / 255)
    static let background = Color(red: 0x1A / 255, green: 0x1A / 255, blue: 0x1D / 255)
    static let surface = Color(red: 0x2B / 255, green: 0x2B / 255, blue: 0x31 / 255)
    static let muted = Color(red: 0x8C / 255, green: 0x8C / 255, blue: 0x94 / 255)
    static let accent = Color(hue: Lane.videoHue / 360, saturation: Lane.saturation,
                              brightness: Lane.brightness)

    // MARK: - surfaces, darkest to lightest

    enum Surface {
        /// Behind everything — the window's own ground.
        static let base = Theme.ink
        /// A panel sitting on the base: the inspector, the timeline area.
        static let panel = Theme.background
        /// A control or a card on a panel.
        static let raised = Theme.surface
        /// The preview's own backdrop. Black rather than the brand's ink, because anything else
        /// is a colour cast on the thing being judged.
        static let preview = Color.black
    }

    enum Ink {
        static let primary = Color.white
        static let secondary = Theme.muted
        static let tertiary = Theme.muted.opacity(0.6)
    }

    enum Line {
        /// Between two surfaces of the same weight.
        static let hairline = Color.white.opacity(0.08)
        /// Between two areas doing different jobs.
        static let divider = Color.white.opacity(0.14)
    }

    /// A control's background as it is pointed at and pressed.
    enum Fill {
        static let rest = Color.white.opacity(0.05)
        static let hover = Color.white.opacity(0.10)
        static let pressed = Color.white.opacity(0.16)
        static let track = Color.white.opacity(0.07)
    }

    /// **One tint per track, all the same colour with the hue turned.**
    ///
    /// The accent is HSB(230°, 44%, 100%). Every lane below is that colour with its hue rotated
    /// and nothing else changed, so the five read as one family and stay equally bright — which
    /// is what `.orange`/`.teal`/`.purple` did not do: three of Apple's system colours side by
    /// side have three different brightnesses and belong to no palette.
    enum Lane {
        static let saturation: Double = 0.44
        static let brightness: Double = 1.0

        static let videoHue: Double = 230
        static let audioHue: Double = 150
        static let zoomHue: Double = 268
        static let textHue: Double = 38
        static let captionHue: Double = 190
        static let hideHue: Double = 320
        /// **Between the text lane's amber and the hide lane's magenta, and away from both.**
        /// An annotation is a mark a person made, like a title, but it is not text — and the two
        /// tracks are read side by side on the timeline, so they have to be tellable apart at a
        /// glance rather than by reading the label.
        static let markHue: Double = 8
        /// **Yellow-green, the widest gap left on the wheel** — 38 and 150 are its neighbours. A
        /// chapter flag sits on the ruler above every lane, so it must not read as any of them.
        static let chapterHue: Double = 94

        static func colour(_ hue: Double) -> Color {
            Color(hue: hue / 360, saturation: saturation, brightness: brightness)
        }

        static var video: Color { colour(videoHue) }
        static var audio: Color { colour(audioHue) }
        static var zoom: Color { colour(zoomHue) }
        static var text: Color { colour(textHue) }
        static var caption: Color { colour(captionHue) }
        static var hide: Color { colour(hideHue) }
        static var mark: Color { colour(markHue) }
        static var chapter: Color { colour(chapterHue) }
    }
}

extension View {
    /// A panel: the brand's background, a hairline edge, and the dark scheme pinned.
    func editorPanel() -> some View {
        background(Theme.Surface.panel)
            .environment(\.colorScheme, .dark)
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
