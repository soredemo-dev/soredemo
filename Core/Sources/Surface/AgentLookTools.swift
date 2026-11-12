import Foundation

// The look, the cursor and the sound, as the agent changes them: field by field, every field
// optional, each held to the range of the person's own control. Declared once (`ToolSpec`) and
// performed by the app through the same setters the inspector uses.

/// A change to the look. `nil` leaves a field as it is.
public struct LookChange: Equatable, Sendable {
    public var backgroundPreset: String?
    public var backgroundColor: String?
    public var backgroundImage: String?
    public var backgroundBlur: Double?
    public var padding: Double?
    public var cornerRadius: Double?
    public var shadow: Double?
    public var edge: Double?
    public var zoomAmount: Double?
    public var cameraPace: String?
    public var shape: String?

    public init(backgroundPreset: String? = nil, backgroundColor: String? = nil, backgroundImage: String? = nil,
                backgroundBlur: Double? = nil, padding: Double? = nil, cornerRadius: Double? = nil,
                shadow: Double? = nil, edge: Double? = nil, zoomAmount: Double? = nil,
                cameraPace: String? = nil, shape: String? = nil) {
        self.backgroundPreset = backgroundPreset
        self.backgroundColor = backgroundColor
        self.backgroundImage = backgroundImage
        self.backgroundBlur = backgroundBlur
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.edge = edge
        self.zoomAmount = zoomAmount
        self.cameraPace = cameraPace
        self.shape = shape
    }
}

/// A change to the drawn cursor and the keystroke badges.
public struct CursorChange: Equatable, Sendable {
    public var size: Double?
    public var clickEffect: String?
    public var clickSize: Double?
    public var clickOpacity: Double?
    public var color: String?
    public var hidesWhenIdle: Bool?
    public var hideAfter: Double?
    public var tilt: Double?
    public var movement: String?
    public var loopsToStart: Bool?
    public var showsKeystrokes: Bool?

    public init(size: Double? = nil, clickEffect: String? = nil, clickSize: Double? = nil,
                clickOpacity: Double? = nil, color: String? = nil, hidesWhenIdle: Bool? = nil,
                hideAfter: Double? = nil, tilt: Double? = nil, movement: String? = nil,
                loopsToStart: Bool? = nil, showsKeystrokes: Bool? = nil) {
        self.size = size
        self.clickEffect = clickEffect
        self.clickSize = clickSize
        self.clickOpacity = clickOpacity
        self.color = color
        self.hidesWhenIdle = hidesWhenIdle
        self.hideAfter = hideAfter
        self.tilt = tilt
        self.movement = movement
        self.loopsToStart = loopsToStart
        self.showsKeystrokes = showsKeystrokes
    }
}

/// A change to the sound: each source's level, mute, levelling, and the music bed.
public struct AudioChange: Equatable, Sendable {
    public var systemAudioGain: Double?
    public var microphoneGain: Double?
    public var systemAudioMuted: Bool?
    public var microphoneMuted: Bool?
    /// The loudness to level to, in LUFS. `levels == false` turns levelling off instead.
    public var targetLoudness: Double?
    public var levels: Bool?
    public var musicEnabled: Bool?
    public var musicDucks: Bool?

    public init(systemAudioGain: Double? = nil, microphoneGain: Double? = nil, systemAudioMuted: Bool? = nil,
                microphoneMuted: Bool? = nil, targetLoudness: Double? = nil, levels: Bool? = nil,
                musicEnabled: Bool? = nil, musicDucks: Bool? = nil) {
        self.systemAudioGain = systemAudioGain
        self.microphoneGain = microphoneGain
        self.systemAudioMuted = systemAudioMuted
        self.microphoneMuted = microphoneMuted
        self.targetLoudness = targetLoudness
        self.levels = levels
        self.musicEnabled = musicEnabled
        self.musicDucks = musicDucks
    }
}

extension AgentTools {
    public static let look = "look"
    public static let setLook = "set_look"
    public static let setCursor = "set_cursor"
    public static let setAudio = "set_audio"

