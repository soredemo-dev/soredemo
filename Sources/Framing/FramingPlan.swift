import Foundation
import Geometry
import Project
import Timeline

/// **What a reviewer sees, and what a reviewer can change.**
///
/// `FramingGate` decides one click at a time and names its refusals. Until this type
/// existed, the caller that drove it — `StageCompositor.buildTracks` — kept the accepted
/// targets and threw the refusals away at the moment they were computed, with a comment
/// saying so. A recording where every chain was refused therefore zoomed nowhere and
/// offered no way to find out why: the reasons had all been discarded one function call
/// after being derived.
///
/// A plan keeps every decision, accepted and refused alike, so `review-ui` can show which
/// gate fired, and so a reviewer's own decision has something to attach to.
public struct FramingPlan: Hashable, Sendable {
    /// One click, and what the gate concluded about it — in the order they were observed.
    public struct Entry: Hashable, Sendable {
        public let instant: HostInstant
        public let decision: FramingDecision

        public init(instant: HostInstant, decision: FramingDecision) {
            self.instant = instant
            self.decision = decision
        }
    }

    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries.sorted { $0.instant.hostTime.rawValue < $1.instant.hostTime.rawValue }
    }

    /// How many clicks the gate framed, and how many it refused for each named reason.
    /// A recording that zooms nowhere is a recording whose reasons are all in this table,
    /// which is the difference between a bug report and a diagnosis.
    public var rejectionCounts: [FramingRejection: Int] {
        var counts: [FramingRejection: Int] = [:]
        for entry in entries {
            if let reason = entry.decision.rejection { counts[reason, default: 0] += 1 }
        }
        return counts
    }

    public var framedCount: Int {
        entries.count { $0.decision.rejection == nil }
    }
}

/// A reviewer's decision about one click. **Authored, and it always wins.**
///
/// Architecture rule 7's producer-value rule: an authored value is never silently replaced
/// by a derived one. That is enforced here by resolution order rather than by convention —
/// `FramingPlan.resolved(with:)` consults overrides first and the gate second, and there is
/// no path in which a re-derivation can overwrite one.
///
/// `epoch` for the same reason `CursorOverride` carries one: `instant` is an absolute host
/// time, two boots produce overlapping host times, and an override recorded in one session
/// must not match a click in another by coincidence.
public struct FramingOverride: Codable, Hashable, Sendable {
    /// What the reviewer decided.
    public enum Action: Codable, Hashable, Sendable {
        /// Zoom to this rectangle, whatever the gate concluded — including a rectangle no
        /// AX element ever reported. This is the case that proves the rule: the producer
        /// could not have derived it, so a resolution that returned it can only have come
        /// from the author.
        case frame(NormalizedFrame)
        /// No zoom here, whatever the gate concluded.
        case suppress
    }

    public let epoch: BootEpoch
    public let instant: Nanoseconds
    public let action: Action

    public init(epoch: BootEpoch, instant: Nanoseconds, action: Action) {
        self.epoch = epoch
        self.instant = instant
        self.action = action
    }

    public func matches(_ candidate: HostInstant) -> Bool {
        epoch == candidate.epoch && instant.rawValue == candidate.hostTime.rawValue
    }
}

/// Where a resolved decision's value came from — the "origin" half of the ROADMAP's
/// "every generated value shows its origin, review state, and reason".
public enum FramingOrigin: Hashable, Sendable {
    /// The gate decided and no reviewer disagreed.
    case derived
    /// A reviewer decided. `over` is what the gate had concluded, kept rather than
    /// discarded: a reviewer who forced a zoom past `tooLarge` should still be able to see
    /// that `tooLarge` is what they overrode, and a reviewer looking at someone else's
    /// project should be able to tell an override from an agreement.
    case authored(over: FramingDecision?)
}

/// One click after both the gate and the reviewer have been consulted.
public struct ResolvedFraming: Hashable, Sendable {
    public let instant: HostInstant
    /// `nil` means no zoom — either the gate refused and nobody overrode it, or a reviewer
    /// suppressed one the gate had accepted.
    public let target: FramingTarget?
    public let origin: FramingOrigin

