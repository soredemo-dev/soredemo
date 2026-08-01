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
Timeline    ← Geometry
Graph       ← Geometry, Timeline
Framing     ← Graph, Geometry
Variants    ← Framing, Timeline
Project     ← Graph, Geometry, Timeline
```

`Graph` depends on `Timeline` because `EvidenceRef.sourceInterval` cites a time range: a citation
that cannot name *when* in the recording it came from is not much of a citation.

*Rejected:* one module — folders would be cosmetic and every internal boundary would rest on review.
*Rejected:* several packages — nothing here ships separately; it buys manifests and resolution cost.
*Rejected:* split later — boundaries drawn after the coupling exists are boundaries drawn too late.

`Framing` and `Variants` are empty in Phase 1. They exist to fix the dependency direction before
there is code to tangle. Each has a test target asserting only that it builds.

### D-P2 — `GeometryRevision` is a stable content digest, with a registry in the document

Identity is *the geometry*, not the event. Same display configuration yields the same revision, in
any session.

```swift
public struct GeometryRevision: Hashable, Codable, Sendable { public let id: UInt64 }

public struct DisplayGeometry: Hashable, Codable, Sendable {
    public let displayID: UInt32
    public let pixelWidth: Int, pixelHeight: Int
    public let scale: Double
    public var revision: GeometryRevision { GeometryRevision(id: fnv1a64(canonicalBytes)) }
}

public struct GeometryRegistry: Codable, Sendable {
    public var entries: [GeometryRevision: DisplayGeometry]
    public var firstObserved: [GeometryRevision: Int64]   // ordering, kept out of identity
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
little-endian encoding of the four fields, written by us and covered by a test that pins known input
to known output.

Pixel dimensions appear only inside `DisplayGeometry` and the registry, honouring D3's rule that
nothing in between speaks in pixels.

*Rejected:* monotonic session counter — collides on merge, false-traps on flip-back.
*Rejected:* UUID per epoch — merges safely but still false-traps, and is opaque in a log.
*Rejected:* inline self-describing geometry in every frame — no registry lookup and a maximally
informative trap message, but it puts pixel values in the type that crosses module boundaries and
costs ~16 bytes across millions of observation records.

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
/// non-empty guarantee needs a type that cannot represent emptiness.
public struct Evidence: Codable, Hashable, Sendable, RandomAccessCollection {
    public let first: EvidenceRef            // at least one, structurally
    public let rest: [EvidenceRef]
    public init(_ first: EvidenceRef, _ rest: EvidenceRef... ) { … }
}

public struct EvidenceRef: Codable, Hashable, Sendable {
    public let kind: EvidenceKind            // .observation | .transcript | .release
    public let id: EvidenceID
    public let contentHash: UInt64           // evidence as cited → staleness
    public let sourceInterval: TimeRange?    // for written-steps citing its interval
}
```

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

Producers never assign to a `Derived` directly; `ArchitectureCheck` rule 4 is extended in Phase 3 to
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
- A save leaves every media sidecar byte-identical; a compact — and only a compact — removes an
  unreferenced one.
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
4. **One owner for the observation-log → graph join** — inert in Phase 1, in place for Phase 3.

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
