import Foundation

/// Identifies the boot session a host timestamp belongs to. `mach_absolute_time()`
/// restarts at boot, so timestamps from two boots carry overlapping, incomparable
/// values with nothing raising an error. Minted in the app from
/// `kern.bootsessionuuid` and passed in; this module reads no ambient values.
public struct BootEpoch: Hashable, Codable, Sendable {
    public let id: UUID
    public init(id: UUID) { self.id = id }
}
