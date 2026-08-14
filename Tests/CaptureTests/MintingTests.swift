import Foundation
import Graph
import Testing
import Timeline
@testable import Capture

// The first tests of `Minting` that have ever run under `swift test`. It sat in the app
// target from Phase 1 until Phase 3A-3, where `swift test` cannot link an executable
// target — so its only instruments were `Tests/AppSourceTests` reading it AS TEXT, the
// hand-run cross-boundary probe, and a person. The digest vectors below were pinned by
// the probe; they are now also pinned by something that runs on every `swift test`.
//
// What is asserted here is what an ambient boundary CAN promise: the shape of the value,
// the invariants between two reads, and the pinned mapping for the one pure function.
// Nobody can assert what `hostNow()` returns.

/// Lowercase hex, without `String(format:)` — that initialiser's C varargs are an
/// unmarked unsafe construct under `.strictMemorySafety()`, the same reason
/// `MP4Exporter` reaches for `.formatted(...)` instead.
private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String($0, radix: 16).count == 1 ? "0" + String($0, radix: 16) : String($0, radix: 16) }
        .joined()
}

// MARK: - digest: the one member with a right answer

/// FIPS 180-4's own SHA-256 vector for the empty input. A digest function that silently
/// became something else — a different algorithm, a truncation, a double-hash — still
/// returns 32 bytes and still round-trips; only a pinned vector catches it.
@Test func theEmptyInputDigestIsSHA256sPublishedVector() {
    let digest = Minting.digest(of: Data())
    #expect(hex(digest.bytes)
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
}

/// The `"abc"` vector, from the same publication — a non-identity input, because the
/// empty-input case alone would pass for a function that ignored its argument.
@Test func theAbcDigestIsSHA256sPublishedVector() {
    let digest = Minting.digest(of: Data("abc".utf8))
    #expect(hex(digest.bytes)
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}

/// `digest(of:)` is generic over `DataProtocol` so `[UInt8]` and `Data` callers share one
/// implementation; that sharing is the claim, and it is only true if they agree.
@Test func theSameBytesDigestTheSameThroughEitherDataProtocolConformance() {
    let bytes: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
    #expect(Minting.digest(of: bytes) == Minting.digest(of: Data(bytes)))
}

@Test func aDigestIsAlwaysThePinnedByteCount() {
    #expect(Minting.digest(of: Data("anything".utf8)).bytes.count == ContentDigest.byteCount)
}

// MARK: - the boot epoch

/// The epoch is read from `kern.bootsessionuuid`, which is fixed for a boot session, so
/// two reads inside one test process must agree. This is the property the whole
/// epoch-stamping design rests on: `1a98402`'s neighbourhood is full of comparisons that
/// are only meaningful because two components independently reading the epoch get the
/// same answer. `kern.boottime` — now-minus-uptime — would fail this under a clock
/// correction, which is why `Minting` does not use it.
@Test func theBootEpochIsStableWithinOneBootSession() {
    #expect(Minting.bootEpoch() == Minting.bootEpoch())
}

/// An anchor carries the same epoch the direct read gives — an anchor stamped with a
/// different session would make every record it dates uncomparable with every other.
@Test func anEpochAnchorCarriesThisBootSession() {
    #expect(Minting.epochAnchor().epoch == Minting.bootEpoch())
}

// MARK: - the clocks

/// `hostNow()` is the ordering key for every observation record, so it may never go
/// backwards between two reads.
@Test func theHostClockDoesNotRunBackwards() {
    let first = Minting.hostNow()
    let second = Minting.hostNow()
    #expect(second.rawValue >= first.rawValue)
}

/// `continuousNow() - hostNow()` is how long the system has slept since boot, which
/// cannot be negative. This also catches the two clocks being wired to each other's
/// `mach_*` source — a swap that leaves both monotonic and both plausible.
@Test func theContinuousClockIsNeverBehindTheHostClock() {
    // Continuous first: reading it second would let elapsed time between the two reads
    // hide a small negative difference, and the test would pass for the wrong reason.
    let continuous = Minting.continuousNow()
    let host = Minting.hostNow()
    #expect(continuous.rawValue >= host.rawValue)
}

/// Both clocks are converted from `mach` ticks through the timebase; a timebase fetched
/// as zeroes (the shape of an unchecked `mach_timebase_info` failure) yields zero here.
@Test func bothClocksReturnANonZeroReading() {
    #expect(Minting.hostNow().rawValue > 0)
    #expect(Minting.continuousNow().rawValue > 0)
}

// MARK: - identifiers

/// Two calls must not collide. A stubbed or cached implementation — the shape a
/// determinism refactor could plausibly introduce — reddens here.
@Test func eachMintedIdentifierIsDistinct() {
    #expect(Minting.newIdentifier() != Minting.newIdentifier())
}
