import AppKit
import MediaAccessibility
import Render

/// The caption appearance this person already chose, in System Settings.
///
/// **Somebody who needs captions has already set this up.** macOS carries a full caption
/// appearance under Accessibility — size, colours, opacity, edge style, corner radius — and a
/// person who relies on captions has tuned it once for every app on the machine. Soredemo
/// shipped four presets and none of them was "the one I already use", which is the only preset
/// that requires no decision from the person it is for.
///
/// **The read and the conversion are separate, and only the read touches the system.**
/// `read()` is the one ambient call; `style(matching:)` is arithmetic over plain numbers and is
/// tested without a Mac's settings being anything in particular. That split is the reason this
/// is two functions rather than one — the same reason `Minting` exists.
struct SystemCaptionAppearance: Equatable {
    /// How much larger or smaller than normal, as a multiplier. 1 is the system default.
    let textScale: Double
    let red: Double
    let green: Double
    let blue: Double
    let textOpacity: Double
    /// The plate behind the text. **`window`, not `background`** — macOS has both: the
    /// background is behind each LINE, the window is behind the whole block. Soredemo draws one
    /// plate, so the window's opacity is the one that corresponds to it.
    let plateOpacity: Double
    let plateCornerFraction: Double
    /// Whether the person asked for an outline rather than a plate.
    let prefersEdge: Bool

    /// Reads what System Settings holds. **The only impure function here.**
    ///
    /// `kMACaptionAppearanceDomainUser` rather than `Default`: the default domain is what Apple
    /// ships, and offering somebody their own settings means the ones they changed.
    @MainActor static func read() -> SystemCaptionAppearance {
        let domain = MACaptionAppearanceDomain.user
        let scale = Double(MACaptionAppearanceGetRelativeCharacterSize(domain, nil))
        let foreground = MACaptionAppearanceCopyForegroundColor(domain, nil).takeRetainedValue()
        let components = foreground.components ?? [1, 1, 1, 1]
        let edge = MACaptionAppearanceGetTextEdgeStyle(domain, nil)
        return SystemCaptionAppearance(
            // A scale of zero would collapse the type; the system reports 1 when unset, and
            // this is the floor for a setting that arrives wrong rather than absent.
            textScale: scale > 0 ? scale : 1,
            red: components.count > 0 ? Double(components[0]) : 1,
            green: components.count > 1 ? Double(components[1]) : 1,
            blue: components.count > 2 ? Double(components[2]) : 1,
            textOpacity: Double(MACaptionAppearanceGetForegroundOpacity(domain, nil)),
            plateOpacity: Double(MACaptionAppearanceGetWindowOpacity(domain, nil)),
            plateCornerFraction:
                Double(MACaptionAppearanceGetWindowRoundedCornerRadius(domain, nil)) / 100,
            prefersEdge: edge != .none && edge != .undefined)
    }

    /// The caption style that matches this appearance.
    ///
    /// **Pure.** The system speaks in absolute points and per-line colours; `CaptionStyle`
    /// speaks in fractions of the output height, because a caption has to hold its size when
    /// the same project is exported at 1080p and at 4K. This is the conversion between the two
    /// vocabularies, and it is the part worth testing.
    func style(basedOn base: CaptionStyle = .default) -> CaptionStyle {
        // The system's scale multiplies the DEFAULT height. Clamped, because a caption at three
        // times the default covers a third of the frame and a person moving a system-wide
        // slider is not making a decision about this app's output.
        let height = min(max(base.heightFraction * textScale, 0.02), 0.12)
        return CaptionStyle(
            heightFraction: height,
            bottomInsetFraction: base.bottomInsetFraction,
            maximumWidthFraction: base.maximumWidthFraction,
            // An outline and a plate are alternatives, not a stack: somebody who asked for an
            // edge asked not to have the picture covered.
            backgroundOpacity: prefersEdge ? 0 : plateOpacity,
            backgroundCornerFraction: plateCornerFraction > 0 ? plateCornerFraction
                                                              : base.backgroundCornerFraction,
            red: red, green: green, blue: blue,
            highlightsSpokenWord: base.highlightsSpokenWord,
            unspokenOpacity: base.unspokenOpacity,
            alignment: base.alignment,
            horizontalFraction: base.horizontalFraction,
            isBold: prefersEdge ? true : base.isBold,
            shadowOpacity: prefersEdge ? 0.7 : base.shadowOpacity,
            outlineWidthFraction: prefersEdge ? 0.08 : 0,
            outlineRed: 0, outlineGreen: 0, outlineBlue: 0)
    }
}
