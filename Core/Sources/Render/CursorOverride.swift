import Foundation
import Timeline

/// A reviewer's permanent decision to draw no pointer over a range.
///
/// First-class and stored with the project, like every other override. It exists because the one
/// thing the automatic path cannot know is whether the real screen showed a cursor: macOS hides
/// the pointer while the user types, keyboard events are deliberately not captured, so "the user
/// is typing" is absent from this app's data by design. Spike E measured that the hidden state is
/// not readable — `NSCursor.currentSystem` is identical hidden and visible, and both CG
/// cursor-visibility functions are unavailable at the 26.0 floor.
public struct CursorOverride: Hashable, Sendable {
    /// **The boot session `start` is measured in — and the reason this field exists.**
    ///
    /// `start` is an instant in the ABSOLUTE host clock, the domain every observation record is
    /// stamped in and the domain `PointerTrack.position(at:)` is queried in. Nothing about a bare
    /// `Nanoseconds` says so. `HostInstant` and `HostRange` — this project's other two persisted
    /// time types — both carry their epoch for exactly this reason; this type was the one that
    /// did not, and a reviewer UI writing `CursorOverride(start: Nanoseconds(3_200_000_000), …)`
    /// (the shape every unit test writes) would be a silent recurrence of `1a98402`, where a
    /// composition-relative number was compared against an absolute-clock track and matched
    /// nothing, on every frame, for a whole phase.
    ///
    /// **Added while zero files exist.** This type is `Codable` and has no writer: no `.soredemo`
    /// package on disk carries an override. That is the only window in which adding this field is
    /// not a migration — after the first file is written, old overrides would be permanently
    /// ambiguous about which clock they meant, with no way to decide retroactively.
    ///
    /// **The deferred behaviour arrived 2026-08-12**: `PointerTrack.position(at:)` now takes a
    /// `HostInstant` and compares this epoch before the interval, so an override recorded against
    /// another boot session no longer suppresses by host-time coincidence
    /// (`anOverrideFromAnotherEpochDoesNotSuppress`). The field is still required on decode rather
    /// than defaulted precisely so it cannot be quietly omitted: a file without it fails to decode
    /// instead of inheriting whatever the reader assumes.
    public let epoch: BootEpoch
    public let start: Nanoseconds
    public let duration: Nanoseconds

    public init(epoch: BootEpoch, start: Nanoseconds, duration: Nanoseconds) {
        precondition(duration.rawValue >= 0,
                     "CursorOverride duration must be non-negative, got \(duration.rawValue)")
        self.epoch = epoch
        self.start = start
        self.duration = duration
    }

    public func contains(_ time: Nanoseconds) -> Bool {
        time.rawValue >= start.rawValue && time.rawValue < start.rawValue + duration.rawValue
    }
}

extension CursorOverride: Codable {
    /// Matches the synthesised shape exactly — `epoch`, `start`, `duration` — so this hand-written
    /// conformance changes validation, not the wire form. Same rule-8 reason as
    /// `BlindInterval.init(from:)` above.
    private enum CodingKeys: String, CodingKey {
        case epoch, start, duration
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `decode`, not `decodeIfPresent`: see `epoch`'s own doc comment. A file that does not say
        // which clock its override is in is not a file this type can read.
        let epoch = try container.decode(BootEpoch.self, forKey: .epoch)
        let start = try container.decode(Nanoseconds.self, forKey: .start)
        let duration = try container.decode(Nanoseconds.self, forKey: .duration)
        guard duration.rawValue >= 0 else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "CursorOverride duration must be non-negative, got \(duration.rawValue)"))
        }
        self.epoch = epoch
        self.start = start
        self.duration = duration
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(epoch, forKey: .epoch)
        try container.encode(start, forKey: .start)
        try container.encode(duration, forKey: .duration)
    }
}


