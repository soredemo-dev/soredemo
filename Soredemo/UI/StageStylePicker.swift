import Compositing
import Foundation
import Observation
import Render
import SwiftUI

/// The stage's look, chosen by a person rather than compiled in.
///
/// **Why this exists.** `StageCompositor.style` was internal, with a comment saying no caller
/// outside that file set it — accurate, and the reason every recording came out the same
/// charcoal rectangle. A recorder that competes with Screen Studio or a Rust recorder on output is
/// judged on the frame around the capture as much as on the capture, and a fixed background
/// is the one part a person notices immediately.
///
/// Holds the style rather than mirroring it: `StageCompositor.style` is a static because
/// AVFoundation owns compositor instances, and a static is not observable. This is what
/// SwiftUI watches; `publish()` is the one place the two are connected.
@Observable
final class StageStyleModel {
    private(set) var style: StageStyle = .default
    /// Which preset the background came from, so the picker can show a selection rather than
    /// reverse-engineering one from colour values. `nil` after a knob is changed by hand.
    private(set) var presetName: String? = StageBackground.presets.first?.name

    init() { publish() }

    func selectBackground(named name: String) {
        guard let preset = StageBackground.presets.first(where: { $0.name == name })
        else { return }
        presetName = name
        apply(background: preset.background)
    }

    func setInset(_ value: Double) { apply(insetFraction: value) }
    func setCornerRadius(_ value: Double) { apply(cornerRadius: value) }
    func setShadowOpacity(_ value: Double) { apply(shadowOpacity: value) }

    /// One writer for the whole struct: `StageStyle` has a validating initialiser
    /// (`insetFraction` must be in [0, 0.5) or it traps), so every change goes through it
    /// exactly once rather than through four near-copies that each have to remember.
    private func apply(insetFraction: Double? = nil, cornerRadius: Double? = nil,
                       shadowOpacity: Double? = nil, background: StageBackground? = nil) {
        style = StageStyle(
            // Clamped, not asserted: this comes from a slider, and a UI that can trap the
            // app by being dragged to its own maximum is a UI with a bug in it.
            insetFraction: min(max(insetFraction ?? style.insetFraction, 0), 0.45),
            cornerRadius: max(cornerRadius ?? style.cornerRadius, 0),
            shadowRadius: style.shadowRadius,
            shadowOpacity: min(max(shadowOpacity ?? style.shadowOpacity, 0), 1),
            background: background ?? style.background)
        publish()
    }

    /// Applies a saved look. The preset name is recovered by matching the background against
    /// the shipped presets, so a project saved with one still shows it selected — and one saved
    /// with a hand-adjusted background shows none, which is true.
    func restore(_ saved: StageStyle) {
        style = saved
        presetName = StageBackground.presets.first { $0.background == saved.background }?.name
        publish()
    }

    private func publish() {
        StageCompositor.style = style
    }
}

/// The picker. Standard SwiftUI controls, which get Liquid Glass from the system.
struct StageStylePicker: View {
    let model: StageStyleModel
    /// Called after any change, so the host rebuilds the composition and the preview moves.
    let onChange: () -> Void

    var body: some View {
        Group {
            Picker("Background", selection: Binding(
                get: { model.presetName ?? "" },
                set: { model.selectBackground(named: $0); onChange() })
            ) {
                ForEach(StageBackground.presets, id: \.name) { preset in
                    Text(preset.name).tag(preset.name)
                }
            }

            slider("Padding", value: model.style.insetFraction, range: 0...0.3) {
                model.setInset($0); onChange()
            }
            slider("Corner radius", value: model.style.cornerRadius, range: 0...48) {
                model.setCornerRadius($0); onChange()
            }
            slider("Shadow", value: model.style.shadowOpacity, range: 0...1) {
                model.setShadowOpacity($0); onChange()
            }
        }
    }

    /// `onEditingChanged` rather than the binding's setter: recomposing on every intermediate
    /// value of a drag would rebuild an `AVVideoComposition` per pixel of slider travel. The
    /// value updates live so the number moves under the thumb; the preview rebuilds on release.
    @ViewBuilder private func slider(_ title: String, value: Double,
                                     range: ClosedRange<Double>,
                                     commit: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f", value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            SliderCommitOnRelease(value: value, range: range, commit: commit)
        }
    }
}

/// A slider that reports while dragging and commits once on release.
private struct SliderCommitOnRelease: View {
    let value: Double
    let range: ClosedRange<Double>
    let commit: (Double) -> Void
    @State private var live: Double?

    var body: some View {
        Slider(value: Binding(get: { live ?? value }, set: { live = $0 }), in: range) { editing in
            if !editing, let settled = live {
                commit(settled)
                live = nil
            }
        }
    }
}
