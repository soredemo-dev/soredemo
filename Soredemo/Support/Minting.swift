// `CGDisplayCreateUUIDFromDisplayID` is declared in `ColorSync.framework`
// (`ColorSyncDevice.h`), not CoreGraphics, despite the `CG` prefix and despite
// taking a `CGDirectDisplayID` — verified by grepping the SDK's frameworks for
// the symbol after `import CoreGraphics` alone failed to find it. CoreGraphics
// is still imported for `CGDirectDisplayID` itself.
import ColorSync
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import Graph
import Timeline

/// The three things `SoredemoCore` is forbidden to do, done here — once, in one
/// file, on the app side of the line.
///
/// Architecture rule 1 (`ARCHITECTURE.md` D6) keeps the package on `import Foundation`
/// alone, and the design doc § Determinism keeps ambient time and randomness out
/// of it entirely (enforced at link time by `Tests/DeterminismTests`, which
/// scans the package's object files for `UUID` and `Date` symbols). That rule is
/// what makes derivation a deterministic function of its input, and therefore
/// what makes staleness detection and content-hash approval mean anything.
///
/// A rule like that only works if the ambient values enter from a boundary that
/// is small enough to see. This is that boundary. **Every function here is a
/// pure mapping from an ambient thing to a package type** — no branching, no
/// policy, nothing that could have lived in the package. Anything with logic in
/// it belongs on the other side of the line, where it can be tested without a
/// clock or a random number generator.
///
/// `SHA256` in particular is not an arbitrary choice of venue: `ContentDigest`
/// documents at length why the package **compares digests and never computes
/// one** — computing needs CryptoKit, which rule 1 forbids — so the value is
/// injected by whoever produced the evidence. That producer is this enum.
enum Minting {
    /// A fresh v4 UUID. The package cannot call `UUID()`; it can hold the result.
    ///
    /// **`nonisolated`, and it must stay that way.** Every function in this
    /// file is unannotated, so under this
    /// target's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` each one is
    /// implicitly `@MainActor` — harmless while every caller was itself
    /// MainActor, which was true until `CaptureSession`'s `SCStreamOutput`
    /// callbacks (Task 8), which `ScreenCaptureKit` delivers on a queue this
    /// app owns and which must stay synchronous, non-`async` (they override
    /// a plain ObjC protocol method). Verified by compiling
    /// `CaptureSession.swift` against the unmodified file: `xcrun swiftc`
    /// rejected `Minting.hostNow()` called from a `nonisolated` function
    /// with "call to main actor-isolated static method 'hostNow()' in a
    /// synchronous nonisolated context" — the exact shape
    /// `CaptureSource.swift`'s own header describes hitting for
    /// `.geometry()`/`.filter()` while building Task 7, for the identical
    /// reason: "a function pinned to the main actor is not free of the
    /// concurrency domain it claims independence from, whatever thread
    /// happens to call it in practice today." None of these functions reads
    /// AppKit or UI state — they are thin reads of `sysctl`/`mach_*`/`UUID`/
    /// `Date`/`SHA256`, ambient but context-free — so `nonisolated` is the
    /// correct annotation, not a workaround: it makes the isolation match
    /// what was already true of the implementation, for every function in
    /// this file, not only the one Task 8 happened to need first.
    nonisolated static func newIdentifier() -> UUID {
        UUID()
    }

    /// The current wall-clock instant. Same reasoning as `newIdentifier()`.
    nonisolated static func now() -> Date {
        Date()
    }

    /// SHA-256 of `bytes`, as the package's opaque 32-byte `ContentDigest`.
    ///
    /// Generic over `DataProtocol` so the two shapes that actually cross this
    /// boundary — `[UInt8]` from `canonicalBytes`/`approvalBytes`, and `Data`
    /// from a media sidecar — both go through one implementation rather than
    /// two that could drift apart.
    ///
    /// `SHA256Digest` is a `Sequence` of `UInt8` of exactly 32 elements, so
    /// `ContentDigest.init(_:)`'s byte-count precondition can never fire here;
    /// it stands for callers that build a digest from somewhere else.
    ///
    /// Pinned across the package boundary by `Tests/GraphTests/CrossBoundaryDigestVectorTests.swift`
    /// plus `scripts/cross-boundary-digest-probe.swift` — see those files for
    /// why the vector is split in two.
    nonisolated static func digest(of bytes: some DataProtocol) -> ContentDigest {
        ContentDigest(Array(SHA256.hash(data: bytes)))
    }
}

