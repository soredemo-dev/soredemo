import AppKit
import SwiftUI

/// The four places this panel can send you: two openers, Settings, and Quit.
///
/// **Icon-only, because the words truncate and an icon cannot.** These were labelled links:
/// three to a row rendered as "Op…", "O…", "Set…", and two to a row still rendered as
/// "Open Proj… ⌘O". The panel is 292 points wide, the English labels with their shortcuts
/// fit at no arrangement of rows, and a shorter label was not available — these are the
/// names of the things they open. So the words move to `.help` and to an accessibility
/// label, both the full name; the shortcuts still work from the panel; and nothing here can
/// truncate in the next translation either, which the labelled version could not promise.
///
/// **No gear.** An earlier version put Settings and Permissions behind one. A `Menu` inside
/// a panel opens a system popup AppKit positions itself: it hangs outside the panel, covers
/// the controls beneath it, and near a display's right edge lands where there is room.
///
/// **Quit is last, the corner nothing is next to** — it used to sit beside Open Project,
/// one slip from the row a person actually came for.
struct MenuBarFooter: View {
    let coordinator: RecordingCoordinator

    var body: some View {
        HStack(spacing: Space.snug) {
            FooterButton(icon: "folder", title: "Open Project", shortcut: "\u{2318}O") {
                coordinator.openProject()
            }
            FooterButton(icon: "film", title: "Open Video",
                         shortcut: "\u{21E7}\u{2318}O") {
                coordinator.openVideoFromPanel()
            }
            Spacer()
            SettingsPanelLink()
            FooterButton(icon: "power", title: "Quit", shortcut: "\u{2318}Q") {
                NSApp.terminate(nil)
            }
        }
    }
}

/// One footer action, drawn as its symbol.
///
/// **The name is not dropped, it is moved.** `.help` puts it under the pointer and
/// `accessibilityLabel` puts it in VoiceOver; both carry the shortcut too, because a person
/// hovering to find out what a button does is exactly the person who would like to stop hovering.
private struct FooterIcon: View {
    let icon: String
    /// **A `LocalizedStringResource`, not a `LocalizedStringKey`.** The tooltip is the name AND
    /// the shortcut in one string, and a key cannot be resolved back into text to join to
    /// anything — `Text + Text` would do it and is deprecated. A resource goes to `Text` for the
    /// label and through `String(localized:)` for the tooltip, from one translated source.
    let title: LocalizedStringResource
    let shortcut: String
    let isHovering: Bool

    private var tooltip: String {
        let name = String(localized: title)
        return shortcut.isEmpty ? name : "\(name)  \(shortcut)"
    }

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 13))
            .frame(width: 26, height: 22)
            .foregroundStyle(isHovering ? .primary : .secondary)
            .background(isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            .help(Text(verbatim: tooltip))
            .accessibilityLabel(Text(title))
    }
}

private struct FooterButton: View {
    let icon: String
    let title: LocalizedStringResource
    let shortcut: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            FooterIcon(icon: icon, title: title, shortcut: shortcut, isHovering: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// The Settings row, which is a `SettingsLink` rather than a `FooterButton` with an action.
///
/// **`NSApp.sendAction(Selector("showSettingsWindow:"))` is what this was, and it is broken.**
/// That private selector has been the way to open a `Settings` scene since it existed; since
/// macOS 14 it logs `Please use SettingsLink for opening the Settings scene` at runtime —
/// observed on this app — and is documented as no longer working. `SettingsLink` is the
/// sanctioned replacement for the same job.
///
/// **The app is activated alongside it, and that is not decoration.** `SettingsLink` assumes
/// the app is already active with a window-management context; a `MenuBarExtra` app has neither
/// — it runs as an accessory, has no Dock icon, and is not "active" in the sense AppKit means.
/// The `simultaneousGesture` is meant to activate the app before the link's own action runs.
/// **That order is not measured** — the next paragraph says why it cannot be from here — and a
/// tap gesture ends on release, as the link's action does, so it is the claim to check first if
/// Settings ever opens behind another app.
///
/// **Not verified at runtime by the author of this change**, and worth saying: the menu bar
/// panel is not reachable by accessibility — measured 2026-08-25, which is why an earlier bug
/// in this file had to be found by reading — so there is no way to drive this row from a test
/// or a probe. What is established is that the old call was logging a warning that says it does
/// not work, and that this is the API Apple names in that warning.
private struct SettingsPanelLink: View {
    @State private var isHovering = false

    var body: some View {
        SettingsLink {
            FooterIcon(icon: "gearshape", title: "Settings", shortcut: "\u{2318},",
                       isHovering: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .simultaneousGesture(TapGesture().onEnded {
            NSApp.activate(ignoringOtherApps: true)
        })
    }
}