    /// The option names the app's types use. **Surface cannot see those types** (Render and
    /// Framing's enums), so the app test `theAgentsOptionNamesAreTheAppsOwn` holds them equal.
    public static let clickEffects = ["ripple", "pulse", "none"]
    public static let movements = ["none", "rapid", "quick", "standard", "slow"]
    public static let cameraPaces = ["gentle", "standard", "snappy"]
    public static let shapes = ["Landscape", "Portrait", "Square", "Match Recording"]

    private static func optional(_ name: String, _ kind: ToolParameter.Kind, _ description: String) -> ToolParameter {
        ToolParameter(name, kind, description: description, required: false)
    }

    static let lookSpecs: [ToolSpec] = [
        ToolSpec(look, title: "The look, the cursor and the sound",
                 description: "Everything a person sets in the inspector, as it is now: the background (and the presets and images it can be), padding, corners, shadow, edge, the zoom amount and camera pace, the shape; the cursor and click effect; each audio source's level and mute, levelling, and the music bed. Read it before set_look, set_cursor or set_audio.",
                 readOnly: true),
        ToolSpec(setLook, title: "Change the look",
                 description: "Change any of the look's fields, as one undo step; fields not given stay. One background at most: a preset, a colour or an image named by look.",
                 readOnly: false, parameters: [
                    optional("backgroundPreset", .string(longest: 80, allowsEmpty: false), "A preset's name, from look."),
                    optional("backgroundColor", .color, "A solid colour, #RRGGBB."),
                    optional("backgroundImage", .string(longest: 200, allowsEmpty: false), "An image's name, from look's backgroundImages."),
                    optional("backgroundBlur", .number(minimum: 0, maximum: 1), "How much an image background is blurred."),
                    optional("padding", .number(minimum: 0, maximum: 0.3), "Space around the recording, as a fraction of the frame."),
                    optional("cornerRadius", .number(minimum: 0, maximum: 48), "The recording's corner radius, in points."),
                    optional("shadow", .number(minimum: 0, maximum: 1), "The shadow's opacity."),
                    optional("edge", .number(minimum: 0, maximum: 1), "The thin edge around the recording, its opacity."),
                    optional("zoomAmount", .number(minimum: 0, maximum: 2), "How far zooms go in; 1 is the default."),
                    optional("cameraPace", .choice(cameraPaces), "How fast the camera moves between framings."),
                    optional("shape", .choice(shapes), "The output's shape; look says which this recording offers."),
                    .reason]),
        ToolSpec(setCursor, title: "Change the cursor",
                 description: "Change the drawn cursor, the click effect and the keystroke badges, as one undo step; fields not given stay.",
                 readOnly: false, parameters: [
                    optional("size", .number(minimum: 0.5, maximum: 3), "The drawn cursor's size; 1 is the default."),
                    optional("clickEffect", .choice(clickEffects), "What a click draws."),
                    optional("clickSize", .number(minimum: 0.25, maximum: 3), "The click effect's size."),
                    optional("clickOpacity", .number(minimum: 0, maximum: 1), "The click effect's opacity."),
                    optional("color", .color, "The click effect's colour, #RRGGBB."),
                    optional("hidesWhenIdle", .boolean, "Fade the cursor out when it stops moving."),
                    optional("hideAfter", .number(minimum: 0.5, maximum: 10), "Seconds of stillness before it fades."),
                    optional("tilt", .number(minimum: 0, maximum: 1), "How much the cursor leans into its motion."),
                    optional("movement", .choice(movements), "How much the drawn cursor glides."),
                    optional("loopsToStart", .boolean, "Glide back to where it started at the end, for a looping video."),
                    optional("showsKeystrokes", .boolean, "Show the keys pressed as badges."),
                    .reason]),
        ToolSpec(setAudio, title: "Change the sound",
                 description: "Change each source's level and mute, levelling, and the music bed, as one undo step; fields not given stay. Gains are multipliers; 1 is as recorded.",
                 readOnly: false, parameters: [
                    optional("systemAudioGain", .number(minimum: 0, maximum: 4), "What the Mac played, as a multiplier."),
                    optional("microphoneGain", .number(minimum: 0, maximum: 4), "The voice, as a multiplier."),
                    optional("systemAudioMuted", .boolean, "Silence what the Mac played."),
                    optional("microphoneMuted", .boolean, "Silence the voice."),
                    optional("targetLoudness", .number(minimum: -30, maximum: -9), "Level every source to this loudness, in LUFS; -16 suits the web."),
                    optional("levels", .boolean, "false turns levelling off."),
                    optional("musicEnabled", .boolean, "Play the music bed, when the project has one."),
                    optional("musicDucks", .boolean, "Lower the music while somebody speaks."),
                    .reason]),
    ]

