import Foundation
import Framing
import Overlays
import Project
import Render
import Surface
import Variants

/// The look, the cursor and the sound, read and changed by the agent through the same setters the
/// inspector uses — so an agent can set nothing a person could not, and every clamp a slider has
/// applies to it too. Each change is one step named for the agent, revertible with its turn.
extension AgentEditorBridge {
    // MARK: - reads

    func lookReport() -> MCPToolResult {
        let look = editor.look
        let style = look.style, cursor = look.cursor
        return json([
            "background": EditorLook.describe(style.background),
            "backgroundPresets": StageBackground.presets.map(\.name),
            "backgroundImages": backgroundImages().map(\.name),
            "backgroundBlur": style.backgroundBlur, "padding": style.insetFraction,
            "cornerRadius": style.cornerRadius, "shadow": style.shadowOpacity, "edge": style.borderOpacity,
            "zoomAmount": look.zoomIntensity, "cameraPace": look.cameraPace.rawValue,
            "shape": look.variant.name, "shapes": availableShapes().map(\.name),
            "cursor": [
                "size": cursor.scale, "clickEffect": cursor.clickEffect.rawValue, "clickSize": cursor.clickSize,
                "clickOpacity": cursor.clickOpacity, "color": EditorLook.hex(cursor.red, cursor.green, cursor.blue),
                "hidesWhenIdle": cursor.hidesWhenIdle, "hideAfter": cursor.idleDelay, "tilt": cursor.tilt,
                "movement": cursor.movement.rawValue, "loopsToStart": cursor.loopsToStart,
            ] as [String: Any],
            "showsKeystrokes": look.showsKeystrokes,
            "audio": [
                "systemAudioGain": look.audioMix.gain(for: .systemAudio),
                "microphoneGain": look.audioMix.gain(for: .microphone),
                "systemAudioMuted": look.audioMix.muted.contains(.systemAudio),
                "microphoneMuted": look.audioMix.muted.contains(.microphone),
                "targetLoudness": look.audioMix.targetLoudness ?? NSNull(),
                "music": look.music.filename ?? NSNull(),
                "musicEnabled": look.music.isEnabled, "musicDucks": look.music.ducks,
            ] as [String: Any],
        ])
    }

    /// Pictures a background can be, by name: the project's own first, then the desktop the
    /// person has now, then the system's — the gallery's order and the gallery's sources.
    func backgroundImages() -> [(name: String, url: URL)] {
        var found: [(name: String, url: URL)] = []
        if let package = packageURL {
            let directory = package.appending(path: StageBackground.imageDirectory)
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            found += files.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { ($0.lastPathComponent, $0) }
        }
        for url in WallpaperGallery.currentDesktops() + WallpaperGallery.systemPictures()
        where !found.contains(where: { $0.name == url.lastPathComponent }) {
            found.append((url.lastPathComponent, url))
        }
        return found
    }

    private var packageURL: URL? { editor.mediaURL.map(ProjectStore.packageURL(forMediaAt:)) }

    private func availableShapes() -> [AspectVariant] {
        AspectVariant.available(recordingWidth: editor.recordingSize.width, recordingHeight: editor.recordingSize.height)
    }

    // MARK: - changes

    func setLook(_ change: LookChange, reason: String) -> MCPToolResult {
        recordLook(reason: reason) {
            let style = editor.stageStyle
            if let name = change.backgroundPreset {
                guard StageBackground.presets.contains(where: { $0.name == name }) else {
                    return "There is no preset \(name). The presets are: \(StageBackground.presets.map(\.name).joined(separator: ", "))."
                }
                style.selectBackground(named: name)
            }
            if let hex = change.backgroundColor, let rgb = EditorLook.components(hex) {
                style.useSolidBackground(red: rgb.red, green: rgb.green, blue: rgb.blue)
            }
            if let name = change.backgroundImage {
                guard let image = backgroundImages().first(where: { $0.name == name }) else {
                    return "There is no background image \(name). Read look for backgroundImages."
                }
                guard let packageURL else { return "This recording has no project to copy a picture into yet." }
                if let problem = style.useImageBackground(image.url, inPackageAt: packageURL) { return problem }
            }
            if let value = change.backgroundBlur { style.setBackgroundBlur(value) }
            if let value = change.padding { style.setInset(value) }
            if let value = change.cornerRadius { style.setCornerRadius(value) }
            if let value = change.shadow { style.setShadowOpacity(value) }
            if let value = change.edge { style.setBorderOpacity(value) }
            if let value = change.zoomAmount { editor.zoomIntensity = value }
            if let pace = change.cameraPace.flatMap(CameraPace.init(rawValue:)) { editor.cameraPace = pace }
            if let name = change.shape {
                guard let shape = availableShapes().first(where: { $0.name == name }) else {
                    return "This recording offers the shapes \(availableShapes().map(\.name).joined(separator: ", ")); \(name) is not one."
                }
                editor.variant = shape
                editor.chosenShapeDeliberately = true
            }
            return nil
        }
    }

    func setCursor(_ change: CursorChange, reason: String) -> MCPToolResult {
        recordLook(reason: reason) {
            let rgb = change.color.flatMap(EditorLook.components)
            let cursor = editor.stageStyle.cursor.changing(
                scale: change.size, clickEffect: change.clickEffect.flatMap(CursorStyle.ClickEffect.init(rawValue:)),
                clickOpacity: change.clickOpacity, clickSize: change.clickSize,
                red: rgb?.red, green: rgb?.green, blue: rgb?.blue,
                hidesWhenIdle: change.hidesWhenIdle, idleDelay: change.hideAfter, tilt: change.tilt,
                movement: change.movement.flatMap(PointerPath.Tuning.Movement.init(rawValue:)),
                loopsToStart: change.loopsToStart)
            editor.stageStyle.setCursor(cursor)
            if let shows = change.showsKeystrokes { editor.stageStyle.setShowsKeystrokes(shows) }
            return nil
        }
    }

    func setAudio(_ change: AudioChange, reason: String) -> MCPToolResult {
        recordLook(reason: reason) {
            var mix = editor.audioMix
            if let gain = change.systemAudioGain { mix = mix.setting(.systemAudio, gain: gain) }
            if let gain = change.microphoneGain { mix = mix.setting(.microphone, gain: gain) }
            if let muted = change.systemAudioMuted { mix = mix.setting(.systemAudio, muted: muted) }
            if let muted = change.microphoneMuted { mix = mix.setting(.microphone, muted: muted) }
            if change.levels == false { mix = mix.settingTargetLoudness(nil) }
            if let target = change.targetLoudness { mix = mix.settingTargetLoudness(target) }
            editor.audioMix = mix
            if change.musicEnabled != nil || change.musicDucks != nil {
                guard editor.music.filename != nil else {
                    return "This project has no music. A person chooses the music in the Look tab; it can then be turned on or ducked."
                }
                editor.music = editor.music.changing(isEnabled: change.musicEnabled, ducks: change.musicDucks)
            }
            return nil
        }
    }
}
