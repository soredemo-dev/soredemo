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
/// charcoal rectangle. A recorder judged on its output is
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
            return String(localized: "\(name) is not a name this can use.")
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
            return String(localized: "Could not copy \(name) into the project: \(String(describing: error))")
        }
        presetName = nil
        apply(background: .image(filename: name))
        return nil
    }

    /// Nothing behind the card, so the export carries a hole rather than a colour.
    ///
    /// **Clears `presetName`**, like every other background that is not a shipped preset: the
    /// gallery shows a selection by name, and leaving a stale name on would draw a ring around
    /// a gradient nobody is looking at.
    func useTransparentBackground() {
        presetName = nil
        apply(background: .transparent)
    }

    /// Whether the stage currently has nothing behind it. Read by the export sheet, which has to
    /// narrow its codec list to the two that can carry it.
    var isTransparent: Bool { style.background == .transparent }

    func selectBackground(named name: String) {
        guard let preset = StageBackground.presets.first(where: { $0.name == name })
        else { return }
        presetName = name
        apply(background: preset.background)
    }

    /// How much the background PICTURE is blurred. Does nothing to a colour or a gradient — see
    /// `StageStyle.backgroundBlur`, which explains why that is arithmetic rather than a rule.
    func setBackgroundBlur(_ value: Double) { apply(backgroundBlur: value) }

    /// A background of one flat colour.
    ///
    /// **Clears `presetName` unless the colour IS a preset.** Two of the shipped presets are
    /// solid, and somebody who lands on one by dragging a colour well should see it selected
    /// rather than see the gallery claim nothing is chosen.
    func useSolidBackground(red: Double, green: Double, blue: Double) {
        let background = StageBackground.solid(red: red, green: green, blue: blue)
        presetName = StageBackground.presets.first { $0.background == background }?.name
        apply(background: background)
    }

    /// The background's colour when it is a flat one, for a colour well to show. `nil` for a
    /// gradient, a picture or nothing — a well showing grey for a photograph would be a control
    /// claiming to describe something it does not.
    var solidBackground: (red: Double, green: Double, blue: Double)? {
        guard case .solid(let red, let green, let blue) = style.background else { return nil }
        return (red, green, blue)
    }

    func setInset(_ value: Double) { apply(insetFraction: value) }
    func setCornerRadius(_ value: Double) { apply(cornerRadius: value) }
    func setShadowOpacity(_ value: Double) { apply(shadowOpacity: value) }
    func setBorderOpacity(_ value: Double) { apply(borderOpacity: value) }

    /// How far the card is turned. Two angles, one at a time, because a person adjusts one axis
    /// and looks — `StageTilt` clamps both, so a slider dragged to its own end cannot trap.
    func setTiltPitch(_ value: Double) {
        apply(tilt: StageTilt(pitch: value, yaw: style.tilt.yaw, distance: style.tilt.distance))
    }
    func setTiltYaw(_ value: Double) {
        apply(tilt: StageTilt(pitch: style.tilt.pitch, yaw: value, distance: style.tilt.distance))
    }
    /// Back to square on. Offered as its own control because returning two sliders to exactly
    /// zero by hand is a thing nobody manages.
    func setTiltFlat() { apply(tilt: .flat) }

    /// One writer for the whole struct: `StageStyle` has a validating initialiser
    /// (`insetFraction` must be in [0, 0.5) or it traps), so every change goes through it
    /// exactly once rather than through four near-copies that each have to remember.
    private func apply(insetFraction: Double? = nil, cornerRadius: Double? = nil,
                       shadowOpacity: Double? = nil, background: StageBackground? = nil,
                       borderOpacity: Double? = nil,
                       deviceModel: DeviceFrame.Model?? = nil,
                       deviceFinish: DeviceFrame.Finish? = nil,
                       backgroundBlur: Double? = nil,
                       tilt: StageTilt? = nil) {
        style = StageStyle(
            // Clamped, not asserted: this comes from a slider, and a UI that can trap the
            // app by being dragged to its own maximum is a UI with a bug in it.
            insetFraction: min(max(insetFraction ?? style.insetFraction, 0), 0.45),
            cornerRadius: max(cornerRadius ?? style.cornerRadius, 0),
            shadowRadius: style.shadowRadius,
            shadowOpacity: min(max(shadowOpacity ?? style.shadowOpacity, 0), 1),
            background: background ?? style.background,
            borderOpacity: min(max(borderOpacity ?? style.borderOpacity, 0), 1),
            // **Carried through, and every field added to `StageStyle` has to be.** This
            // function rebuilds the whole struct, so a field it does not mention is reset to a
            // default every time any slider moves — silently, and only for the person who had
            // set it. `everyStageStyleFieldSurvivesAChangeToAnother` is the check.
            //
            // A double optional: `nil` means "leave it", `.some(nil)` means "turn the frame
            // off". One optional could not say the second thing.
            deviceModel: deviceModel ?? style.deviceModel,
            deviceFinish: deviceFinish ?? style.deviceFinish,
            backgroundBlur: backgroundBlur ?? style.backgroundBlur,
            tilt: tilt ?? style.tilt)
        publish()
    }

    /// Which device body to draw, or `nil` for none.
    func setDeviceModel(_ value: DeviceFrame.Model?) { apply(deviceModel: .some(value)) }
    func setDeviceFinish(_ value: DeviceFrame.Finish) { apply(deviceFinish: value) }

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
                    Text(LocalizedStringKey(preset.name)).tag(preset.name)
                }
                // The empty tag is what a hand-picked image selects, so the picker shows no
                // preset rather than showing the last one as if it were still in force.
                if model.presetName == nil {
                    (model.imageBackgroundName.map { Text(verbatim: $0) } ?? Text("Custom")).tag("")
                }
            }

            if let packageURL {
                WallpaperPicker(model: model, packageURL: packageURL, onChange: onChange)
                HStack(spacing: Space.snug) {
                    Button {
                        guard let picked = Self.chooseImage() else { return }
                        imageFailure = model.useImageBackground(picked, inPackageAt: packageURL)
                        onChange()
                    } label: {
                        model.imageBackgroundName == nil ? Text("Choose image\u{2026}")
                            : Text("Change image\u{2026}")
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
                    Text(verbatim: imageFailure).font(Type.detail).foregroundStyle(Signal.paused)
                }
            }

            // **Above the padding, because it changes what everything below it applies to.**
            // With a body around the recording the corner radius belongs to the device rather
            // than to a slider, and the slider is hidden rather than left there doing nothing.
            Picker("Device", selection: Binding(
                get: { model.style.deviceModel },
                set: { model.setDeviceModel($0); onChange() })) {
                Text("None").tag(DeviceFrame.Model?.none)
                ForEach(DeviceFrame.Model.allCases, id: \.self) { device in
                    Text(LocalizedStringKey(device.displayName)).tag(DeviceFrame.Model?.some(device))
                }
            }
            .font(Type.detail)
            if model.style.deviceModel != nil {
                Picker("Finish", selection: Binding(
                    get: { model.style.deviceFinish },
                    set: { model.setDeviceFinish($0); onChange() })) {
                    ForEach(DeviceFrame.Finish.allCases, id: \.self) { finish in
                        Text(LocalizedStringKey(finish.displayName)).tag(finish)
                    }
                }
                .font(Type.detail)
            }
            slider("Padding", value: model.style.insetFraction, range: 0...0.3) {
                model.setInset($0); onChange()
            }
            // **Hidden while a device is drawn.** The screen's corners are the device's own
            // — `StagePlanner` uses the model's radius and ignores this one — so leaving the
            // slider there would be a control that moves and changes nothing.
            if model.style.deviceModel == nil {
                slider("Corner radius", value: model.style.cornerRadius, range: 0...48) {
                    model.setCornerRadius($0); onChange()
                }
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

            // **Two axes and a way back, and nothing else.** A tilt that ANIMATES is a different
            // feature — it needs a track, keyframes and a retiming story — and offering a third
            // slider for the viewing distance would be a lens control on a panel that has no
            // other lens controls. See `docs/design/2026-09-25-tilting-the-card.md`.
            slider("Lean", value: model.style.tilt.pitch,
                   range: -StageTilt.steepestAngle...StageTilt.steepestAngle) {
                model.setTiltPitch($0); onChange()
            }
            slider("Turn", value: model.style.tilt.yaw,
                   range: -StageTilt.steepestAngle...StageTilt.steepestAngle) {
                model.setTiltYaw($0); onChange()
            }
            // Only when there is something to undo: returning two sliders to exactly zero by
            // hand is a thing nobody manages, and a button that does nothing is noise.
            if !model.style.tilt.isFlat {
                Button("Flat") { model.setTiltFlat(); onChange() }
                    .buttonStyle(.link)
                    .font(Type.detail)
            }
        }
    }

    /// The cursor's own controls. **Both of these were fixed constants**, and every reference
    /// recorder makes them a choice — a cursor scale, a click effect
    /// with a style, a size and an opacity. A cursor drawn at one size is right for one export
    /// size, and a ripple nobody can turn off is in the way of anyone recording a drawing app.
    @ViewBuilder var cursorControls: some View {
        slider("Cursor size", value: model.cursor.scale, range: 0.5...3) {
            model.setCursor(model.cursor.changing(scale: $0)); onChange()
        }
        // **Four named amounts, plus off.** One hard-coded response was the defect and it
        // sat at the fastest value anybody ships — see `PointerPath.Tuning.Movement`, which
        // carries the measurement against a surveyed recorder's. Changing this re-bakes the cursor's path, so
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
                Text(LocalizedStringKey(effect.displayName)).tag(effect)
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
        // **The two cursor options worth having.** Both
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
        // Loops the cursor back to where it started. Off by default, like the two above it.
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
    @ViewBuilder private func slider(_ title: LocalizedStringKey, value: Double,
                                     range: ClosedRange<Double>,
                                     commit: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: Space.hairline) {
            HStack {
                Text(title)
                Spacer()
                Text(verbatim: String(format: "%.2f", value))
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
