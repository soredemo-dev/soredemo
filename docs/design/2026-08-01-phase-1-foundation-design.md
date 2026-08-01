# Phase 1 — Foundation: design

*Brainstormed 1 August 2026. Covers `repo-skeleton`, `architecture-plugin`, `geometry`,
`project-format`, `derivation-graph`.*

Four decisions were taken deliberately with the project owner and are recorded in § Decisions. Five
claims in existing documents were tested against the macOS 27 SDK and four of them are wrong; the
corrections are in § Document corrections and land in the same commits as the code.

---

## SDK findings

Probes run against `MacOSX27.0.sdk`, Xcode 27 beta 4 (`27A5228h`), Swift 6.4. Sources are the
`.swiftinterface` declarations and two compiled probes, not documentation.

### F1 — The Document API handles packages. `ARCHITECTURE.md § To verify` is resolved

`ReadableDocument`/`WritableDocument` place no constraint on the shape of what is read or written:

```swift
public protocol DocumentReader<Snapshot> {
  associatedtype Snapshot
  associatedtype Source = Foundation.URL          // generic, merely defaults to URL
  @concurrent func read(from source: sending Self.Source,
                        progress: consuming Foundation.Subprogress) async throws -> sending Self.Snapshot
}
```

A directory URL is a URL. With `UTType(exportedAs:conformingTo: .package)` the document *is* a
directory, and a custom reader may read one small manifest and leave gigabytes of media untouched on
disk. Verified by compiling `DocProbe.swift` (a `Document` over a directory URL) clean under
`-swift-version 6 -strict-concurrency=complete -target arm64-apple-macos27.0`.