/// How the drawn cursor looks: how big, and what a click does.
///
/// **Every reference recorder makes both of these a choice, and we made neither.** a Swift recorder has
/// a `Cursor Scale` and a smoothing preset; an Electron recorder has a click effect with a style, a colour,
/// a size, a duration and an opacity. A cursor drawn at one fixed size is right for one export
/// size and one screen density, and a ripple nobody can turn off is a ripple in the way of
/// anyone recording a drawing app.
///
/// **Not a smoothing control, deliberately.** The obvious fifth field here is the one Screen
/// Studio is known for and complained about — a spring that makes the pointer drift behind the
/// real one. This recorder's pointer is linearly interpolated between real samples with three
/// refusals (`PointerTrack.smoothedPosition`) and never invents motion, so there is no drift to
/// tune away and no knob that would improve it. Adding one would mean adding the drift first.
public struct CursorStyle: Hashable, Codable, Sendable {
    /// A multiplier on the drawn cursor, 0.5…3. **The recording's own cursor is not resized** —
    /// this is the art this app draws, and making it larger is how a demo stays legible when it
    /// is watched in a 400-point embed.
    public let scale: Double
    /// What a click draws.
    public let clickEffect: ClickEffect
    /// The ring's opacity at its brightest.
    public let clickOpacity: Double
    /// The ring's final radius as a multiple of the default.
    public let clickSize: Double
    public let red: Double
    public let green: Double
    public let blue: Double

    public enum ClickEffect: String, Hashable, Codable, Sendable, CaseIterable {
        /// An expanding ring — what this app has always drawn.
        case ripple
        /// A filled disc that fades, which reads better on a busy screen than an outline.
        case pulse
        /// Nothing at all. The option a person recording a drawing app needs.
        case none

        public var displayName: String {
            switch self {
            case .ripple: "Ripple"
            case .pulse: "Pulse"
            case .none: "None"
            }
        }
    }

    public static let `default` = CursorStyle(
        scale: 1, clickEffect: .ripple, clickOpacity: 0.85, clickSize: 1,
        red: 1, green: 1, blue: 1)

    public init(scale: Double, clickEffect: ClickEffect, clickOpacity: Double,
                clickSize: Double, red: Double, green: Double, blue: Double) {
        // Clamped rather than trapped: every one of these arrives from a slider AND from a
        // decoder, which is rule 8's case.
        self.scale = min(max(scale, 0.5), 3)
        self.clickEffect = clickEffect
        self.clickOpacity = min(max(clickOpacity, 0), 1)
        self.clickSize = min(max(clickSize, 0.25), 3)
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(scale: try container.decodeIfPresent(Double.self, forKey: .scale) ?? 1,
                  clickEffect: try container.decodeIfPresent(ClickEffect.self,
                                                             forKey: .clickEffect) ?? .ripple,
                  clickOpacity: try container.decodeIfPresent(Double.self,
                                                              forKey: .clickOpacity) ?? 0.85,
                  clickSize: try container.decodeIfPresent(Double.self, forKey: .clickSize) ?? 1,
                  red: try container.decodeIfPresent(Double.self, forKey: .red) ?? 1,
                  green: try container.decodeIfPresent(Double.self, forKey: .green) ?? 1,
                  blue: try container.decodeIfPresent(Double.self, forKey: .blue) ?? 1)
    }

    private enum CodingKeys: String, CodingKey {
        case scale, clickEffect, clickOpacity, clickSize, red, green, blue
    }

    /// The same style with one field changed — the shape `TextOverlayStyle.changing` uses, for
    /// the same reason: a seven-argument initialiser repeated per slider is seven chances to
    /// pass `green` where `blue` belongs.
    public func changing(scale: Double? = nil, clickEffect: ClickEffect? = nil,
                         clickOpacity: Double? = nil, clickSize: Double? = nil,
                         red: Double? = nil, green: Double? = nil,
                         blue: Double? = nil) -> CursorStyle {
        CursorStyle(scale: scale ?? self.scale,
                    clickEffect: clickEffect ?? self.clickEffect,
                    clickOpacity: clickOpacity ?? self.clickOpacity,
                    clickSize: clickSize ?? self.clickSize,
                    red: red ?? self.red, green: green ?? self.green, blue: blue ?? self.blue)
    }
}