    /// The look tools' requests, or `nil` for a name that is not one of them.
    static func lookRequest(_ name: String, _ arguments: ToolArguments) -> Result<Request, MCPToolResultFailure>? {
        let reason = { arguments.string("reason") }
        switch name {
        case look:
            return .success(.look)
        case setLook:
            let change = LookChange(
                backgroundPreset: arguments.optionalString("backgroundPreset"),
                backgroundColor: arguments.optionalString("backgroundColor"),
                backgroundImage: arguments.optionalString("backgroundImage"),
                backgroundBlur: arguments.optionalNumber("backgroundBlur"),
                padding: arguments.optionalNumber("padding"),
                cornerRadius: arguments.optionalNumber("cornerRadius"),
                shadow: arguments.optionalNumber("shadow"),
                edge: arguments.optionalNumber("edge"),
                zoomAmount: arguments.optionalNumber("zoomAmount"),
                cameraPace: arguments.optionalString("cameraPace"),
                shape: arguments.optionalString("shape"))
            let backgrounds = [("backgroundPreset", change.backgroundPreset), ("backgroundColor", change.backgroundColor),
                               ("backgroundImage", change.backgroundImage)].filter { $0.1 != nil }.map(\.0).sorted()
            guard backgrounds.count <= 1 else {
                return .failure(.init("Give one background: `backgroundPreset`, `backgroundColor` or `backgroundImage` — this gave \(backgrounds.joined(separator: " and "))."))
            }
            guard change != LookChange() else { return .failure(nothingToChange(setLook)) }
            return .success(.setLook(change, reason: reason()))
        case setCursor:
            let change = CursorChange(
                size: arguments.optionalNumber("size"), clickEffect: arguments.optionalString("clickEffect"),
                clickSize: arguments.optionalNumber("clickSize"), clickOpacity: arguments.optionalNumber("clickOpacity"),
                color: arguments.optionalString("color"), hidesWhenIdle: arguments.optionalBool("hidesWhenIdle"),
                hideAfter: arguments.optionalNumber("hideAfter"), tilt: arguments.optionalNumber("tilt"),
                movement: arguments.optionalString("movement"), loopsToStart: arguments.optionalBool("loopsToStart"),
                showsKeystrokes: arguments.optionalBool("showsKeystrokes"))
            guard change != CursorChange() else { return .failure(nothingToChange(setCursor)) }
            return .success(.setCursor(change, reason: reason()))
        case setAudio:
            let change = AudioChange(
                systemAudioGain: arguments.optionalNumber("systemAudioGain"),
                microphoneGain: arguments.optionalNumber("microphoneGain"),
                systemAudioMuted: arguments.optionalBool("systemAudioMuted"),
                microphoneMuted: arguments.optionalBool("microphoneMuted"),
                targetLoudness: arguments.optionalNumber("targetLoudness"), levels: arguments.optionalBool("levels"),
                musicEnabled: arguments.optionalBool("musicEnabled"), musicDucks: arguments.optionalBool("musicDucks"))
            guard change != AudioChange() else { return .failure(nothingToChange(setAudio)) }
            return .success(.setAudio(change, reason: reason()))
        default:
            return nil
        }
    }

    /// Names the fields, so the model can correct the call rather than guess.
    private static func nothingToChange(_ tool: String) -> MCPToolResultFailure {
        let fields = lookSpecs.first { $0.name == tool }?.parameters.map(\.name).filter { $0 != "reason" } ?? []
        return .init("Nothing to change: give at least one of \(fields.joined(separator: ", ")).")
    }
}
