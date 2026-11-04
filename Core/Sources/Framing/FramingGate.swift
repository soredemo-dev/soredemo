import Foundation
import Geometry
import Project
import Timeline

/// Why a click produced no zoom target. **A value, never a `nil`** — the ROADMAP's own
/// requirement is that every rejection names its reason, `review-ui` shows which gate
/// fired, and an optional would erase that reason at the moment it was computed.
///
/// `String`-raw and `Codable` because these persist alongside the derivation that refused;
/// renaming a case is a wire-breaking change.
public enum FramingRejection: String, Codable, Hashable, Sendable, CaseIterable {
    /// AX had no element at the click at all.
    case hitTestReturnedNothing
    /// The click was on one of the recorder's own windows — the recording bar's Stop, most
    /// often. Not part of the demo, and the one refusal the pointer fallback must never cover:
    /// falling back here put a zoom on the last 0.4 s of every recording stopped from the bar.
    case overOwnWindow
    /// An element answered, without geometry. Distinct from a BAD frame: nothing was
    /// measured, so nothing can be judged degenerate or offscreen.
    case noFrameRecorded
    /// The read ended after the click was let go, so what it reported may be what the click's
    /// action put there. See `docs/design/2026-11-04-a-read-is-stale-only-after-the-release.md`.
    case staleObservation
    /// The log has no release for this click — the take ended with the button held, or the
    /// release fell where nothing was observed — so whether the read was in time is unknown.
    case releaseNotObserved
    /// The frame and the click are in different geometry revisions — two coordinate
    /// systems, and comparing them is the `1a98402` family one domain over.
    case notComparable
    /// A coordinate fault: the element AX returned is not where the user clicked.
    case doesNotContainTheClick
    /// Zero or negative extent — nothing to zoom to.
    case degenerateRectangle
    /// The frame leaves the recording, so framing it would zoom to empty space.
    case partlyOffscreen
    /// **A pane is not a control.** Past `maxTargetArea` a zoom is a no-op that reads as
    /// a bug.
    case tooLarge
    /// The chain was CUT and the chosen element is the outermost one recorded, so it is
    /// indistinguishable on disk from one genuinely outermost (Phase 2's F2-3, measured at
    /// 7–8% of clicks — a normal path, not an edge case). Refusal is the honest answer.
    case bestCandidateOnTheTruncationBoundary
}

/// A rectangle to zoom to, and which element it came from.
public struct FramingTarget: Hashable, Sendable {
    public let frame: NormalizedFrame
    /// The AX role of the framed element, for a reviewer reading a rejection-free decision
    /// and asking "what did it pick". Never the title: `ObservationLog`'s content rule bans
    /// another application's window titles, and this value travels with the derivation.
    public let role: String?

    public init(frame: NormalizedFrame, role: String?) {
        self.frame = frame
        self.role = role
    }
}

/// The outcome of framing one click: a target, or a named reason there is none.
public enum FramingDecision: Hashable, Sendable {
    case framed(FramingTarget)
    case rejected(FramingRejection)

    /// `nil` when framed — the spelling every test and caller uses to ask "which gate".
    public var rejection: FramingRejection? {
        if case .rejected(let reason) = self { return reason }
        return nil
    }
}

/// Turns one `AXChainRecord` into a zoom target or a named refusal.
///
/// **Pure, and deliberately not a producer.** `framing-targets`' ROADMAP row also covers
/// writing a `Derived` with provenance, which needs `observation-ingest` and a real
/// `derivation-graph`; this type is the choosing half, so the graph work later wraps
/// provenance around a function that already has its own tests. See
/// `docs/design/2026-08-19-framing-gates.md`.
///
/// **No pointer fallback here.** A function that silently substituted the pointer would
/// erase the reason it just computed; the caller asks for the fallback having seen it.
public enum FramingGate {
    /// The share of the screen past which a target is a pane rather than a control.
    /// **Uncalibrated**, same as above: 0.5 is a starting point, not a finding.
    public static let maxTargetArea: Double = 0.5

    /// Gates in a FIXED order, first match wins. The order is a claim about which
    /// explanation is more useful to a person, not an implementation accident: without it
    /// the reported reason would vary with evaluation order and `review-ui` could show a
    /// different cause for the same recording between builds
    /// (`theEarliestApplicableGateIsTheReportedReason`).
    ///
    /// `release` is when the click was let go — `ClickRelease.instant(for:in:)`, from the same
    /// log — and is what gate 3 measures the read against.
    public static func decide(for record: AXChainRecord, releasedAt release: HostInstant?) -> FramingDecision {
        // Before the missing-hit guard, because a click on our own window has no hit too — and
        // reporting it as `.hitTestReturnedNothing` is what let the fallback zoom to it.
        if record.truncation == .overOwnWindow { return .rejected(.overOwnWindow) }
        guard let hit = record.hit else { return .rejected(.hitTestReturnedNothing) }
        guard let frame = hit.frame else { return .rejected(.noFrameRecorded) }

        // **Stale means read after the release, not read slowly.** Until the button comes up the
        // click has activated nothing, so a 36 ms read that ends before it describes what was
        // pressed; a fast one that ends after it may not. The read ends with the later of the
        // hit-test and the hit element's own read, where the frame comes from.
        guard let release, release.epoch == record.hitTestInterval.epoch else {
            return .rejected(.releaseNotObserved)
        }
        let readEnd = max(record.hitTestInterval.start.rawValue + record.hitTestInterval.duration.rawValue,
                          hit.readInterval.start.rawValue + hit.readInterval.duration.rawValue)
        if readEnd > release.hostTime.rawValue {
            return .rejected(.staleObservation)
        }
        // Containment is `AXChainRecord`'s own computation, so the revision check and the
        // inside-test are not restated here — one owner for one rule.
        switch record.clickContainment {
        case .notComparable: return .rejected(.notComparable)
        case .doesNotContainTheClick: return .rejected(.doesNotContainTheClick)
        case .noHitElement: return .rejected(.hitTestReturnedNothing)
        case .noFrameRecorded: return .rejected(.noFrameRecorded)
        case .containsTheClick: break
        }

        guard frame.size.width > 0, frame.size.height > 0 else {
            return .rejected(.degenerateRectangle)
        }
        guard frame.minX >= 0, frame.minY >= 0, frame.maxX <= 1, frame.maxY <= 1 else {
            return .rejected(.partlyOffscreen)
        }
        guard frame.size.width * frame.size.height <= maxTargetArea else {
            return .rejected(.tooLarge)
        }
        // Last, because it is a statement about the CHAIN rather than about this element,
        // and a reader is better served by "the button was offscreen" than by "the walk was
        // cut" when both are true. `.reachedRoot` means the walk finished, so an element
        // with no ancestors there is genuinely a root.
        if record.ancestors.isEmpty && record.truncation != .reachedRoot {
            return .rejected(.bestCandidateOnTheTruncationBoundary)
        }
        return .framed(FramingTarget(frame: frame, role: hit.role))
    }
}
