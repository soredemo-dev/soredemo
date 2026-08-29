import Foundation
import Project
import Timeline

/// A click's ripple and press scale, as pure functions of when the buttons went
/// down and up.
///
/// Deliberately a SEPARATE type from `PointerTrack`: a pointer position and a
/// ripple phase answer different questions from different record streams. See
/// `docs/design/how-the-drawn-cursor-behaves.md`.
///
/// `StageCompositor` combines the two — it asks `PointerTrack` where the pointer
/// is, asks this whether a ripple is in flight, and hands both into
/// `StagePlanner.placement(for:in:ripplePhase:)`.
public struct ClickTrack: Sendable {
    /// The moment of contact, which is when a ripple starts.
    private let downInstants: [HostInstant]      // sorted by hostTime
    /// The moment of release. Needed by `pressScale(at:)` and by nothing else —
    /// the ripple never wanted it, and the design doc records why keeping it
    /// stopped being a mistake.
    private let upInstants: [HostInstant]        // sorted by hostTime

    public init(events: [ButtonEvent]) {
        let sorted = events.sorted { $0.instant.hostTime.rawValue < $1.instant.hostTime.rawValue }
        self.downInstants = sorted.filter { $0.phase == .down }.map(\.instant)
        self.upInstants = sorted.filter { $0.phase == .up }.map(\.instant)
    }

    /// **A look-and-feel value, chosen by eye, not measured.** A constant because
    /// it has to be SOME fixed number, not because 400 ms answers a question that
    /// was asked.
    public static let rippleDuration = Nanoseconds(400_000_000)

    /// The phase (`0...1`) of the most recent click's ripple that is still in flight at `time`, or
    /// `nil` if no click's ripple covers it — `0` at the click instant itself, rising toward `1` as
    /// `rippleDuration` is approached, `nil` again once it is reached or passed.
    ///
    /// Overlapping clicks: the LATER click's ripple wins outright, mirroring
    /// `PointerTrack.position(at:)`'s "most recent at or before" rule. Nothing
    /// here holds two ripples in superposition.
    ///
    /// `HostInstant` for `PointerTrack.position(at:)`'s reason: the argument's
    /// type is what keeps a composition-relative number out of an absolute-clock
    /// comparison.
    public func ripplePhase(at instant: HostInstant) -> Double? {
        let time = instant.hostTime
        var latest: HostInstant?
        // Epoch first: a click from another boot session's overlapping host times
        // must not start a ripple in this one.
        for down in downInstants
        where down.epoch == instant.epoch && down.hostTime.rawValue <= time.rawValue {
            latest = down
        }
        guard let latest else { return nil }
        let elapsed = time.rawValue - latest.hostTime.rawValue
        let duration = Self.rippleDuration.rawValue
        guard elapsed < duration else { return nil }
        return Double(elapsed) / Double(duration)
    }

    /// How much smaller the drawn cursor is at `instant`, because a button is down or has just
    /// come up — see `CursorPress`, which owns the curve.
    ///
    /// **`1` where there is nothing to say**, never `nil`: this multiplies a
    /// size, and every frame has one.
    public func pressScale(at instant: HostInstant) -> Double {
        CursorPress.scale(sincePress: seconds(since: downInstants, at: instant),
                          sinceRelease: seconds(since: upInstants, at: instant))
    }

    /// Seconds from the latest instant at or before `instant`, or `nil` when there is none.
    private func seconds(since instants: [HostInstant], at instant: HostInstant) -> Double? {
        var latest: HostInstant?
        for edge in instants
        where edge.epoch == instant.epoch && edge.hostTime.rawValue <= instant.hostTime.rawValue {
            latest = edge
        }
        guard let latest else { return nil }
        return Double(instant.hostTime.rawValue - latest.hostTime.rawValue) / 1_000_000_000
    }
}