**Consequence:** D5 stands unchanged. No hand-written package coordinator. The contingency named in
`KICKOFF.md` ("if the answer is single-file only, `project-format` needs a hand-written package
coordinator and that changes the row") does not fire.

**Unanticipated bonus:** `write(snapshot:to:previous:progress:)` supplies the *previous* snapshot.
Incremental save is a first-class affordance of the API rather than something to build.

### F2 — The document protocols are SwiftUI types, so `SoredemoCore` cannot use them

```
SwiftUI.framework/…/SwiftUI.swiftinterface:1812   public protocol ReadableDocument : AnyObject
SwiftUI.framework/…/SwiftUI.swiftinterface:1822   public protocol WritableDocument : AnyObject
```

They are not in Foundation. Under D6 the package cannot import SwiftUI, so the `project-format` row
spans the package/app boundary. See § Project format for the split.

### F3 — `DocumentCreationSource` is unavailable on macOS

```swift
public struct DocumentCreationSource : Sendable, Hashable {
  @available(macOS, unavailable)  public init(id: String)
}
@available(macOS, unavailable)  extension NewDocumentButton { … }
```

Unconstructible on macOS, and its only consumer is entirely macOS-unavailable — it is an
iOS/visionOS affordance. `URLDocumentConfiguration.creationSource` compiles on macOS but is
permanently `nil`. The three entry points (new from recording, new from release, new empty) are
built by hand.

### F4 — SwiftPM does **not** restrict system-framework imports

A target with zero declared dependencies, importing `AppKit` and `ScreenCaptureKit` and calling
`NSColor.red`, builds successfully:

```
[94 / 102] PureTarget
Build complete! (10.01秒)
```

Everything in the SDK is importable from any target. `ARCHITECTURE.md` D6 mechanism 1 and
`AGENTS.md` architecture rule 1 both claim the compiler enforces the Foundation-only rule. It does
not. **`Plugins/ArchitectureCheck` is the primary enforcement of D6, not a supplement to it.**

### F5 — `.macOS(.v27)` requires `swift-tools-version: 6.4`

Under tools version 6.2 the manifest fails with `error: 'v27' is unavailable` /
`note: 'v27' was introduced in PackageDescription 6.4`.

---

## Decisions

### D-P1 — One package, six modules

One `Package.swift`; six library targets whose SwiftPM dependency edges make the module map in
`ARCHITECTURE.md` a compile error rather than a naming convention.

```
Geometry    ─ no dependencies (leaf)
Timeline    ─ no dependencies (leaf)
Graph       ← Geometry, Timeline
Framing     ← Graph, Geometry
Variants    ← Framing, Timeline
Project     ← Graph, Geometry, Timeline
```

`Graph` depends on `Timeline` because `EvidenceRef.sourceInterval` cites a time range: a citation
that cannot name *when* in the recording it came from is not much of a citation.

**`Timeline` is a second leaf.** It maps integer nanoseconds between source, camera, and output
timebases; nothing in that is spatial, so it needs nothing from `Geometry`. An edge with no reason
is one the next person will use for something unrelated, and this is the cheapest moment to leave it
out. `Framing` and `Variants` are where space and time meet, and both already depend on each side.

*Rejected:* one module — folders would be cosmetic and every internal boundary would rest on review.
*Rejected:* several packages — nothing here ships separately; it buys manifests and resolution cost.
*Rejected:* split later — boundaries drawn after the coupling exists are boundaries drawn too late.

`Framing` and `Variants` are empty in Phase 1. They exist to fix the dependency direction before
there is code to tangle. Each has a test target asserting only that it builds.

### D-P2 — `GeometryRevision` is a stable content digest, with a registry in the document

Identity is *the geometry*, not the event. Same display configuration yields the same revision, in
any session.

`DisplayGeometry` holds **intrinsic** geometry only — what the panel is, not where it sits. Extrinsic
arrangement is modelled separately and deliberately excluded from the digest; see § Display identity
and arrangement for why both halves of that sentence are load-bearing.

```swift
public struct GeometryRevision: Hashable, Codable, Sendable { public let id: UInt64 }

public struct DisplayGeometry: Hashable, Codable, Sendable {
    public let displayUUID: UUID        // persistent, NOT CGDirectDisplayID
    public let pixelWidth: Int, pixelHeight: Int
    public let scale: Double            // finite, > 0; digested as .bitPattern
    public var revision: GeometryRevision { GeometryRevision(id: fnv1a64(canonicalBytes)) }
}

public struct GeometryRegistry: Codable, Sendable {
    public var entries: [GeometryRevision: DisplayGeometry]
    public var firstObserved: [GeometryRevision: Int64]   // ordering, kept out of identity

    /// FNV-1a is 64-bit and non-cryptographic. Collisions are vanishingly unlikely across the
    /// handful of configurations one document sees, but they are *detectable* here, and a silent
    /// collision means two different geometries compare equal — the exact failure D3 names.
    public mutating func insert(_ geometry: DisplayGeometry, observedAt: Int64) {
        let revision = geometry.revision
        if let existing = entries[revision] {
            precondition(existing == geometry,
                "geometry revision collision: \(existing) vs \(geometry)")
            return
        }
        entries[revision] = geometry
        firstObserved[revision] = observedAt
    }
}
```

Two properties this buys:

- **No false traps.** A display that changes and changes back restores comparability, because the
  geometry genuinely is the same. A counter would produce revisions 0 and 2 over identical geometry
  and trap on a legitimately comparable pair — a crash for no reason.
- **Merges are safe.** `selective-rerecord` (Phase 4) puts footage from two sessions in one document.
  Per-session counters both start at 0 and collide silently, which is precisely the "lands a zoom on
  the wrong control with no error anywhere" failure D3 names.

**The digest must not be `Hashable.hashValue`.** Swift's `Hasher` is randomly seeded per process, so
a persisted `hashValue` will not match the same geometry on reopen. FNV-1a over a canonical
little-endian encoding of the fields, written by us and covered by a test that pins known input to
known output.

`scale` is a `Double`, so its canonical encoding is `scale.bitPattern` — exact and deterministic,
where a decimal rendering is neither. A precondition rejects non-finite or non-positive scale on
construction, which removes the `NaN`/`-0.0` cases that would otherwise make the digest ill-defined.

Pixel dimensions appear only inside `DisplayGeometry` and the registry, honouring D3's rule that
nothing in between speaks in pixels.

*Rejected:* monotonic session counter — collides on merge, false-traps on flip-back.
*Rejected:* UUID per epoch — merges safely but still false-traps, and is opaque in a log.
*Rejected:* inline self-describing geometry in every frame — no registry lookup and a maximally
informative trap message, but it puts pixel values in the type that crosses module boundaries and
costs ~16 bytes across millions of observation records.

#### Display identity and arrangement

Two mistakes here would each reintroduce exactly the false trap D-P2 exists to eliminate.

**`CGDirectDisplayID` must not enter the digest.** It is assigned dynamically by the window server
and is not stable across reboot or unplug/replug. Using it would make the decision's own
justification false: record on Monday, reboot, record on Tuesday with the same monitor at the same
resolution, and `selective-rerecord` (Phase 4) puts both in one document with two different
revisions for identical geometry — a precondition failure on a genuinely comparable pair. The
persistent identity is `CGDisplayCreateUUIDFromDisplayID` (`ColorSyncDevice.h:233` in the macOS 27
SDK, with `CGDisplayGetDisplayIDFromUUID` for the reverse). It vends a `CFUUIDRef`, bridged to a
Foundation `UUID`, so D6 is untouched: the app target performs the lookup and passes a plain value
into the package.

Display identity stays in the digest rather than being dropped. Two identical monitors side by side
would otherwise collapse to one revision, and "40% across *a* display" is not a comparable
coordinate when there are two of them.

**Global arrangement must stay out of the digest.** `CGEventGetLocation` returns coordinates in the
global space spanning every display, so routing a click to the display it landed on requires each
display's global origin — which `DisplayGeometry` deliberately does not have. Putting it there would
be worse than the omission: `CGDisplayBounds` origins shift when the arrangement changes, and
promoting a different display to main re-bases the entire global space, so rearranging display B
would silently change display A's revision and invalidate footage that nothing about display A had
altered.

So the two are separated by lifetime, and only the intrinsic half is digested:

```swift
/// Intrinsic. Digested. Changes only when the panel or its mode changes.
public struct DisplayGeometry: Hashable, Codable, Sendable { … }

/// Extrinsic. NOT digested, NOT part of any revision. Used at capture entry only,
/// to route a global point to the display that contains it.
public struct DisplayArrangement: Sendable {
    public struct Placement: Sendable {
        public let geometry: DisplayGeometry
        public let globalOriginX, globalOriginY: Double   // top-left, global space
    }
    public let placements: [Placement]

    /// Returns the containing display and the point re-expressed in that display's
    /// own top-left pixel space. nil when the point lies on no display.
    public func route(globalTopLeftX: Double, globalTopLeftY: Double)
        -> (geometry: DisplayGeometry, localX: Double, localY: Double)?
}
```

`NormalizationContext.normalize(topLeftX:topLeftY:…)` therefore takes **display-local** top-left
pixels, never global ones — the ambiguity that would otherwise compute a plausible, wrong answer in
silence. Routing happens once, at capture entry, immediately before normalisation. A test asserts
that a click on a secondary display normalises against that display's geometry and not the main
display's.

### D-P3 — Package document, immutable media, atomic manifest

```
MyDemo.soredemo/                 UTType(exportedAs:conformingTo: .package)
├─ project.json                  small · atomically replaced on save
├─ media/
│   ├─ master-01H….mov           write-once, never mutated
│   └─ mic-01H….caf              write-once, never mutated
└─ observations/
    └─ log-01H….jsonl            append-only
```

`ARCHITECTURE.md` D5 says "atomic writes" without addressing that the package holds gigabytes. The
textbook temp-directory-and-rename copies every byte on every save. Instead: **media sidecars are
written once under unique names and never mutated**, so the only thing a save must make atomic is
the small manifest, via `replaceItemAt`. Saves stay in milliseconds regardless of footage size and
work on any filesystem, including a non-APFS external drive.

The `previous` snapshot (F1) identifies sidecars that became unreferenced. They are swept on an
explicit compact operation, never as a side effect of saving — a save must not be able to delete
media.

**Atomicity is not durability, and we are choosing atomicity.** `replaceItemAt` guarantees the
rename is atomic — a reader sees the old manifest or the new one, never a torn one. It does *not*
guarantee the bytes reached the platter: macOS `fsync` may leave data in the drive's write cache,
and only `fcntl(F_FULLFSYNC)` forces it out. So a power cut milliseconds after a save can lose that
save while leaving the previous manifest intact and valid.

For a video editor that trade is acceptable: the cost of losing it is one save's worth of edit
state, the media itself is already durable because it was written once and closed, and
`F_FULLFSYNC` on every autosave is a visible stall. **Recorded as a decision, not an omission** —
if a later phase makes a save expensive to lose, `F_FULLFSYNC` goes in front of the rename and the
cost is understood.

**Append-only logs need a truncated-tail rule.** A crash mid-write leaves `observations/*.jsonl`
with a partial final line. The reader discards an incomplete trailing line and reports how many
bytes it dropped; it does not error, and it does not attempt repair. Silence here would turn a
crash into a quietly shortened observation log, and a log that is short by one record is a
derivation that is wrong with no diagnostic. A test appends a truncated line and asserts both the
discard and the report.

*Rejected:* APFS `clonefile` + `renamex_np(RENAME_SWAP)` — genuinely cheap whole-package atomicity
on APFS, but needs a full byte-copy fallback for exFAT/SMB, which is the cost being avoided.
*Rejected:* full temp copy — correct everywhere, unusable at this data size.
*Rejected:* single file with embedded media — AVFoundation needs a file URL to stream from, so
embedding means extracting on every open.
*Rejected:* single file plus sibling media folder — the "media offline" bug by construction.

### D-P4 — Citation is a field of the value's type

```swift
public struct Derived<Value: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public let value: Value
    public let origin: Origin
    public var review: ReviewState

    /// Canonical bytes an approval is bound to: `value` + `origin`, never `review`.
    /// Approving mutates `review`; if the bound digest covered it, the act of approving
    /// would invalidate the approval it just recorded. Phase 8's `approval-gate` reads this,
    /// but the definition belongs here, where the fields are declared.
    ///
    /// The package emits the bytes and the app hashes them, per § Two digests — so this is
    /// `Data`, not a `ContentDigest`.
    public var approvalBytes: Data { get }
}

public enum Origin: Codable, Hashable, Sendable {
    case generated(Derivation)      // cannot be spelled without evidence
    case authored(Authorship)       // human; wins, always; carries no Derivation
}

public struct Derivation: Codable, Hashable, Sendable {
    public let producer: ProducerID          // stable code, e.g. "framing.target"
    public let producerVersion: Int
    public let evidence: Evidence            // non-empty by construction — see below
    public let outcome: Outcome              // .accepted | .rejected(GateCode)
}

/// A citation with no evidence is not a citation. `[EvidenceRef]` permits `[]`, so the
/// non-empty guarantee needs a type that cannot represent emptiness. Defined below.

public struct EvidenceRef: Codable, Hashable, Sendable {
    public let kind: EvidenceKind            // .observation | .transcript | .release
    public let id: EvidenceID
    public let contentDigest: ContentDigest  // evidence as cited → staleness AND approval
    public let sourceInterval: TimeRange?    // for written-steps citing its interval
}
```

#### Two digests, deliberately not the same primitive

`GeometryRevision` and `EvidenceRef` both "hash content", and that resemblance is a trap. They have
different threat models:

| | `GeometryRevision` | `ContentDigest` |
| --- | --- | --- |
| Purpose | identity, registry lookup | staleness **and** `approval-gate` binding |
| Adversary | none — inputs are the window server's | external text, attacker-controllable per `agentic-threat-model` |
| Primitive | FNV-1a, 64-bit, non-cryptographic | SHA-256, 32 bytes, opaque |
| Computed by | `SoredemoCore` (pure, deterministic) | the **app target**, via CryptoKit |

A 64-bit non-cryptographic digest on the evidence path would be a real hole rather than a
theoretical one: Phase 8's `approval-gate` binds per-post human approval to a content hash, and
`ARCHITECTURE.md` § Agentic security states that release notes and PR titles are attacker-controlled
on a repository accepting contributions. FNV-1a collisions can be constructed to order, so an
approval could be bound to reviewed text and redeemed against substituted text.

```swift
/// Opaque. SoredemoCore compares digests; it never computes one.
public struct ContentDigest: Hashable, Codable, Sendable {
    public let bytes: Data                   // 32, validated on decode
    public init(validating: Data) throws
}
```

The package cannot compute SHA-256 without either importing CryptoKit (violating D6) or
hand-rolling a hash function, which is the wrong way to obtain one. So the digest is **injected**:
whoever produces the evidence computes it and passes the value in. That matches how time and
randomness are handled (§ Determinism), and it keeps `SoredemoCore` a pure comparator.

The two are also kept apart by name — `fnv1a64` is internal to `Geometry` and is not visible to
`Graph`, so there is no route by which the identity hash reaches the evidence path.

#### `Evidence`: a non-empty collection that behaves

```swift
public struct Evidence: Codable, Hashable, Sendable, RandomAccessCollection {
    public let head: EvidenceRef             // NOT `first` — see below
    public let tail: [EvidenceRef]

    public init(_ head: EvidenceRef, _ tail: [EvidenceRef] = [])
    /// Phase 3's framing producers hold `[EvidenceRef]`; Swift cannot splat an array
    /// into a variadic parameter, so an array entry point is required, not optional.
    public init?(_ refs: [EvidenceRef])      // nil on empty
}
```

Naming the stored property `first` compiles but resolves differently by path, which was verified
rather than assumed:

```
viaConcrete(e) → Ref              // the stored property shadows Collection.first
viaGeneric(e)  → Optional<Ref>    // the protocol requirement, through a generic context
```

No warning, no error, and a type that changes with how the value is reached. `head` avoids it.

`Evidence` encodes as a flat JSON array and decodes by rejecting an empty one, so the guarantee
survives a round-trip through disk and is not merely an in-memory invariant.

An uncited generated value is therefore **unrepresentable**. Phase 6's `evaluations-harness` then
asserts a property the type system already guarantees, and the `agentic-threat-model` requirement —
that injected text cannot manufacture an approvable claim — has a structural floor rather than a
validator someone might forget to call.

**What the type system does not do.** It guarantees that anything generated cites evidence. It does
*not* by itself stop a producer replacing an `.authored` value wholesale, because a producer that
writes a fresh `Derived` overwrites whatever was there. The producer-value rule therefore needs one
enforced write path:

```swift
extension Derived {
    /// The only way a producer may write a result. Authored values are returned untouched.
    public func applyingProduced(_ produced: Derived<Value>) -> Derived<Value> {
        if case .authored = origin { return self }      // authored always wins
        return produced
    }
}
```

Producers never assign to a `Derived` directly; `ArchitectureCheck` rule 7 arrives in Phase 3 to
enforce that `applyingProduced` is the sole writer. In Phase 1 the rule is carried by the
producer-value tests, which is the bar `KICKOFF.md` sets for this row.

`Derivation.outcome` carries rejections as first-class citations, which is what `framing-gates`
(Phase 3) and `explain_framing` (Phase 6) read.

**Reverse index.** "What depended on observation X" — needed by `text-based-editing` to invalidate
exactly the dependent beats — is computed from the forward edges and cached. Under the cache-pairing
rule it ships with a hit test and an invalidation test in the same commit.

*Rejected:* side-table provenance graph — equal cost in both directions, but a value can exist with
no edge pointing at it, making "uncited claims cannot be approved" a runtime check rather than a
compile-time guarantee.
*Rejected:* both representations — two records of one fact that drift apart silently.
*Rejected:* per-producer citation protocol — the review UI and `explain_framing` would handle N
shapes, and each new producer is a chance to define citation slightly differently.

---

## Geometry: the Y-axis flip

D3's rationale — bottom-left "matching CoreGraphics so the render path never flips" — is correct
about rendering and misleading about everything else. Every input source in Phase 2 is top-left:

| Source | Origin | Consumer |
| --- | --- | --- |
| Core Image, `CGContext` | **bottom-left** | `render-core`, `export-basic` |
| `CGDisplayBounds` | top-left | display enumeration |
| `CGEventGetLocation` | top-left | `input-observation` |
| AX `kAXPositionAttribute` | top-left | `ax-observation` |
| `NSScreen.frame` | bottom-left | AppKit — disagrees with CoreGraphics |

There is a flip. The design's obligation is that it happens exactly once, on entry, and never again.

```swift
public struct NormalizedPoint: Hashable, Codable, Sendable {   // 0…1, bottom-left
    public let x, y: Double
}
public struct NormalizedSize: Hashable, Codable, Sendable {
    public let width, height: Double
}
public struct NormalizedFrame: Hashable, Codable, Sendable {
    public let origin: NormalizedPoint
    public let size: NormalizedSize
    public let revision: GeometryRevision
}

/// The one conversion point. The only Y-flip in the codebase.
public struct NormalizationContext: Sendable {
    public let geometry: DisplayGeometry
    public func normalize(topLeftX: Double, topLeftY: Double,
                          width: Double, height: Double) -> NormalizedFrame
    public func denormalize(_ frame: NormalizedFrame) -> PixelRect
}

/// Plain Doubles. Not CGRect — this type may cross the module boundary.
public struct PixelRect: Hashable, Sendable { public let x, y, width, height: Double }
```

`CGRect` and `CGPoint` never enter `SoredemoCore`. The app target holds exactly one file,
`Soredemo/Capture/CGGeometryBridge.swift`, converting `CGRect ↔ PixelRect`, and `ArchitectureCheck`
allow-lists that single filename.

Cross-revision comparison is a precondition failure:

```swift
extension NormalizedFrame {
    public func contains(_ other: NormalizedFrame) -> Bool {
        precondition(revision == other.revision,
            "geometry revision mismatch: \(revision.id) vs \(other.revision.id)")
        …
    }
}
```

---

## Project format

The row spans the D6 boundary because of F2. The split is not a compromise — the API asks for it.
`snapshot(contentType:)` is `@MainActor` and returns a `sending` value consumed by a `@concurrent`
writer, so the snapshot type must be a pure sendable value, which is exactly a `SoredemoCore` type.

```
Packages/SoredemoCore/Project     (Foundation)
    ProjectSnapshot: Codable, Sendable        schema version, graph, GeometryRegistry
    ProjectUpgrade                            v0→v1→… chain
    ProjectPackageReader / Writer             plain URL + FileManager, no SwiftUI
        ▲
        │ conformance only, ~40 lines
Soredemo/UI/ProjectDocument.swift  (SwiftUI)
    final class ProjectDocument: @MainActor Document
```

Strict concurrency shape, established by the compiled probe:

```swift
@MainActor @Observable
final class ProjectDocument: @MainActor Document {          // isolated conformance required
    nonisolated static var readableContentTypes: [UTType] { [.soredemoProject] }
    nonisolated func reader(configuration: sending DocumentReadConfiguration) -> sending PackageReader
    nonisolated func writer(configuration: sending DocumentWriteConfiguration) -> sending PackageWriter
    func apply(snapshot: sending ProjectSnapshot, previous: sending ProjectSnapshot?) async throws
    func snapshot(contentType: UTType) async throws -> sending ProjectSnapshot
}
```

Without `: @MainActor Document` the conformance fails with `#ConformanceIsolation`; without
`nonisolated` on `readableContentTypes` it cannot satisfy the nonisolated requirement.

**Versioning.** Decode a two-field probe first, then dispatch:

```swift
struct SchemaProbe: Decodable { let schemaVersion: Int }
```

- `found > current` → throw `ProjectError.unsupportedFutureVersion(found:supported:)`. Never
  partial-decode: a partial decode followed by a save destroys fields a newer build wrote.
- `found < current` → apply upgrades in sequence.
- `found == current` → decode directly.

All media paths in the manifest are relative to the package root, so the package can move.

---

## Test plan

Swift Testing (`@Test`, `#expect`, `#require`) throughout. No XCTest.

**Mandatory forms, per `AGENTS.md` and `KICKOFF.md`:**

- **Producer-value rule** — for every producer: run it, obtain `.generated`; then set `.authored`
  with a value the producer could not have derived; re-run; assert the authored value survives
  unchanged and `origin` is still `.authored`.
- **Cache pairing** — the reverse-dependency index gets a hit test and an invalidation test in the
  same commit.

**Per-row completion criteria** (`KICKOFF.md` § What "done" means):

| Row | Done when |
| --- | --- |
| `repo-skeleton` | `xcodebuild` succeeds and the app launches to an empty window |
| `architecture-plugin` | `import AppKit` in `SoredemoCore` **fails the build**, with a test proving it |
| `geometry` | comparing two `NormalizedFrame`s of differing `geometryRevision` traps, with a test |
| `project-format` | a v1 document round-trips and a synthetic v0 document upgrades |
| `derivation-graph` | the producer-value rule holds under test |

Additional tests this design requires:

- `fnv1a64` pins known input to known output, and a second test asserts the digest is stable across
  processes (guarding the `Hasher` seeding trap in D-P2).
- Identical `DisplayGeometry` in two independently-constructed registries yields one revision.
- `GeometryRegistry.insert` traps when two different geometries produce one revision.
- `DisplayGeometry` rejects non-finite and non-positive `scale` on construction.
- **Rearranging displays changes no revision.** Build an arrangement, move a placement's global
  origin, assert every `GeometryRevision` is unchanged — the regression test for keeping extrinsic
  data out of the digest.
- **A click on a secondary display normalises against that display**, not the main one.
- `Evidence(refs:)` returns `nil` on an empty array, and a decoded empty array is rejected.
- `Evidence.head` and `Evidence.first` are both reachable and the collection conformance is
  consistent, since this is the shadowing case that compiles either way.
- **Determinism:** encoding the same snapshot twice yields byte-identical output.
- `approvalBytes` is unchanged by a transition of `review`, and changes when `value` or `origin`
  changes.
- A save leaves every media sidecar byte-identical; a compact — and only a compact — removes an
  unreferenced one.
- A `.jsonl` log with a truncated final line reads back with that line discarded and the dropped
  byte count reported.
- `unsupportedFutureVersion` throws rather than partial-decoding, and the on-disk file is unmodified
  afterwards.

`repo-skeleton`'s launch check is **blocked**: this machine runs macOS 26.5.2 (`25F84`) with no
macOS 27 volume, so a `.macOS(.v27)` target compiles but cannot launch. The row stays ◐ until the
volume exists per `TOOLCHAIN.md` § 2. Rows 2–5 are pure-package work verifiable by `swift test` and
are not blocked.

`derivation-graph` has no real producer in Phase 1 — observations arrive in Phase 2. `KICKOFF.md`
sets its bar at "the producer-value rule holds under test", so it ships with a reference producer
exercised by tests, and the completion rule is satisfied by `observation-ingest` in Phase 3. This is
noted rather than silently accepted.

---

## `Plugins/ArchitectureCheck`

A SwiftPM **build-tool** plugin; a non-zero exit fails the build. Given F4 it is the primary
enforcement of D6, so it runs on every build rather than on demand.

Checks:

1. **Import allow-list per target.** `SoredemoCore` targets may import Foundation and their declared
   siblings only. This is the D6 rule the compiler does not enforce.
2. **No `CGPoint`/`CGRect`/`CGSize` in the package's public API.**
3. **Single-file allow-list** for the `CGRect ↔ PixelRect` bridge.
4. **Determinism: no ambient time or randomness.** See § Determinism — an import allow-list cannot
   catch this, so it is a separate symbol scan.
5. **Empty dependency list in `Package.swift`.** The package declares no external dependencies at
   all; a plugin that polices imports while a manifest quietly adds a package is checking the wrong
   door.
6. **One owner for the observation-log → graph join** — inert in Phase 1, in place for Phase 3.
7. **`applyingProduced` is the sole writer of a `Derived`** — inert in Phase 1, in place for Phase 3.

### Determinism

`ARCHITECTURE.md` D6 rests derivation correctness on determinism: "a framing stage that could call
ScreenCaptureKit could observe the world mid-derivation, and then staleness, `isCurrent`, and
content-hash approval all stop meaning anything." Ambient time and randomness break that identically
to a framework call, and are far easier to introduce by accident.

The concrete Phase 1 exposure is the ULID naming `media/master-01H….mov` and the values behind
`EvidenceID`: a ULID is a timestamp plus random bytes. If either is minted inside `SoredemoCore`,
the package stops being a deterministic function of its inputs.

**`Date()`, `Date.now`, `UUID()`, `.random(in:)`, `SystemRandomNumberGenerator`, `DispatchTime.now()`
and `ContinuousClock` are all in Foundation and the standard library.** The import allow-list from
rule 1 cannot see them, and neither can a cross-platform build. Hence a dedicated symbol scan over
`Packages/SoredemoCore`, and a rule that IDs and timestamps are minted in the app target and passed
in as plain values — the same shape as the injected `ContentDigest`.

A test constructs a snapshot twice from identical inputs and asserts byte-identical encodings, which
fails if anything ambient leaks in.

Its own test suite includes a fixture target that violates each rule and asserts the plugin rejects
it. Per `AGENTS.md`: changing a rule changes the plugin in the same commit.

---

## Row order

`architecture-plugin` moves ahead of `geometry`, against the order in `ROADMAP.md`. F4 is the
reason: the Foundation-only rule is unenforced until the plugin exists, so every row built before it
is a row that could violate D6 undetected. The dependency (`repo-skeleton`) is unchanged.

1. `repo-skeleton` — package + app target, builds; launch check deferred to the beta volume
2. `architecture-plugin` — import allow-list, public-API check, bridge allow-list
3. `geometry` — `NormalizedPoint`/`Frame`, `GeometryRevision`, `NormalizationContext`
4. `derivation-graph` — `Derived`, `Origin`, `Derivation`, `EvidenceRef`, reverse index
5. `project-format` — `ProjectSnapshot`, upgrade chain, package reader/writer, app conformance

`project-format` moves after `derivation-graph` because the snapshot embeds the graph.

---

## Document corrections

Per `AGENTS.md` — "when a document is wrong, say so… the code usually wins and the document gets
fixed in the same commit."

| Document | Claim | Correction | Lands with |
| --- | --- | --- | --- |
| `ARCHITECTURE.md` D6 mechanism 1 | "The compiler. `import AppKit` in the package is a build failure" | False (F4). The plugin enforces it. | `architecture-plugin` |
| `AGENTS.md` architecture rule 1 | "The compiler enforces it; do not work around it" | Same correction | `architecture-plugin` |
| `ARCHITECTURE.md` D5 | "`DocumentCreationSource` maps onto the entry points" | Unavailable on macOS (F3); entry points built by hand | `project-format` |
| `ARCHITECTURE.md` D3 | bottom-left "so the render path never flips" | True for render; CG/AX/event inputs are top-left. One flip, at capture entry | `geometry` |
| `ARCHITECTURE.md` § To verify, item 1 | open question on packages | Resolved (F1): packages work, no coordinator | `project-format` |
| `ROADMAP.md` `project-format` row | lists `ReadableDocument`/`WritableDocument` | SwiftUI types (F2); row spans the boundary | `project-format` |

---

## Out of scope

Recording, rendering, framing, the timeline, variants, the app's real UI, and the MCP surface. Phase
1 delivers an app that launches empty, a package that cannot violate its own rules, and the three
data structures every later phase is expressed in.
