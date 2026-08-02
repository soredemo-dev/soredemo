import CryptoKit
import Foundation
import Graph

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
    static func newIdentifier() -> UUID {
        UUID()
    }

    /// The current wall-clock instant. Same reasoning as `newIdentifier()`.
    static func now() -> Date {
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
    static func digest(of bytes: some DataProtocol) -> ContentDigest {
        ContentDigest(Array(SHA256.hash(data: bytes)))
    }
}