// MARK: - boot epoch and the host clock (Task 5)
//
// Two more ambient readings, same boundary, same reasoning as above: a pure
// mapping from something only the app may touch to a plain value `Timeline`
// can hold without touching a clock or `sysctl` itself.
extension Minting {
    /// `mach_timebase_info`'s numerator/denominator convert `mach_absolute_time`
    /// and `mach_continuous_time` ticks to nanoseconds. Measured on this machine
    /// (F2-1): `numer = 125, denom = 3`, i.e. 1 tick = 41.667 ns. Fetched once —
    /// it is a property of the CPU, fixed for the life of the process.
    /// `nonisolated`, alongside the functions below — it must be reachable
    /// from `hostNow()`/`continuousNow()`'s own `nonisolated` context, and
    /// no `unsafe` is needed: `mach_timebase_info_data_t` is `Sendable` and
    /// a `static let` is initialised exactly once regardless of which
    /// isolation domain first touches it.
    private nonisolated static let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t
    }()

    /// The current boot session, from `kern.bootsessionuuid`.
    ///
    /// **Not `kern.boottime`.** That is computed as now-minus-uptime and moves
    /// when the system clock is corrected by NTP or by hand, so two reads within
    /// one boot can disagree and a single boot would look like two (D2-11).
    /// Verified on this machine: `bootsessionuuid` is stable across reads.
    ///
    /// `precondition`s on an absent or malformed value rather than returning a
    /// fallback. This is judged, not copied from Task 4.5's caution about
    /// `precondition` on values from outside the process: that caution was
    /// about a `.soredemo` package's bytes, which are attacker-influenced
    /// document content by `agentic-threat-model`'s assumption.
    /// `kern.bootsessionuuid` is not document content — it is a property of
    /// the platform this app is built against (macOS 26, `AGENTS.md`'s stated
    /// target), read once at a fixed, documented sysctl name that has been
    /// present and UUID-shaped on every machine this project has measured. If
    /// it is ever absent, that means the platform assumption itself is false —
    /// a programming-environment contract violation, not a malformed input to
    /// tolerate — and D2-11 is explicit that a silently wrong or fabricated
    /// epoch is worse than a crash: it makes two boots look like one, or one
    /// look like two, with no error anywhere downstream. A fallback identifier
    /// would be exactly `AGENTS.md`'s "measurement with a safe default" one
    /// level up: a plausible-looking `BootEpoch` for a question the type exists
    /// to answer correctly.
    public nonisolated static func bootEpoch() -> BootEpoch {
        var size = 0
        sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0)
        precondition(size > 0, "kern.bootsessionuuid is unavailable; there is no honest fallback")
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("kern.bootsessionuuid", &buf, &size, nil, 0)
        // `String(cString: [CChar])` is deprecated on this SDK; truncate at the
        // null terminator `sysctlbyname` writes and decode explicitly instead.
        let terminatorIndex = buf.firstIndex(of: 0) ?? buf.count
        let s = String(decoding: buf[..<terminatorIndex].map(UInt8.init(bitPattern:)), as: UTF8.self)
        guard let id = UUID(uuidString: s) else {
            preconditionFailure("kern.bootsessionuuid is not a UUID: \(s)")
        }
        return BootEpoch(id: id)
    }

    /// A display's **persistent** identity, from
    /// `CGDisplayCreateUUIDFromDisplayID` — the value `DisplayGeometry
    /// .displayUUID` is documented to hold (D-P2), and the reason it holds a
    /// `UUID` rather than a `CGDirectDisplayID`: the window server assigns
    /// display IDs dynamically and they are not stable across reboot or
    /// replug.
    ///
    /// **Here, and not at the call site, because of this file's own rule.**
    /// `AppSourceAllowListTests` bans `UUID(` and `UUID.init` everywhere
    /// under `Soredemo/` except this file, and every route from a `CFUUID` to
    /// a Foundation `UUID` — `UUID(uuidString:)`, `UUID(uuid:)`, `NSUUID(…)`
    /// — is one of those spellings. So a display's identity could not be
    /// read anywhere else even if it wanted to be, which is the intended
    /// outcome: this is ambient environment identity, exactly like
    /// `bootEpoch()`, and it enters at the one audited place. Added to that
    /// test's banned list alongside `sysctlbyname` in the same commit, so the
    /// claim is enforced rather than asserted.
    ///
    /// Returns `nil` rather than trapping, unlike `bootEpoch()`. The
    /// difference is judged, not inherited: `kern.bootsessionuuid`'s absence
    /// means the platform contract is false, while a display ID can go stale
    /// between being listed and being asked about — a monitor unplugged
    /// mid-enumeration is a normal race on a machine someone is using, not a
    /// broken environment. The caller drops that display from the
    /// arrangement and keeps the others; see `InputObserver.currentArrangement()`.
    ///
    /// `takeRetainedValue()`: `CGDisplayCreateUUIDFromDisplayID` is a
    /// `Create` function, so this side owns the reference.
    ///
    /// **Named `displayIdentity`, not `displayUUID`, and that is the scan's
    /// doing rather than a style choice.** `AppSourceAllowListTests` bans the
    /// substring `UUID(` and matches substrings deliberately, so every call
    /// site written `Minting.displayUUID(of: id)` failed that test — the
    /// "visible false positive" its own header describes as survivable. It is
    /// survivable because the fix is renaming one function; weakening the
    /// substring match to buy a nicer name would trade a real guarantee for
    /// spelling.
    nonisolated static func displayIdentity(of displayID: CGDirectDisplayID) -> UUID? {
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, cfUUID) as String? else { return nil }
        return UUID(uuidString: string)
    }

    /// The host clock, in nanoseconds — the same base as
    /// `CMClockGetHostTimeClock()` and `CGEventTimestamp`, measured (F2-1).
    /// Stops advancing while the system sleeps (D2-4); see `continuousNow()`.
    public nonisolated static func hostNow() -> Nanoseconds {
        Nanoseconds(Int64(mach_absolute_time() &* UInt64(timebase.numer) / UInt64(timebase.denom)))
    }

    /// For display and rough placement only. The wall clock is **not** an
    /// ordering key — `SegmentTable` is (D2-11).
    ///
    /// `wallClockUnixNanos` is an `Int64` built from `Date().timeIntervalSince1970
    /// * 1e9`. No overflow: at today's magnitude (~1.79e18) that is comfortably
    /// inside `Int64`'s range, which runs out only in the year 2262. But it is
    /// not nanosecond-*precision* — `Double` has a 53-bit mantissa, and a value
    /// near 1.79e18 needs about 61 bits to represent exactly, so the multiply
    /// rounds to the nearest 256 ns (measured: `(t * 1e9).ulp == 256.0` on this
    /// machine), and `timeIntervalSince1970` itself already carries about 238 ns
    /// of rounding at this magnitude before the multiply. That is coarser than
    /// the type's name promises, and is acceptable only because this field is
    /// documented — here and in `EpochAnchor` — as display and rough placement,
    /// never an ordering key. `hostNow()` and `continuousNow()`, which order
    /// things, do not go through `Double` at any point.
    public nonisolated static func epochAnchor() -> EpochAnchor {
        EpochAnchor(epoch: bootEpoch(), hostTime: hostNow(),
                    wallClockUnixNanos: Int64(Date().timeIntervalSince1970 * 1e9))
    }

    /// The continuous clock, in nanoseconds — advances during sleep, unlike
    /// `hostNow()`. `continuousNow() - hostNow()` is how long the system has
    /// slept since boot (D2-4): measured on this machine at 59.68 h against
    /// 172.57 h of uptime — 35%, not a corner case. Never stored or compared
    /// against a `hostNow()` reading from a different moment as an ordering
    /// key; it exists to detect sleep, not to replace the host clock F2-1
    /// established `CMClockGetHostTimeClock()` and `CGEventTimestamp` are on.
    public nonisolated static func continuousNow() -> Nanoseconds {
        Nanoseconds(Int64(mach_continuous_time() &* UInt64(timebase.numer) / UInt64(timebase.denom)))
    }
}
