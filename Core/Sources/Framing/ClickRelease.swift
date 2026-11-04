import Project
import Timeline

/// When a click was let go — what `FramingGate` measures a read against.
///
/// **One pairing, called by both readers of a log**: the compositor, which places the zooms, and
/// `FramingPlanReader`, which lists them for review. Two pairings could disagree about which `up`
/// ends a click, and then the zoom that plays and the reason the review gives would be about
/// different releases. See `docs/design/2026-11-04-a-read-is-stale-only-after-the-release.md`.
public enum ClickRelease {
    /// The first `up` of the same button after the click's own `down`, in the same boot epoch;
    /// `nil` when the log holds no such `down`, or no `up` follows it.
    ///
    /// The chain carries its click's instant and not its button, so the button is the one the
    /// `down` at that instant used — a right click is let go by a right `up`, even when a left
    /// one comes first.
    public static func instant(for chain: AXChainRecord, in events: [ButtonEvent]) -> HostInstant? {
        let down = chain.instant
        guard let button = events.first(where: { $0.phase == .down && $0.instant == down })?.button else {
            return nil
        }
        return events
            .filter { $0.phase == .up && $0.button == button && $0.instant.epoch == down.epoch
                && $0.instant.hostTime.rawValue >= down.hostTime.rawValue }
            .min { $0.instant.hostTime.rawValue < $1.instant.hostTime.rawValue }?
            .instant
    }
}
