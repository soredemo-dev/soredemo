/// A half-open span of time: `[start, start + duration)`, on a single boot's
/// clock with no epoch attached.
///
/// **Half-open, not closed.** `end` itself is excluded. Touching ranges —
/// where one's `end` equals the other's `start` — therefore do **not**
/// overlap. Two adjacent citations of *anything* time-bounded must never both
/// claim the same instant; if `contains`/`overlaps` were closed at `end`, two
/// abutting citations would silently double-claim the boundary nanosecond.
/// `HostRange` (this module) inherits this exact half-open reasoning for the
/// epoch-stamped case.
///
/// **No caller in `Sources/` today.** `Graph`'s `EvidenceRef.sourceInterval`
/// was this type's stated first caller until Phase 2 Task 2 moved it to
/// `HostRange` — a bare `TimeRange` is exactly the value D2-11 showed is
/// ambiguous across a reboot, which is what `EvidenceRef.sourceInterval`
/// needed not to be. This type is otherwise unchanged and still tested
/// (`Tests/TimelineTests/TimeRangeTests.swift`); it has no first caller
/// recorded as of Task 2. A future intra-boot-only interval — one that is
/// provably never compared across a reboot, so the epoch would be pure
/// overhead — is the shape of caller that would justify keeping it rather
/// than folding it into `HostRange`.
public struct TimeRange: Hashable, Codable, Sendable {
    public let start: Nanoseconds
    public let duration: Nanoseconds

    /// Traps if `duration` is negative. Like every precondition in this
    /// package, this cannot be exercised with `#expect` — a precondition
    /// failure kills the process — so it is not covered by
    /// `TimeRangeTests.swift`; see the task report for how it was verified
    /// out-of-process instead.
    public init(start: Nanoseconds, duration: Nanoseconds) {
        precondition(duration.rawValue >= 0,
                     "TimeRange.duration must be non-negative, got \(duration.rawValue)")
        self.start = start
        self.duration = duration
    }

    /// The exclusive upper bound: `start + duration`.
    public var end: Nanoseconds { start + duration }

    /// True for every instant in `[start, end)`. A zero-duration range
    /// contains nothing — not even `start` — because half-openness makes
    /// `[start, start)` empty. This is intended: a zero-duration range
    /// represents an instant with no extent, not a single contained point.
    /// Do not "fix" this to include `start` for a zero-duration range; it
    /// would make `contains` disagree with `overlaps` between two
    /// zero-duration ranges at the same instant.
    public func contains(_ instant: Nanoseconds) -> Bool {
        instant >= start && instant < end
    }

    /// True iff the two half-open intervals share at least one instant.
    /// Touching ranges (`a.end == b.start`) do NOT overlap — see the type's
    /// documentation.
    public func overlaps(_ other: TimeRange) -> Bool {
        start < other.end && other.start < end
    }
}
