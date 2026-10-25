import Capture
import SwiftUI

/// How long to wait before the capture starts.
struct MenuBarCountdownRow: View {
    let preferences: RecordingPreferences

    var body: some View {
        let seconds = preferences.countdownSeconds
        MenuBarRow(icon: seconds == 0 ? "timer.square" : "timer", iconIsOff: seconds == 0,
                   title: "Countdown", value: seconds == 0 ? Text("Off") : Text("\(seconds)s")) {
            ForEach(RecordingPreferences.countdownChoices, id: \.self) { value in
                Button { preferences.countdownSeconds = value } label: {
                    Label { value == 0 ? Text("Off") : Text("\(value)s") } icon: {
                        Image(systemName: value == seconds ? "checkmark" : "")
                    }
                }
            }
        }
    }
}

/// One row of the panel: an icon, what it sets, its current value, and a menu. **Microphone,
/// camera and countdown all go through this**, so the three cannot drift into three shapes — the
/// way Frame rate and Countdown once came out different lengths
/// (`AppSourceAllowListTests.theMenuBarPanelHasOneSettingsRowShape`).
///
/// **A menu, not a `.menu` picker**, because the microphone's menu holds more than its choices
/// (Microphone Modes, system audio) and a picker cannot. **The value is text, not the accent**:
/// the accent marks the act — Record — and a setting's value is something to read.
struct MenuBarRow<Choices: View, Accessory: View>: View {
    let icon: String
    var iconIsOff = false
    let title: LocalizedStringKey
    let value: Text
    @ViewBuilder let choices: () -> Choices
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        Menu {
            choices()
        } label: {
            HStack(spacing: Space.snug) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(iconIsOff ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .frame(width: 16)
                Text(title).font(.system(size: 12))
                accessory()
                Spacer(minLength: Space.tight)
                value
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Space.regular)
            .frame(height: 30)
            .background(ConcentricRectangle(corners: .concentric(minimum: .fixed(Glass.controlRadius)),
                                            isUniform: true)
                .fill(.fill.quaternary))
            .contentShape(Rectangle())
        }
        // **`.button` with a plain button style, not `.borderlessButton`**: the borderless style
        // draws only a label's icon and title, which dropped the value, the chevrons and the
        // fill — measured on the running panel, and true of the old microphone row too.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .tint(Theme.Ink.primary)
    }
}

extension MenuBarRow where Accessory == EmptyView {
    init(icon: String, iconIsOff: Bool = false, title: LocalizedStringKey, value: Text,
         @ViewBuilder choices: @escaping () -> Choices) {
        self.init(icon: icon, iconIsOff: iconIsOff, title: title, value: value, choices: choices,
                  accessory: { EmptyView() })
    }
}
