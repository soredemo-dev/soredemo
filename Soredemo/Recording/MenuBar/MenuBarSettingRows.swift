import Capture
import SwiftUI

/// How often the capture may deliver a frame.
///
/// **Only rates some attached display can produce** (`DisplayRefreshRates`):
/// `minimumFrameInterval` is a ceiling and the panel is the floor, so offering 120 with only
/// 60 Hz displays attached would be offering a control that changes no observable thing.
struct MenuBarFrameRateRow: View {
    let preferences: RecordingPreferences

    var body: some View {
        MenuBarSettingRow(icon: "speedometer", title: "Frame rate",
                          selection: Binding(get: { preferences.frameRate },
                                             set: { preferences.frameRate = $0 })) {
            ForEach(CaptureFrameRate.available(forDisplayRates: DisplayRefreshRates.current),
                    id: \.self) {
                // A format key, not the name: the rate is the display's own (144, 240…), so no
                // table of fixed names can hold it, and French and Russian do not say "fps".
                Text("\($0.rawValue) fps").tag($0)
            }
        }
    }
}

/// How long to wait before the capture starts.
struct MenuBarCountdownRow: View {
    let preferences: RecordingPreferences

    var body: some View {
        MenuBarSettingRow(icon: preferences.countdownSeconds == 0 ? "timer.square" : "timer",
                          // Muted when it is off, so the row says so before the value is read.
                          iconIsMuted: preferences.countdownSeconds == 0,
                          title: "Countdown",
                          selection: Binding(get: { preferences.countdownSeconds },
                                             set: { preferences.countdownSeconds = $0 })) {
            ForEach(RecordingPreferences.countdownChoices, id: \.self) { value in
                (value == 0 ? Text("Off") : Text("\(value)s")).tag(value)
            }
        }
    }
}

/// One settings row: an icon, a label, and a popup on the right. Both rows go through this,
/// so the padding, the height, the corner radius and the popup width cannot disagree.
struct MenuBarSettingRow<Value: Hashable, Options: View>: View {
    let icon: String
    var iconIsMuted = false
    let title: LocalizedStringKey
    let selection: Binding<Value>
    @ViewBuilder let options: () -> Options

    /// **How wide the popup on a settings row is.** One number for both rows, because the two
    /// were built differently and did not line up: the countdown's was a `labelsHidden` picker
    /// pinned to 76 points, and the frame rate's was a `Picker(label:)` whose popup sized itself
    /// to its widest entry. Two shapes for one kind of row is how they came to be different
    /// lengths, and matching the numbers would have left the shapes free to drift again.
    ///
    /// Wide enough for the longest value either row offers — `120 fps` — so neither truncates.
    /// Computed, because a generic type cannot hold a static stored property.
    private static var pickerWidth: Double { 92 }

    var body: some View {
        HStack(spacing: Space.snug) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(iconIsMuted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .frame(width: 14)
            Text(title).font(.system(size: 12))
            Spacer(minLength: Space.tight)
            Picker("", selection: selection) { options() }
                .labelsHidden()
                .pickerStyle(.menu)
                // **These two values opt out of the accent, and the panel's one purple thing
                // stays the record button.** A `.menu` picker draws its selection in the tint,
                // and the panel is tinted — so "120 fps" and "3s" came out the same purple as
                // Start Recording, which made three things compete for the eye in a panel whose
                // whole job is to get out of the way. The accent marks the ACTION; a setting's
                // current value is text.
                .tint(.primary)
                .frame(width: Self.pickerWidth)
        }
        .padding(.horizontal, Space.regular)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: Glass.controlRadius, style: .continuous)
            .fill(.quaternary.opacity(0.5)))
    }
}
