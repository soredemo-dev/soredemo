import Overlays
import Render
import SwiftUI

/// The named starting points, above every slider because that is the order a person works
/// in: pick the one closest, then move what is wrong with it.
///
/// **"Custom" is a real row, not a placeholder.** It is selected — and cannot be picked —
/// the moment a control moves the style off every preset, because a picker still naming
/// "Broadcast" after four sliders moved would be naming something that is not on the screen.
/// `CaptionStyle.matchingPreset` decides, on full equality.
struct CaptionPresetControls: View {
    let model: CaptionsModel
    let onChange: () -> Void

    /// The tag for the system-appearance entry. **Not a `CaptionStyle.presets` member**: those
    /// are fixed values in the package, and this one is read from the machine every time it is
    /// chosen — a person who changes their system captions and comes back should get the new
    /// ones, not a copy taken the first time.
    private static let systemPresetName = "\u{1}system"

    var body: some View {
        Picker("Preset", selection: Binding(
            get: { model.style.matchingPreset?.name },
            set: { name in
                if name == Self.systemPresetName {
                    model.setStyle(SystemCaptionAppearance.read().style())
                    onChange()
                    return
                }
                guard let preset = CaptionStyle.presets.first(where: { $0.name == name })
                else { return }
                model.setStyle(preset.style)
                onChange()
            })) {
            ForEach(CaptionStyle.presets, id: \.name) { preset in
                Text(LocalizedStringKey(preset.name)).tag(String?.some(preset.name))
            }
            // **The fifth preset is not a preset — it is what this Mac is already set to.**
            // Somebody who needs captions has tuned System Settings once for every app on the
            // machine; offering the four above and not that one asks them to make a decision
            // they already made. See `SystemCaptionAppearance`.
            Divider()
            Text("Match my system captions").tag(String?.some(Self.systemPresetName))
            // Only present while it is the answer, so the list is not permanently one row
            // longer for a state most recordings are never in.
            if model.style.matchingPreset == nil {
                Divider()
                Text("Custom").tag(String?.none)
            }
        }
        if let detail = model.style.matchingPreset?.detail {
            Text(LocalizedStringKey(detail)).font(Type.detail).foregroundStyle(.secondary)
        } else {
            Text("Edited from a preset. Picking one above replaces every value below.")
                .font(Type.detail).foregroundStyle(.secondary)
        }
    }
}
