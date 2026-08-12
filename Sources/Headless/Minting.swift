// `CGDisplayCreateUUIDFromDisplayID` is declared in `ColorSync.framework`
// (`ColorSyncDevice.h`), not CoreGraphics, despite the `CG` prefix. CoreGraphics
// is still imported for `CGDirectDisplayID` itself.
import ColorSync
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import Graph
import Timeline

/// The ambient values the deterministic tier is forbidden to touch (`UUID`, `Date`,
/// `SHA256`, the clocks, `sysctl`), read here at one boundary. Every function is a pure
/// mapping from an ambient thing to a package type; anything with branching or policy in
/// it belongs in a package module instead.
///
/// **In `Headless` since Phase 3A-3, and `public` because of it.** It was an app-target
/// file, so `internal` reached its callers; from a library target the app tier needs the
/// symbol exported. Every member of this file reads the environment, which is what makes
/// the whole-file permit in `Tests/AppSourceTests` cost nothing — the same argument
/// `MonotonicStopwatch.swift` carries, and the reason those are two files and not one:
/// this file's claim is "pure ambient→package mappings" and a stateful stopwatch is not
/// one. The app target now holds no ambient boundary at all
/// (`noAppSourceReadsAnAmbientValueAtAll`).
public enum Minting {
    /// A fresh v4 UUID. The package cannot call `UUID()`; it can hold the result.
    ///
    /// `nonisolated` here and on every function in this file is required and must stay:
    /// the target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and callers include
    /// synchronous non-MainActor contexts such as `SCStreamOutput` callbacks.
    public nonisolated static func newIdentifier() -> UUID {
        UUID()
    }

    /// The current wall-clock instant. Same reasoning as `newIdentifier()`.
    public nonisolated static func now() -> Date {
        Date()
    }

    /// SHA-256 of `bytes`, as the package's opaque 32-byte `ContentDigest`.
    /// Generic over `DataProtocol` so `[UInt8]` and `Data` callers share one
    /// implementation. The digest values are pinned by cross-boundary tests.
    public nonisolated static func digest(of bytes: some DataProtocol) -> ContentDigest {
        ContentDigest(Array(SHA256.hash(data: bytes)))
    }
}

// MARK: - boot epoch and the host clock
extension Minting {
    /// `mach_timebase_info`'s numerator/denominator convert `mach_absolute_time` and
    /// `mach_continuous_time` ticks to nanoseconds. A property of the CPU, fixed for the
    /// life of the process, so it is fetched once. `nonisolated` to be reachable from
    /// `hostNow()`/`continuousNow()`.
    private nonisolated static let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t()
        // Safe here: `&t` is a local whose lifetime spans the call, and the kernel
        // writes it only before returning.
        unsafe mach_timebase_info(&t)
        return t
    }()

    /// The current boot session, from `kern.bootsessionuuid`. Not `kern.boottime`: that
    /// is computed as now-minus-uptime and moves with clock corrections, so two reads
    /// within one boot can disagree. Traps on an absent or malformed value rather than
    /// returning a fallback; a fabricated epoch makes two boots look like one silently.
    public nonisolated static func bootEpoch() -> BootEpoch {
        var size = 0
        // Safe here: the two-call sysctl idiom. The first call writes only `size` (the
        // value pointer is nil); the second writes at most `size` bytes into a buffer
        // allocated at exactly that length one line earlier, and cannot grow it — the
        // key names a fixed-length UUID string. Both pointers are locals outliving the
        // call. `precondition` between them refuses a zero length rather than passing a
        // zero-capacity buffer to the second call.
        unsafe sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0)
        precondition(size > 0, "kern.bootsessionuuid is unavailable; there is no honest fallback")
        var buf = [CChar](repeating: 0, count: size)
        unsafe sysctlbyname("kern.bootsessionuuid", &buf, &size, nil, 0)
        // `String(cString: [CChar])` is deprecated on this SDK; truncate at the
        // null terminator `sysctlbyname` writes and decode explicitly instead.
        let terminatorIndex = buf.firstIndex(of: 0) ?? buf.count
        let s = String(decoding: buf[..<terminatorIndex].map(UInt8.init(bitPattern:)), as: UTF8.self)
        guard let id = UUID(uuidString: s) else {
            preconditionFailure("kern.bootsessionuuid is not a UUID: \(s)")
        }
        return BootEpoch(id: id)
    }

    /// A display's **persistent** identity, from `CGDisplayCreateUUIDFromDisplayID`:
    /// window-server display IDs are assigned dynamically and are not stable across
    /// reboot or replug. `takeRetainedValue()` because that is a `Create` function.
    ///
    /// Returns `nil`, unlike `bootEpoch()`, because a display can go away between being
    /// listed and being asked about; the caller drops it and keeps the rest.
    /// Named `displayIdentity`, not `displayUUID`: `AppSourceAllowListTests` bans the
    /// substring `UUID(` at every call site outside this file.
    public nonisolated static func displayIdentity(of displayID: CGDirectDisplayID) -> UUID? {
        // Safe here: `takeRetainedValue()` is the documented ownership transfer for a
        // `Create` function, so the CFUUID is released by ARC; `CFUUIDCreateString`'s nil
        // allocator is the documented default, and the result is bridged, not borrowed.
        guard let cfUUID = unsafe CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let string = unsafe CFUUIDCreateString(nil, cfUUID) as String? else { return nil }
        return UUID(uuidString: string)
    }

    /// The host clock, in nanoseconds — the same base as `CMClockGetHostTimeClock()`
    /// and `CGEventTimestamp`. Stops advancing while the system sleeps; see
    /// `continuousNow()`.
    public nonisolated static func hostNow() -> Nanoseconds {
        Nanoseconds(Int64(mach_absolute_time() &* UInt64(timebase.numer) / UInt64(timebase.denom)))
    }

    /// For display and rough placement only; the wall clock is **not** an ordering key.
    /// `wallClockUnixNanos` passes through `Double`, whose 53-bit mantissa rounds it to
    /// the nearest ~256 ns at today's magnitude — coarser than the field's name promises.
    /// `hostNow()` and `continuousNow()`, which do order things, avoid `Double` entirely.
    public nonisolated static func epochAnchor() -> EpochAnchor {
        EpochAnchor(epoch: bootEpoch(), hostTime: hostNow(),
                    wallClockUnixNanos: Int64(Date().timeIntervalSince1970 * 1e9))
    }

    /// The continuous clock, in nanoseconds — advances during sleep, unlike `hostNow()`.
    /// `continuousNow() - hostNow()` is how long the system has slept since boot. Never
    /// used as an ordering key; it detects sleep and does not replace the host clock.
    public nonisolated static func continuousNow() -> Nanoseconds {
        Nanoseconds(Int64(mach_continuous_time() &* UInt64(timebase.numer) / UInt64(timebase.denom)))
    }
}
