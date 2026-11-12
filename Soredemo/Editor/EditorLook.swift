import Compositing
import Foundation
import Framing
import Overlays
import Project
import Render
import Variants

/// Everything the inspector sets that is not an edit of time: the stage, the cursor, the keystroke
/// badges, the sound, the zoom amount and pace, and the shape.
///
/// **One value, so an agent's change to it can be taken back.** None of these were on an undo
/// stack, which was tolerable while only a person moved them, slider by slider. An agent changes
/// several at once, and "every act names who did it and the person can take it back" needs the
/// state before and after as a value to compare and restore — the same arrangement the captions
/// use (`CaptionsModel.Snapshot`).
struct EditorLook: Equatable {
    var style: StageStyle
    var cursor: CursorStyle
    var showsKeystrokes: Bool
    var audioMix: AudioMix
    var music: MusicBed
    var zoomIntensity: Double
    var cameraPace: CameraPace
    var variant: AspectVariant
}

extension EditorViewModel {
    var look: EditorLook {
        EditorLook(style: stageStyle.style, cursor: stageStyle.cursor, showsKeystrokes: stageStyle.showsKeystrokes,
                   audioMix: audioMix, music: music, zoomIntensity: zoomIntensity, cameraPace: cameraPace,
                   variant: variant)
    }

    /// Puts a look back, through the same restores a saved project uses.
    func restoreLook(_ look: EditorLook) {
        stageStyle.restore(look.style)
        stageStyle.restoreCursor(look.cursor)
        stageStyle.setShowsKeystrokes(look.showsKeystrokes)
        audioMix = look.audioMix
        music = look.music
        zoomIntensity = look.zoomIntensity
        cameraPace = look.cameraPace
        variant = look.variant
    }
}

extension EditorLook {
    /// One field that differs, as the agent and the turn's card read it.
    struct Difference: Equatable {
        let field: String
        let was: String
        let now: String
    }

    /// Every field that differs between two looks, named as the tools name them, in a fixed order.
    static func differences(_ a: EditorLook, _ b: EditorLook) -> [Difference] {
        var found: [Difference] = []
        func check<T: Equatable>(_ field: String, _ x: T, _ y: T, _ text: (T) -> String) {
            if x != y { found.append(Difference(field: field, was: text(x), now: text(y))) }
        }
        let number = { (value: Double) in String(format: "%g", value) }
        check("background", a.style.background, b.style.background, describe)
        check("backgroundBlur", a.style.backgroundBlur, b.style.backgroundBlur, number)
        check("padding", a.style.insetFraction, b.style.insetFraction, number)
        check("cornerRadius", a.style.cornerRadius, b.style.cornerRadius, number)
        check("shadow", a.style.shadowOpacity, b.style.shadowOpacity, number)
        check("edge", a.style.borderOpacity, b.style.borderOpacity, number)
        check("zoomAmount", a.zoomIntensity, b.zoomIntensity, number)
        check("cameraPace", a.cameraPace, b.cameraPace) { $0.rawValue }
        check("shape", a.variant, b.variant) { $0.name }
        check("cursor.size", a.cursor.scale, b.cursor.scale, number)
        check("cursor.clickEffect", a.cursor.clickEffect, b.cursor.clickEffect) { $0.rawValue }
        check("cursor.clickSize", a.cursor.clickSize, b.cursor.clickSize, number)
        check("cursor.clickOpacity", a.cursor.clickOpacity, b.cursor.clickOpacity, number)
        check("cursor.color", hex(a.cursor.red, a.cursor.green, a.cursor.blue),
              hex(b.cursor.red, b.cursor.green, b.cursor.blue)) { $0 }
        check("cursor.hidesWhenIdle", a.cursor.hidesWhenIdle, b.cursor.hidesWhenIdle) { "\($0)" }
        check("cursor.hideAfter", a.cursor.idleDelay, b.cursor.idleDelay, number)
        check("cursor.tilt", a.cursor.tilt, b.cursor.tilt, number)
        check("cursor.movement", a.cursor.movement, b.cursor.movement) { $0.rawValue }
        check("cursor.loopsToStart", a.cursor.loopsToStart, b.cursor.loopsToStart) { "\($0)" }
        check("showsKeystrokes", a.showsKeystrokes, b.showsKeystrokes) { "\($0)" }
        for source in AudioMix.Source.allCases {
            check("\(source.rawValue)Gain", a.audioMix.gain(for: source), b.audioMix.gain(for: source), number)
            check("\(source.rawValue)Muted", a.audioMix.muted.contains(source), b.audioMix.muted.contains(source)) { "\($0)" }
        }
        check("targetLoudness", a.audioMix.targetLoudness, b.audioMix.targetLoudness) { $0.map(number) ?? "off" }
        check("musicEnabled", a.music.isEnabled, b.music.isEnabled) { "\($0)" }
        check("musicDucks", a.music.ducks, b.music.ducks) { "\($0)" }
        return found
    }

    /// A background as a person would name it.
    static func describe(_ background: StageBackground) -> String {
        if let preset = StageBackground.presets.first(where: { $0.background == background }) { return "preset \(preset.name)" }
        switch background {
        case .solid(let red, let green, let blue): return "colour \(hex(red, green, blue))"
        case .linearGradient: return "a gradient"
        case .image(let filename): return "image \(filename)"
        case .transparent: return "transparent"
        }
    }

    static func hex(_ red: Double, _ green: Double, _ blue: Double) -> String {
        let byte = { (value: Double) in Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    /// `#RRGGBB` as three components. `nil` for anything else — the tool spec has already
    /// refused a malformed one, so `nil` here is a programming error a caller reports.
    static func components(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        guard hex.count == 7, hex.first == "#", let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }
}
