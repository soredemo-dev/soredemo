import Foundation
import Project
import Timeline

/// **A click's ripple, as a pure function of when clicks happened and how long a ripple lasts.**
///
/// Deliberately a SEPARATE type from `PointerTrack`, not a fifth thing bolted onto it: a pointer
/// POSITION and a ripple PHASE answer two different questions — "where was the pointer" and "is a
/// click still animating" — from two different record streams (`PointerSample` versus
/// `ButtonEvent`), and `PointerTrack` already carries four reading cases, a blind-interval list and
/// an override list. A `ripplePhase` field folded into `PointerReading` would make `.drawn` two
/// things at once and would force every `.blind`/`.suppressedByReviewer`/`.noObservationYet` case
/// to say something about ripples it has no opinion on.
///
/// `StageCompositor` combines the two: it asks `PointerTrack` where the pointer is, asks this type
/// whether a ripple is in flight, and hands both into `StagePlanner.placement(for:in:ripplePhase:)`
/// — which is exactly what that function's `ripplePhase` parameter was already shaped to take.
public struct ClickTrack: Sendable {
    /// The moment of contact, which is when a ripple starts.
    private let downInstants: [HostInstant]      // sorted by hostTime
    /// The moment of release.
    ///
    /// **Kept since 2026-08-26, and the paragraph that used to say why it was not is worth
    /// keeping too.** It read: "`.up` events are not read… a ripple that started on release
    /// rather than on press would visibly lag a fast click-and-release, and nothing about 'the
    /// ripple marks where a click happened' needs the release edge at all." Every word of that
    /// is still true OF THE RIPPLE. It stopped being a reason to discard the events when this
    /// type was asked a second question: `pressScale(at:)` shrinks the cursor while a button is
    /// HELD, and holding is precisely the state that cannot be known from the press alone — a
    /// curve driven by the down edge would have to guess a duration, and a drag would spring
    /// back mid-drag while the button was still down.
    private let upInstants: [HostInstant]        // sorted by hostTime

    public init(events: [ButtonEvent]) {
        let sorted = events.sorted { $0.instant.hostTime.rawValue < $1.instant.hostTime.rawValue }
        self.downInstants = sorted.filter { $0.phase == .down }.map(\.instant)
        self.upInstants = sorted.filter { $0.phase == .up }.map(\.instant)
    }

    /// **A look-and-feel value, chosen by eye, not measured.** Unlike `NormalizedPoint` or
    /// `HostRange`, nothing about this number comes from a spec, a measurement or an existing
    /// convention — it is how long this app's own click ripple animates before it is spent, and a
    /// different number would still "work" in the sense that nothing downstream would misbehave.
    /// Do not read this as derived from anything; it is a constant because it has to be SOME fixed
    /// number, not because 400 ms is the answer to a question that was asked.
    public static let rippleDuration = Nanoseconds(400_000_000)

    /// The phase (`0...1`) of the most recent click's ripple that is still in flight at `time`, or
    /// `nil` if no click's ripple covers it — `0` at the click instant itself, rising toward `1` as
    /// `rippleDuration` is approached, `nil` again once it is reached or passed.
    ///
    /// **Overlapping clicks: the LATER click's ripple wins outright — not a blend, not the longer-
    /// running of the two.** If a second click lands while the first's ripple is still animating,
    /// this function reports the SECOND click's own phase, computed from the second click's own
    /// instant, from the moment the second click happens. The first click's ripple is not finished
    /// early and not visible again — it is simply not the one reported once a later click exists at
    /// or before `time`. This mirrors `PointerTrack.position(at:)`'s own rule ("the most recent
    /// sample at or before `time`"): the most recent click is authoritative, and nothing here
    /// interpolates or holds two ripples in superposition. A caller that wanted to draw two
    /// concurrent ripples would need a different type; this one draws the single ripple a person
    /// watching the frame would read as "the current click."
    /// `HostInstant` for the same reason as `PointerTrack.position(at:)`: the argument's type is
    /// what keeps a composition-relative number out of an absolute-clock comparison.
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
    /// **`1` where there is nothing to say**, never `nil`: this multiplies a size, and every
    /// frame has one. A `nil` would make every caller write the same `?? 1`.
    ///
    /// The epoch check is `ripplePhase`'s, for its reason: a click from another boot session's
    /// overlapping host times must not press this one's cursor.
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
