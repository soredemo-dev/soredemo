import Foundation
import Timeline

/// **A music bed under the recording: which file, how loud, and whether it gets out of the
/// way.**
///
/// **In `Overlays` beside `MusicDucking`, not in `Project`.** It is an authored value that is
/// persisted, like `CaptionTrack` and `TextTrack` which live here for the same reason — and it
/// carries `MusicDucking.Settings`, which `Project` cannot see: `Overlays` depends on `Render`
/// depends on `Project`, and an edge the other way would be a cycle.
///
/// **A filename, not a path** — `StageBackground.image`'s argument exactly. A bed pointing at a
/// file on the Desktop works until that file moves, is renamed, or the project is opened on
/// another machine, and music that silently becomes silence is worse than music never offered.
/// The chosen file is copied into `<package>/music/` when it is picked, so it travels with the
/// recording as the media and the observation log already do.
public struct MusicBed: Hashable, Sendable, Codable {
    /// The directory the file lives in, inside the package.
    public static let directory = "music"

    /// The file, by name. `nil` is "no music" — a state a person returns to by removing it,
    /// distinct from a bed at zero gain, which they can turn back up.
    public let filename: String?
    /// Whether it plays at all. Separate from `filename` for `AudioMix.muted`'s reason: a bed
    /// switched off keeps the level and the file it had.
    public let isEnabled: Bool
    /// How it behaves under narration.
    public let ducking: MusicDucking.Settings
    /// Whether it ducks at all. Off leaves it at `ducking.bedGain` throughout — which is what
    /// somebody laying music under a demo with no narration wants.
    public let ducks: Bool

    public static let none = MusicBed()

    public init(filename: String? = nil, isEnabled: Bool = true,
                ducking: MusicDucking.Settings = .default, ducks: Bool = true) {
        // A name is joined to a directory by whoever reads it; one carrying `../` would reach
        // outside the package. Refused here AND in the decoder — rule 8's case.
        self.filename = filename.flatMap { Self.isSafeFilename($0) ? $0 : nil }
        self.isEnabled = isEnabled
        self.ducking = ducking
        self.ducks = ducks
    }

    /// True when there is a file to play and it is switched on.
    public var isAudible: Bool { filename != nil && isEnabled }

    /// The same rule `StageBackground.isSafeImageFilename` applies, and for the same reason.
    public static func isSafeFilename(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\")
    }

    public func changing(filename: String?? = nil, isEnabled: Bool? = nil,
                         ducking: MusicDucking.Settings? = nil, ducks: Bool? = nil) -> MusicBed {
        MusicBed(filename: filename ?? self.filename,
                 isEnabled: isEnabled ?? self.isEnabled,
                 ducking: ducking ?? self.ducking,
                 ducks: ducks ?? self.ducks)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decodeIfPresent(String.self, forKey: .filename)
        if let name, !Self.isSafeFilename(name) {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "\"\(name)\" is not a filename this can join to a directory"))
        }
        self.init(filename: name,
                  isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
                  ducking: try container.decodeIfPresent(MusicDucking.Settings.self,
                                                         forKey: .ducking) ?? .default,
                  ducks: try container.decodeIfPresent(Bool.self, forKey: .ducks) ?? true)
    }

    private enum CodingKeys: String, CodingKey { case filename, isEnabled, ducking, ducks }
}
