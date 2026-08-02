import Foundation
import Geometry
import Timeline

/// A pointer position sample. The whole track is kept, never thinned — how
/// dense is dense enough is a property of `cursor-render`'s spring, which will
/// be tuned, and a thinned track cannot be re-tuned (D2-7).
public struct PointerSample: Hashable, Codable, Sendable {
    public let kind: String
    public let instant: HostInstant
    public let position: NormalizedPoint
    public let revision: GeometryRevision

    public init(instant: HostInstant, position: NormalizedPoint, revision: GeometryRevision) {
        self.kind = "pointer"
        self.instant = instant
        self.position = position
        self.revision = revision
    }
}

public enum PointerButton: String, Codable, Sendable { case left, right, other }
public enum ButtonPhase: String, Codable, Sendable { case down, up }

/// A mouse button transition. The verb half of "click the Save button" — the
/// object half is the AX chain recorded against the same instant (D2-1).
public struct ButtonEvent: Hashable, Codable, Sendable {
    public let kind: String
    public let instant: HostInstant
    public let position: NormalizedPoint
    public let revision: GeometryRevision
    public let button: PointerButton
    public let phase: ButtonPhase

    public init(instant: HostInstant, position: NormalizedPoint, revision: GeometryRevision,
                button: PointerButton, phase: ButtonPhase) {
        self.kind = "button"
        self.instant = instant
        self.position = position
        self.revision = revision
        self.button = button
        self.phase = phase
    }
}

/// A keystroke, already filtered to approved shortcuts by the observer — the
/// package never sees an unfiltered keystroke, so there is nothing here to
/// redact later.
public struct KeySample: Hashable, Codable, Sendable {
    public let kind: String
    public let instant: HostInstant
    public let shortcut: String

    public init(instant: HostInstant, shortcut: String) {
        self.kind = "key"
        self.instant = instant
        self.shortcut = shortcut
    }
}