    public init(instant: HostInstant, target: FramingTarget?, origin: FramingOrigin) {
        self.instant = instant
        self.target = target
        self.origin = origin
    }

    /// The gate's reason, whether or not it was overridden — never erased by an override.
    public var rejection: FramingRejection? {
        switch origin {
        case .derived: return nil
        case .authored(let overridden): return overridden?.rejection
        }
    }

    /// True when a reviewer's decision differs from the gate's. The "review state" half of
    /// the requirement, derived rather than stored so it cannot disagree with the value.
    public var wasOverridden: Bool {
        if case .authored = origin { return true }
        return false
    }
}

extension FramingPlan {
    /// **Overrides first, the gate second.** Every override is honoured, including one at
    /// an instant the plan has no entry for — a reviewer marking a moment the recorder saw
    /// no click at all. Refusing those would make the authored value conditional on the
    /// producer having had an opinion, which is the opposite of the rule.
    ///
    /// Two overrides at the same instant would be a project that contradicts itself; the
    /// first in the given order wins, deterministically, rather than the last write to a
    /// dictionary.
    public func resolved(with overrides: [FramingOverride]) -> [ResolvedFraming] {
        var resolved: [ResolvedFraming] = []
        var consumed = Set<Int>()

        for entry in entries {
            guard let index = overrides.firstIndex(where: { $0.matches(entry.instant) }) else {
                switch entry.decision {
                case .framed(let target):
                    resolved.append(ResolvedFraming(instant: entry.instant, target: target,
                                                    origin: .derived))
                case .rejected:
                    resolved.append(ResolvedFraming(instant: entry.instant, target: nil,
                                                    origin: .derived))
                }
                continue
            }
            // **Every** override at this instant is consumed, not only the one that won.
            // Marking just the winner left the loser to fall through to the orphan pass
            // below and appear as a second entry at the same instant — a contradiction
            // resolved into a phantom rather than into one answer.
            for (other, candidate) in overrides.enumerated() where candidate.matches(entry.instant) {
                consumed.insert(other)
            }
            resolved.append(applying(overrides[index], over: entry.decision, at: entry.instant))
        }

        for (index, override) in overrides.enumerated() where !consumed.contains(index) {
            // Nothing to override — the gate never saw this instant. Still honoured, and
            // still only once: a second orphan at the same instant is the same
            // contradiction as above and gets the same treatment.
            let instant = HostInstant(epoch: override.epoch, hostTime: override.instant)
            guard !resolved.contains(where: {
                $0.instant.epoch == instant.epoch
                    && $0.instant.hostTime.rawValue == instant.hostTime.rawValue
            }) else { continue }
            resolved.append(applying(override, over: nil, at: instant))
        }

        return resolved.sorted { $0.instant.hostTime.rawValue < $1.instant.hostTime.rawValue }
    }

    private func applying(_ override: FramingOverride, over decision: FramingDecision?,
                          at instant: HostInstant) -> ResolvedFraming {
        switch override.action {
        case .frame(let frame):
            // The role is the gate's if it had one, so an override that only moves the
            // rectangle does not also erase what the element was. `nil` when the reviewer
            // framed something the gate never identified.
            let role: String?
            if case .framed(let target) = decision { role = target.role } else { role = nil }
            return ResolvedFraming(instant: instant,
                                   target: FramingTarget(frame: frame, role: role),
                                   origin: .authored(over: decision))
        case .suppress:
            return ResolvedFraming(instant: instant, target: nil,
                                   origin: .authored(over: decision))
        }
    }

    /// What the camera actually zooms to, after review. The one call `StageCompositor`
    /// makes; everything above it exists so this answer can be explained.
    public func framedClicks(with overrides: [FramingOverride]) -> [FramedClick] {
        resolved(with: overrides).compactMap { entry in
            entry.target.map { FramedClick(instant: entry.instant, target: $0) }
        }
    }
}
