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
/// **Still not a smoothing control, and the reason changed on 2026-08-25.** This paragraph
/// used to say the pointer was a lerp with no drift to tune. It is a spring now
/// (`PointerPath`), with a phase lead that cancels the steady-state trail — so the drift the
/// knob would tune is compensated by construction, and the tuning lives in
/// `PointerPath.Tuning` beside the mechanism it tunes rather than in a style a person edits
/// per project. Screen Studio ships its equivalent as four presets ("Smooth / Medium / Rapid /
/// None", guide/animations); if a knob ever comes here, it is that picker, not a number.
///
/// **What did come: idle hiding and tilt**, the two Screen Studio cursor options every
/// reference recorder also has ("Auto-hide idle cursor", "Rotate cursor while moving";
/// a Rust recorder's `hide_when_idle`/`rotation_amount`, an Electron recorder's `cursorSway`). Both default OFF: a
/// cursor that vanishes or leans is a choice a person makes about their video, not a
/// default that changes what an existing project looks like when it is reopened.
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
    /// Fade the cursor out when it has not moved for `idleDelay`, and back in just before it
    /// moves again — see `PointerTrack.idleOpacity(at:hideAfter:)`.
    public let hidesWhenIdle: Bool
    /// Seconds of stillness before the fade begins, 0.5…10.
    public let idleDelay: Double
    /// How much the cursor leans into its own motion, 0…1 — `CursorTilt` turns it into degrees.
    public let tilt: Double
    /// **How much the drawn cursor glides**, as Screen Studio's own four choices plus off —
    /// see `PointerPath.Tuning.Movement`, which carries the measurement that made this a
    /// setting rather than a constant. The one place this file's header said would need "the
    /// drift added first": the drift is there now, and the knob is the picker rather than a
    /// number, for the same reason Screen Studio's is.
    public let movement: PointerPath.Tuning.Movement

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

    /// Two seconds: long enough that a pause to read does not blink the cursor away, short
    /// enough that a cursor parked while someone talks is gone before it distracts. a Rust recorder's
    /// default is the same order. **Uncalibrated.**
    public static let defaultIdleDelay: Double = 2.0

    public init(scale: Double, clickEffect: ClickEffect, clickOpacity: Double,
                clickSize: Double, red: Double, green: Double, blue: Double,
                hidesWhenIdle: Bool = false, idleDelay: Double = CursorStyle.defaultIdleDelay,
                tilt: Double = 0,
                movement: PointerPath.Tuning.Movement = .standard) {
        // Clamped rather than trapped: every one of these arrives from a slider AND from a
        // decoder, which is rule 8's case.
        self.scale = min(max(scale, 0.5), 3)
        self.clickEffect = clickEffect
        self.clickOpacity = min(max(clickOpacity, 0), 1)
        self.clickSize = min(max(clickSize, 0.25), 3)
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
        self.hidesWhenIdle = hidesWhenIdle
        self.idleDelay = idleDelay.isFinite ? min(max(idleDelay, 0.5), 10) : CursorStyle.defaultIdleDelay
        self.tilt = tilt.isFinite ? min(max(tilt, 0), 1) : 0
        self.movement = movement
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
                  blue: try container.decodeIfPresent(Double.self, forKey: .blue) ?? 1,
                  hidesWhenIdle: try container.decodeIfPresent(Bool.self, forKey: .hidesWhenIdle) ?? false,
                  idleDelay: try container.decodeIfPresent(Double.self, forKey: .idleDelay)
                      ?? CursorStyle.defaultIdleDelay,
                  tilt: try container.decodeIfPresent(Double.self, forKey: .tilt) ?? 0,
                  // Absent is "never chose", which is the current default — the same rule
                  // every other field in this decoder follows. A first draft decoded it as
                  // `rapid` to preserve how projects saved before the picker existed had
                  // looked; that is the producer-value rule misapplied, because a field
                  // nobody could set carries no authored value to protect, and it would
                  // have made `CursorStyle.default` un-decodable from an empty object.
                  movement: try container.decodeIfPresent(PointerPath.Tuning.Movement.self,
                                                          forKey: .movement) ?? .standard)
    }

    private enum CodingKeys: String, CodingKey {
        case scale, clickEffect, clickOpacity, clickSize, red, green, blue
        case hidesWhenIdle, idleDelay, tilt, movement
    }

    /// The same style with one field changed — the shape `TextOverlayStyle.changing` uses, for
    /// the same reason: a seven-argument initialiser repeated per slider is seven chances to
    /// pass `green` where `blue` belongs.
    public func changing(scale: Double? = nil, clickEffect: ClickEffect? = nil,
                         clickOpacity: Double? = nil, clickSize: Double? = nil,
                         red: Double? = nil, green: Double? = nil,
                         blue: Double? = nil, hidesWhenIdle: Bool? = nil,
                         idleDelay: Double? = nil, tilt: Double? = nil,
                         movement: PointerPath.Tuning.Movement? = nil) -> CursorStyle {
        CursorStyle(scale: scale ?? self.scale,
                    clickEffect: clickEffect ?? self.clickEffect,
                    clickOpacity: clickOpacity ?? self.clickOpacity,
                    clickSize: clickSize ?? self.clickSize,
                    red: red ?? self.red, green: green ?? self.green, blue: blue ?? self.blue,
                    hidesWhenIdle: hidesWhenIdle ?? self.hidesWhenIdle,
                    idleDelay: idleDelay ?? self.idleDelay,
                    tilt: tilt ?? self.tilt,
                    movement: movement ?? self.movement)
    }
}


/// **How far the cursor leans into its motion.** Screen Studio's "Rotate cursor while
/// moving"; an Electron recorder's `cursorSway.ts` is the formulation borrowed: the lean is the
/// horizontal speed as a share of a reference speed, clamped, times a maximum angle, so
/// a slow drift does not tilt and a flick tilts fully. a Rust recorder does the same from the
/// displacement over the last 0.4 s (`rendering/src/lib.rs:3234`), clamped at ±20°.
public enum CursorTilt {
    /// an Electron recorder's `CURSOR_SWAY_MAX_ROTATION`, π/18. **Uncalibrated.**
    public static let maximumDegrees: Double = 10
    /// an Electron recorder's `CURSOR_SWAY_SPEED_REFERENCE`: the horizontal speed, in output pixels per
    /// second, at which the lean is fully applied. **Uncalibrated.**
    public static let speedReferencePixelsPerSecond: Double = 1400

    /// Degrees, positive leaning to the right — the way a moving cursor's tip trails its
    /// body. `amount` is `CursorStyle.tilt`.
    public static func degrees(velocityXPixelsPerSecond velocity: Double, amount: Double) -> Double {
        guard amount > 0, velocity.isFinite else { return 0 }
        let share = min(max(velocity / speedReferencePixelsPerSecond, -1), 1)
        return share * maximumDegrees * min(max(amount, 0), 1)
    }
}
