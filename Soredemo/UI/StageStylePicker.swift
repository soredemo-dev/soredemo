import UniformTypeIdentifiers
import AppKit
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

    /// How the drawn cursor looks. **Held beside the stage's style rather than in its own
    /// model**, because they are the same decision from a person's side — "how should this
    /// video look" — and a second `@Observable` for six numbers would be a second thing to
    /// remember to publish and to restore.
    private(set) var cursor: CursorStyle = .default
    /// Whether pressed shortcuts are drawn as badges. Held here with the cursor for the same
    /// reason the cursor is held with the stage: one decision about how the video looks.
    private(set) var showsKeystrokes = true

    func setCursor(_ value: CursorStyle) {
        cursor = value
        publish()
    }

    func setShowsKeystrokes(_ value: Bool) {
        showsKeystrokes = value
        publish()
    }

    func restoreCursor(_ saved: CursorStyle) {
        cursor = saved
        publish()
    }

    /// The chosen picture's filename, or `nil` when the background is not an image.
    var imageBackgroundName: String? {
        if case .image(let filename) = style.background { return filename }
        return nil
    }

    init() { publish() }

    /// Copies `source` into the recording's package and makes it the background.
    ///
    /// **Copied, not referenced.** A background pointing at a file on the Desktop works until
    /// that file moves, is renamed, or the project is opened on another machine — and a
    /// wallpaper that silently becomes grey is worse than one never offered. The package already
    /// carries the media and the observation log; the picture travels the same way.
    ///
    /// Returns what went wrong, or `nil`. Reported rather than swallowed: a person who chose a
    /// picture and got no picture is owed the reason.
    @discardableResult
    func useImageBackground(_ source: URL, inPackageAt packageURL: URL) -> String? {
        let directory = packageURL.appending(path: StageBackground.imageDirectory,
                                             directoryHint: .isDirectory)
        // The chosen file's own name, made safe. Two pictures with the same name replace each
        // other, which is the behaviour a person expects of "choose an image" and costs nothing.
        let name = source.lastPathComponent
        guard StageBackground.isSafeImageFilename(name) else {
            return "\(name) is not a name this can use."
        }
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            let destination = directory.appending(path: name)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            return "Could not copy \(name) into the project: \(error)"
        }
        presetName = nil
        apply(background: .image(filename: name))
        return nil
    }

    func selectBackground(named name: String) {
        guard let preset = StageBackground.presets.first(where: { $0.name == name })
        else { return }
        presetName = name
        apply(background: preset.background)
    }

    func setInset(_ value: Double) { apply(insetFraction: value) }
    func setCornerRadius(_ value: Double) { apply(cornerRadius: value) }
    func setShadowOpacity(_ value: Double) { apply(shadowOpacity: value) }
    func setBorderOpacity(_ value: Double) { apply(borderOpacity: value) }

    /// One writer for the whole struct: `StageStyle` has a validating initialiser
    /// (`insetFraction` must be in [0, 0.5) or it traps), so every change goes through it
    /// exactly once rather than through four near-copies that each have to remember.
    private func apply(insetFraction: Double? = nil, cornerRadius: Double? = nil,
                       shadowOpacity: Double? = nil, background: StageBackground? = nil,
                       borderOpacity: Double? = nil) {
        style = StageStyle(
            // Clamped, not asserted: this comes from a slider, and a UI that can trap the
            // app by being dragged to its own maximum is a UI with a bug in it.
            insetFraction: min(max(insetFraction ?? style.insetFraction, 0), 0.45),
            cornerRadius: max(cornerRadius ?? style.cornerRadius, 0),
            shadowRadius: style.shadowRadius,
            shadowOpacity: min(max(shadowOpacity ?? style.shadowOpacity, 0), 1),
            background: background ?? style.background,
            borderOpacity: min(max(borderOpacity ?? style.borderOpacity, 0), 1))
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
        StageCompositor.cursorStyle = cursor
        StageCompositor.showsKeystrokes = showsKeystrokes
    }
}

/// The picker. Standard SwiftUI controls, which get Liquid Glass from the system.
struct StageStylePicker: View {
    let model: StageStyleModel
    /// Called after any change, so the host rebuilds the composition and the preview moves.
    let onChange: () -> Void
    /// The package the chosen picture is copied into. `nil` hides the image option rather than
    /// offering one that cannot work — a recording with nowhere to put the file.
    var packageURL: URL?

    @State private var imageFailure: String?

