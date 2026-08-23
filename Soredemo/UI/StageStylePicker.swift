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
        }
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

    /// `onEditingChanged` rather than the binding's setter: recomposing on every intermediate
    /// value of a drag would rebuild an `AVVideoComposition` per pixel of slider travel. The
    /// value updates live so the number moves under the thumb; the preview rebuilds on release.
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
