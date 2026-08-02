import Foundation

/// Identifies the boot session a host timestamp belongs to.
///
/// `mach_absolute_time()` restarts at boot, and `CMClockGetHostTimeClock()` is
/// that clock, so every timestamp this project stores is meaningless without
/// knowing which boot produced it. Two recordings made in different boots carry
/// overlapping, incomparable values and nothing raises an error — which is
/// precisely where Phase 4's `selective-rerecord` splices footage together.
///
/// This is `GeometryRevision` on the time axis and the parallel is deliberate:
/// both answer "are these two values in the same reference frame", and in both
/// cases the absence of the guard produces a wrong answer rather than an error.
///
/// Minted in the app from `kern.bootsessionuuid` and passed in — never read
/// here, because this module may not touch ambient values.
public struct BootEpoch: Hashable, Codable, Sendable {
    public let id: UUID
    public init(id: UUID) { self.id = id }
}