    var body: some View {
        Group {
            Picker("Background", selection: Binding(
                get: { model.presetName ?? "" },
                set: { model.selectBackground(named: $0); onChange() })
            ) {
                ForEach(StageBackground.presets, id: \.name) { preset in
                    Text(preset.name).tag(preset.name)
                }
                // The empty tag is what a hand-picked image selects, so the picker shows no
                // preset rather than showing the last one as if it were still in force.
                if model.presetName == nil {
                    Text(model.imageBackgroundName ?? "Custom").tag("")
                }
            }

            if let packageURL {
                WallpaperPicker(model: model, packageURL: packageURL, onChange: onChange)
                HStack(spacing: Space.snug) {
                    Button(model.imageBackgroundName == nil ? "Choose image\u{2026}"
                           : "Change image\u{2026}") {
                        guard let picked = Self.chooseImage() else { return }
                        imageFailure = model.useImageBackground(picked, inPackageAt: packageURL)
                        onChange()
                    }
                    if model.imageBackgroundName != nil {
                        Button("Remove") {
                            model.selectBackground(
                                named: StageBackground.presets.first?.name ?? "")
                            onChange()
                        }
                    }
                }
                .font(Type.detail)
                if let imageFailure {
                    Text(imageFailure).font(Type.detail).foregroundStyle(Signal.paused)
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
            // **Beside the shadow, because they do the same job at different places.** The
            // shadow separates the card from the background by darkening what is behind it,
            // which works everywhere except at the corners where the card's edge meets the
            // shadow's softest part. Off by default; over a pale background it does nothing and
            // the shadow is the control that works there.
            slider("Edge", value: model.style.borderOpacity, range: 0...1) {
                model.setBorderOpacity($0); onChange()
            }
        }
    }

    /// The cursor's own controls. **Both of these were fixed constants**, and every reference
    /// recorder makes them a choice: a Swift recorder has a `Cursor Scale`, an Electron recorder a click effect
    /// with a style, a size and an opacity. A cursor drawn at one size is right for one export
    /// size, and a ripple nobody can turn off is in the way of anyone recording a drawing app.
    @ViewBuilder var cursorControls: some View {
        slider("Cursor size", value: model.cursor.scale, range: 0.5...3) {
            model.setCursor(model.cursor.changing(scale: $0)); onChange()
        }
        // **Screen Studio's own four, plus off.** One hard-coded response was the defect and it
        // sat at the fastest value anybody ships — see `PointerPath.Tuning.Movement`, which
        // carries the measurement against a Rust recorder's. Changing this re-bakes the cursor's path, so
        // it takes effect on the next composition rather than on the next frame.
        Picker("Cursor movement", selection: Binding(
            get: { model.cursor.movement },
            set: { model.setCursor(model.cursor.changing(movement: $0)); onChange() })
        ) {
            ForEach(PointerPath.Tuning.Movement.allCases, id: \.self) { style in
                Text(LocalizedStringKey(style.displayName)).tag(style)
            }
        }
        Picker("Click effect", selection: Binding(
            get: { model.cursor.clickEffect },
            set: { model.setCursor(model.cursor.changing(clickEffect: $0)); onChange() })
        ) {
            ForEach(CursorStyle.ClickEffect.allCases, id: \.self) { effect in
                Text(effect.displayName).tag(effect)
            }
        }
        if model.cursor.clickEffect != .none {
            slider("Effect size", value: model.cursor.clickSize, range: 0.25...3) {
                model.setCursor(model.cursor.changing(clickSize: $0)); onChange()
            }
            slider("Effect opacity", value: model.cursor.clickOpacity, range: 0...1) {
                model.setCursor(model.cursor.changing(clickOpacity: $0)); onChange()
            }
        }
        // **Screen Studio's two cursor options every reference recorder also has.** Both
        // off by default — see `CursorStyle` — so a saved project looks as it did.
        Toggle("Hide cursor when idle", isOn: Binding(
            get: { model.cursor.hidesWhenIdle },
            set: { model.setCursor(model.cursor.changing(hidesWhenIdle: $0)); onChange() }))
            .font(Type.detail)
        if model.cursor.hidesWhenIdle {
            slider("Hide after (s)", value: model.cursor.idleDelay, range: 0.5...10) {
                model.setCursor(model.cursor.changing(idleDelay: $0)); onChange()
            }
        }
        slider("Tilt while moving", value: model.cursor.tilt, range: 0...1) {
            model.setCursor(model.cursor.changing(tilt: $0)); onChange()
        }
        // **For a video that plays on repeat.** The cursor glides back to where it began over
        // the last moments, so the seam between the last frame and the first is not a jump —
        // Screen Studio's "Loop cursor position". Off by default, like the two above it.
        Toggle("Return cursor to start for looping", isOn: Binding(
            get: { model.cursor.loopsToStart },
            set: { model.setCursor(model.cursor.changing(loopsToStart: $0)); onChange() }))
            .font(Type.detail)
        // **The badges the recorder has always captured for.** Only approved shortcuts are
        // ever recorded — never typing — so there is nothing here a person did not mean to show.
        Toggle("Show keyboard shortcuts", isOn: Binding(
            get: { model.showsKeystrokes },
            set: { model.setShowsKeystrokes($0); onChange() }))
            .font(Type.detail)
    }

    /// The open panel. Images only, and one at a time.
    @MainActor
    private static func chooseImage() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// A labelled slider whose preview moves with the thumb — see `LiveSlider`.
    @ViewBuilder private func slider(_ title: String, value: Double,
                                     range: ClosedRange<Double>,
                                     commit: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: Space.hairline) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f", value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(Type.detail)
            LiveSlider(value: value, range: range, commit: commit)
        }
    }
}

/// A slider that reports every value it passes through, so the preview moves with the thumb.
///
/// **It committed once on release, and the reason given for that was wrong.** The comment said
/// recomposing on every intermediate value would rebuild an `AVVideoComposition` per pixel of
/// slider travel. It would not: a style commit publishes `StageCompositor.style` and asks for a
/// redraw, and `StageWindow`'s own redraw task says so in as many words — "a style change does
/// not rebuild anything… what a PAUSED player needs is a reason to draw the frame it is already
/// showing, which a zero-distance seek is". Two comments in one codebase disagreeing about the
/// same cost, and the code was on the other one's side.
///
/// What it cost: dragging Padding or Corner radius on a paused preview moved the number and
/// nothing else until you let go.
///
/// **Kept as a type rather than inlined as a plain `Slider`.** The `live` state is still
/// carrying its weight — a slider bound straight through to a clamped model value fights the
/// thumb, because the model rounds or clamps and the binding reads back a different number than
/// the drag put in. This holds what the drag says and reports it onward.
private struct LiveSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let commit: (Double) -> Void
    @State private var live: Double?

    var body: some View {
        Slider(value: Binding(get: { live ?? value },
                              set: { live = $0; commit($0) }), in: range) { editing in
            // Released: hand the model back the authority it lends this view for the drag, so
            // the next `value` it publishes is what the slider shows.
            if !editing { live = nil }
        }
    }
}
