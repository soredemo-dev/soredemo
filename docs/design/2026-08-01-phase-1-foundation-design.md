# Phase 1 — Foundation: design

*Covers `repo-skeleton`, `architecture-plugin`, `geometry`, `project-format`, `derivation-graph`.*

Every SDK claim below was tested against the macOS 27 SDK (Xcode 27 beta 4, `27A5228h`, Swift 6.4)
by compiling or building, not read from documentation. Findings that contradict an existing
document are listed in § Document corrections and are fixed alongside the code that depends on them.

---

## SDK findings

### F1 — SwiftPM does **not** restrict system-framework imports

A target with zero declared dependencies, importing `AppKit` and `ScreenCaptureKit` and calling
`NSColor.red`, builds successfully:

```
[94 / 102] PureTarget
Build complete! (10.01秒)
```

Everything in the SDK is importable from any target. `ARCHITECTURE.md` D6 mechanism 1 and
`AGENTS.md` architecture rule 1 both credit the compiler with enforcing the Foundation-only rule.
It does not. **`Plugins/ArchitectureCheck` is the primary enforcement of D6, not a supplement.**

### F2 — SwiftPM **does** enforce edges between package targets

Adding `import Graph` to the `Geometry` leaf fails:

```
error: module dependency cycle: 'Geometry (Source Target) -> Graph.swiftmodule -> Geometry.swiftmodule'
error: Build failed
```

An undeclared import that is not also cyclic fails as `no such module`. So the module map is a
compile error, which is what D-P1 rests on — and note the contrast with F1: SwiftPM polices the
package's internal edges while policing nothing about system frameworks. That gap is exactly what
the plugin fills.

### F3 — The macOS 27 `Document` protocol handles packages, but is unavailable at our floor

`DocumentReader.Source` and `DocumentWriter.Destination` are generic associated types merely
defaulting to `URL`, so a directory URL works and a reader may read one small manifest while leaving
gigabytes on disk. Verified by compiling such a `Document` clean under `-swift-version 6
-strict-concurrency=complete -target arm64-apple-macos27.0`.

But the protocols live in **SwiftUI**, not Foundation:

```
SwiftUI.swiftinterface:1812   public protocol ReadableDocument : AnyObject
SwiftUI.swiftinterface:1822   public protocol WritableDocument : AnyObject
```

and they are `@available(macOS 27, *)`. At a macOS 26 floor (D2) they are unusable. `KICKOFF.md`
anticipated this branch: *"if the answer is single-file only, `project-format` needs a hand-written
package coordinator and that changes the row."* It fires for a different reason than anticipated —
the target floor, not the API's capability — but the consequence is the one predicted.

Also recorded, now moot: `DocumentCreationSource.init(id:)` is `@available(macOS, unavailable)`, as
is its only consumer `NewDocumentButton`. `ARCHITECTURE.md` D5 claims it maps onto the entry points;
on macOS it cannot.

### F4 — `NSDocument` satisfies the storage design on macOS 26

The replacement was verified, not assumed. This compiles clean under `-swift-version 6
-strict-concurrency=complete -target arm64-apple-macos26.0`:

- `read(from url: URL, ofType:)` receives the package **directory** and decodes `project.json`
  alone; media is never touched.
- `writeSafely(to:ofType:for:)` is overridden to bypass `NSDocument`'s whole-package copy and
  atomically replace only the manifest.

**Cost, recorded up front rather than discovered later:** `NSDocument`'s `read` and `writeSafely`
are **nonisolated**. Marking them `@MainActor` is a hard compile error —
`main actor-isolated instance method 'read(from:ofType:)' has different actor isolation from
nonisolated overridden declaration`. Document state therefore needs explicit synchronisation; the
probe used a `Mutex`. The macOS 27 protocol avoided this by making `snapshot(contentType:)`
`@MainActor` and handing a `sending` value to a `@concurrent` writer. This is an ongoing tax, not a
one-off.

### F5 — Everything else Phase 2–5 needs is available on macOS 26

| API | Introduced |
| --- | --- |
| `SCContentSharingPicker` | `macos(14.0)` |
| `SCRecordingOutput` | `macos(15.0)` |
| `SpeechAnalyzer`, `SpeechTranscriber`, `AssetInventory` | `anyAppleOS 26` |
| `NavigationSplitView` | `macOS 13.0` |
| `CGEvent.tapCreate`, `AXUIElement`, `CMClock`, `CADisplayLink` | long-standing |

`Speech.swiftinterface` contains **no `26.x` point-release gate** — every annotation is
`anyAppleOS 26`, `anyAppleOS 27`, `macOS 14` or `macOS 15`. So a **26.0** floor is safe and covers
26.0–26.4 users at no cost.

### F6 — Manifest facts

- `.strictConcurrency` is **not** a `SwiftSetting`: `error: type 'SwiftSetting' has no member
  'strictConcurrency'`. The correct spelling is `.swiftLanguageMode(.v6)`, which implies complete
  concurrency checking. `.strictMemorySafety()` is available and also enabled.
- `swift-tools-version: 6.4` is kept. (It is *required* only for `.macOS(.v27)`; retained for the
  newer manifest API surface.)

### F7 — Link-time symbols are exact for determinism checking

A module calling `Date()`, `UUID()` and `Int.random(in:)` emits these undefined symbols:

```
_$s10Foundation4DateVACycfC                      Foundation.Date.init()
_$s10Foundation4UUIDVACycfC                      Foundation.UUID.init()
_$ss17FixedWidthIntegerPsE6random2inxSnyxG_tFZ   FixedWidthInteger.random(in:)
```

Every syntactic evasion — interpolation, raw strings, `Date .init()`, whitespace, computed
indirection — collapses into the same mangled symbol. This is the correct mechanism for the
determinism rule; text scanning is a proxy for a semantic question, which is why it leaks.

### F8 — `PBXFileSystemSynchronizedRootGroup` picks up subfolders

The app project (`objectVersion 77`) uses Xcode's synchronised folders. Moving sources into
`App/`, `UI/`, `Resources/` and adding new subfolders builds with **zero** `project.pbxproj` edits —
verified by performing exactly that move on a copy and building successfully.

Corollary, learned the hard way: hand-editing `project.pbxproj` to add an
`XCLocalSwiftPackageReference` fails. At `objectVersion 110` the project became unreadable
(`Unable to read project`); at `objectVersion 77` it parses but the module still does not resolve.
**Package dependencies are added in Xcode, not by editing the file.**

---

## Decisions

### D-P0 — Repository layout

Directory conventions follow `../opensource/a native editor`; its **module structure is explicitly
not adopted** (see D-P1).

```
soredemo-main/
├── Package.swift              SoredemoCore · swift-tools-version: 6.4 · .macOS(.v26)
├── Sources/{Geometry,Timeline,Graph,Framing,Variants,Project}/
├── Tests/{Geometry,Timeline,Graph,Framing,Variants,Project}Tests/
├── Plugins/ArchitectureCheck/
├── Metal/                     .metal sources, outside the Swift tree (Phase 2 render-core)
├── scripts/                   entitlements, bundle/release scripts (Phase 7)
├── docs/  assets/             assets/ is the renamed soredemo-brand-kit/
├── Soredemo.xcodeproj         app · objectVersion 77 · committed source of truth
└── Soredemo/{App,UI,Capture,Resources}/
```

Work happens on a branch **in the main checkout**, not a git worktree. A worktree under
`.claude/worktrees/` put the project at a hidden path while the owner worked interactively in
Xcode; the result was the wrong copy being opened and files landing in the wrong checkout twice.
One directory, one project, no ambiguity. `main` stays untouched as the rollback point.

*Rejected:* the app project nested at `Soredemo/Soredemo.xcodeproj` — an extra level, and paths like
`Soredemo/Soredemo/UI/`.
*Rejected:* XcodeGen generating the project from `project.yml` — the hand-made project already
carries `DEVELOPMENT_TEAM`, App Sandbox, Hardened Runtime and the real bundle identifier, which is
what Phase 7 needs, and `PBXFileSystemSynchronizedRootGroup` already provides the source-list
automation XcodeGen was wanted for (F8).

### D-P1 — One package, six modules

Six library targets whose SwiftPM dependency edges make `ARCHITECTURE.md`'s module map a compile
error rather than a naming convention (F2):

```
Geometry ─ no dependencies        Timeline ─ no dependencies
Graph    ← Geometry, Timeline     Framing  ← Graph, Geometry
Variants ← Framing, Timeline      Project  ← Graph, Geometry, Timeline
```

`Graph` depends on `Timeline` because `EvidenceRef.sourceInterval` cites a time range. `Timeline` is
a second leaf: it maps integer nanoseconds between source, camera and output timebases, and nothing
in that is spatial. `Framing` and `Variants` are where space and time meet, and both already depend
on each side.

`Framing` and `Variants` are empty in Phase 1; they exist to fix the dependency direction before
there is code to tangle.

**a native editor's shape is the counter-example, not the model.** It is one executable target whose 26
subfolders carry no compile-time boundary. Folders would be cosmetic and every internal boundary
would rest on review.

*Rejected:* one module — see above. *Rejected:* several packages — nothing here ships separately.
*Rejected:* splitting later — boundaries drawn after the coupling exists are drawn too late.

### D-P2 — `GeometryRevision` is a stable content digest, with a registry in the document

Identity is *the geometry*, not the event, so the same display configuration yields the same
revision in any session.

```swift
public struct GeometryRevision: Hashable, Codable, Sendable { public let id: UInt64 }

public struct DisplayGeometry: Hashable, Codable, Sendable {
    public let displayUUID: UUID        // persistent — NOT CGDirectDisplayID
    public let pixelWidth: Int, pixelHeight: Int
    public let scale: Double            // finite, > 0; digested as .bitPattern
    public var revision: GeometryRevision { GeometryRevision(id: fnv1a64(canonicalBytes)) }
}
```

Two properties this buys: a display that changes and changes back restores comparability, because
the geometry genuinely is the same; and two sessions that shared a display agree without
coordination, which `selective-rerecord` (Phase 4) needs.

**`CGDirectDisplayID` must not enter the digest.** It is assigned dynamically by the window server
and is not stable across reboot or replug. Using it would make this decision's own justification
false: record Monday, reboot, record Tuesday on the same monitor at the same resolution, and one
document holds two revisions for identical geometry — a precondition failure on a genuinely
comparable pair, which is the exact failure a counter scheme was rejected for. The persistent
identity is `CGDisplayCreateUUIDFromDisplayID` (`ColorSyncDevice.h:233`), bridged to a Foundation
`UUID`, looked up in the app and passed in as a plain value.

Display identity stays *in* the digest: two identical monitors side by side would otherwise collapse
to one revision, and "40% across *a* display" is not a comparable coordinate when there are two.

**Global arrangement must stay out.** `CGEventGetLocation` returns coordinates spanning every
display, so routing a click requires each display's global origin — which `DisplayGeometry`
deliberately lacks. Digesting it would be worse than omitting it: `CGDisplayBounds` origins shift
when the arrangement changes, and promoting a different display to main re-bases the whole global
space, so rearranging display B would silently invalidate footage from display A.

```swift
/// Extrinsic. NOT digested. Used at capture entry only, to route a global point to its display.
public struct DisplayArrangement: Sendable {
    public struct Placement: Sendable {
        public let geometry: DisplayGeometry
        public let globalOriginX, globalOriginY: Double   // top-left, global space
    }
    public let placements: [Placement]
    public func route(globalTopLeftX: Double, globalTopLeftY: Double)
        -> (geometry: DisplayGeometry, localX: Double, localY: Double)?
}
```

**The digest must not be `Hashable.hashValue`** — Swift's `Hasher` is randomly seeded per process,
so a persisted `hashValue` will not match the same geometry on reopen. FNV-1a over a canonical
little-endian encoding, with `scale` digested as `.bitPattern` (exact, where a decimal rendering is
not) and a precondition rejecting non-finite or non-positive scale.

`GeometryRegistry.insert` traps when one revision maps to two distinct geometries. FNV-1a is 64-bit
and non-cryptographic; a collision would make two different geometries compare **equal**, which is
the silent direction, and it is detectable exactly there.

*Rejected:* monotonic session counter — collides on merge, false-traps on flip-back.
*Rejected:* UUID per epoch — merges safely but still false-traps, and is opaque in a log.
*Rejected:* inline self-describing geometry in every frame — costs ~16 bytes across millions of
observation records and puts pixel values in the type that crosses module boundaries.

### D-P3 — Package document, immutable media, atomic manifest

```
MyDemo.soredemo/                 UTType(exportedAs:conformingTo: .package)
├─ project.json                  small · atomically replaced on save
├─ media/…                       write-once, never mutated
└─ observations/…jsonl           append-only
```

`ARCHITECTURE.md` D5 says "atomic writes" without addressing gigabytes. The textbook
temp-directory-and-rename copies every byte on every save. Instead **media sidecars are written once
under unique names and never mutated**, so the only thing a save must make atomic is the small
manifest, via `replaceItemAt`. Saves stay in milliseconds regardless of footage size and work on any
filesystem. Unreferenced sidecars are swept on an explicit compact, never as a side effect of
saving — a save must not be able to delete media.

**Atomicity is not durability, and we are choosing atomicity.** `replaceItemAt` guarantees a reader
sees the old manifest or the new one, never a torn one; it does not guarantee the bytes reached the
platter, which needs `fcntl(F_FULLFSYNC)`. Losing one save's edit state to a power cut is acceptable
— the media is already durable because it was written and closed. Recorded as a decision, not an
omission.

**Append-only logs need a truncated-tail rule.** A crash leaves a partial final line; the reader
discards it and reports how many bytes it dropped. Silence would turn a crash into a quietly
shortened observation log, and a log short by one record is a derivation that is wrong with no
diagnostic.

Because of F3/F4 the coordinator is hand-written over `NSDocument` rather than the macOS 27
protocol. The storage layout above is unaffected — it rests on `replaceItemAt`, which is Foundation.
What is lost is the newer API's incidental gift of a `previous` snapshot; the derivation graph
reconstructs that information itself.

*Rejected:* APFS `clonefile` + `renamex_np(RENAME_SWAP)` — cheap whole-package atomicity on APFS,
but needs a full byte-copy fallback for exFAT/SMB. *Rejected:* full temp copy — unusable at this
data size. *Rejected:* single file with embedded media — AVFoundation needs a file URL to stream
from. *Rejected:* single file plus sibling media folder — the "media offline" bug by construction.

### D-P4 — Citation is a field of the value's type

```swift
public struct Derived<Value: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public let value: Value
    public let origin: Origin
    public var review: ReviewState

    /// Canonical bytes an approval binds to: value + origin, never review.
    public var approvalBytes: Data { get }

    /// The only way a producer may write a result.
    public func applyingProduced(_ produced: Derived<Value>) -> Derived<Value>
}

public enum Origin: Codable, Hashable, Sendable {
    case generated(Derivation)      // cannot be spelled without evidence
    case authored(Authorship)       // human; wins, always
}

public struct Derivation: Codable, Hashable, Sendable {
    public let producer: ProducerID
    public let producerVersion: Int
    public let evidence: Evidence            // non-empty by construction
    public let outcome: Outcome              // .accepted | .rejected(GateCode)
}
```

**`Evidence` is a non-empty collection.** `[EvidenceRef]` permits `[]`, which would make "an uncited
generated value is unrepresentable" false. It stores `head` plus `tail`, encodes as a flat JSON
array and rejects an empty one on decode, so the guarantee survives disk. The stored property is
`head`, not `first`: a property named `first` shadows `Collection.first` and resolves as
`EvidenceRef` concretely but `EvidenceRef?` through a generic context, with no diagnostic either way
— verified by compiling both paths. It also needs an array initialiser, since Swift cannot splat an
array into a variadic and Phase 3's producers hold `[EvidenceRef]`.

**Two digests, deliberately not the same primitive.**

| | `GeometryRevision` | `ContentDigest` |
| --- | --- | --- |
| Purpose | identity, registry lookup | staleness **and** `approval-gate` binding |
| Adversary | none | external text, attacker-controllable |
| Primitive | FNV-1a, 64-bit | SHA-256, 32 bytes, opaque |
| Computed by | `SoredemoCore` | the **app**, via CryptoKit |

Phase 8's `approval-gate` binds per-post human approval to a content hash, over input
`ARCHITECTURE.md § Agentic security` designates attacker-controlled. FNV-1a collisions can be
constructed to order, so an approval could be bound to reviewed text and redeemed against
substituted text. The package **compares** digests and never computes one — computing SHA-256 there
would need CryptoKit (violating D6) or a hand-rolled hash. The digest is injected, the same shape as
time and randomness (§ Determinism). `fnv1a64` stays internal to `Geometry` and is not visible to
`Graph`, so there is no route by which the identity hash reaches the evidence path.

**`approvalBytes` covers `value` + `origin`, never `review`.** Approving mutates `review`; a digest
over it would invalidate the approval it just recorded. The package emits canonical bytes and the
app hashes them.

**The producer-value rule needs one enforced write path.** The type system guarantees that anything
generated cites evidence; it does not by itself stop a producer replacing an `.authored` value
wholesale. `applyingProduced` returns authored values untouched, and producers never assign to a
`Derived` directly.

**Reverse index.** "What depended on observation X" — needed by `text-based-editing` to invalidate
exactly the dependent beats — is computed from the forward edges and cached, so under the
cache-pairing rule it ships with a hit test and an invalidation test in the same commit.

*Rejected:* side-table provenance graph — equal cost in both directions, but a value can exist with
no edge pointing at it, making "uncited claims cannot be approved" a runtime check rather than a
compile-time guarantee. *Rejected:* both representations — two records of one fact that drift apart
silently. *Rejected:* per-producer citation protocol — the review UI and `explain_framing` would
handle N shapes.

---

## Geometry: the Y-axis flip

D3's rationale — bottom-left "matching CoreGraphics so the render path never flips" — is correct
about rendering and misleading about everything else:

| Source | Origin | Consumer |
| --- | --- | --- |
| Core Image, `CGContext` | **bottom-left** | `render-core`, `export-basic` |
| `CGDisplayBounds` | top-left | display enumeration |
| `CGEventGetLocation` | top-left | `input-observation` |
| AX `kAXPositionAttribute` | top-left | `ax-observation` |
| `NSScreen.frame` | bottom-left | AppKit — disagrees with CoreGraphics |

There is a flip. The obligation is that it happens exactly once, on entry, and never again.
`NormalizationContext` is that one place, and it takes **display-local** top-left pixels, never
global ones — the ambiguity that would otherwise compute a plausible, wrong answer in silence.
Routing happens first, via `DisplayArrangement.route`.

`CGRect`/`CGPoint` never enter the package; `PixelRect` (plain `Double`s) crosses boundaries
instead. The app holds exactly one file, `Soredemo/Capture/CGGeometryBridge.swift`, converting
`CGRect ↔ PixelRect`.

Cross-revision comparison is a precondition failure:

```swift
precondition(revision == other.revision,
    "geometry revision mismatch: \(revision) vs \(other.revision)")
```

---

## Determinism

`ARCHITECTURE.md` D6 rests derivation correctness on determinism. Ambient time and randomness break
it identically to a framework call and are far easier to introduce by accident. `Date()`,
`Date.now`, `UUID()`, `.random(in:)`, `SystemRandomNumberGenerator`, `DispatchTime.now()` and
`ContinuousClock` are all Foundation or standard library, so an import allow-list cannot see them.

IDs and timestamps are minted in the app and passed in as plain values, the same shape as
`ContentDigest`.

**The check is over link-time symbols, not source text** (F7). Text scanning is a proxy for a
semantic question and leaks: in a prior implementation `"\(Date())"` and `#"\#(Date())"#` both
passed while plain `Date()` was caught. Mangled symbols have no such gaps.

---

## `Plugins/ArchitectureCheck`

Given F1, this is the primary enforcement of D6, so it runs on every build.

| # | Rule | Mechanism |
| --- | --- | --- |
| 1 | Import allow-list per target | source text |
| 2 | No `CGPoint`/`CGRect`/`CGSize`/`CGFloat` in the package | source text |
| 3 | No ambient time or randomness | **link-time symbols** |
| 4 | Manifest declares no package dependencies | source text — scan for `.package(`, which is complete: `Package.Dependency` has no public initialiser |
| 5 | CG types in the app appear only in `Capture/CGGeometryBridge.swift` | a package **test** — the plugin attaches to SwiftPM targets and cannot see the Xcode app target |
| 6 | One owner for the observation-log → graph join | inert in Phase 1 |
| 7 | `applyingProduced` is the sole writer of a `Derived` | inert in Phase 1 |

The plugin is a build-tool plugin using `.buildCommand` with a stamp file. `.prebuildCommand` cannot
be used: SwiftPM prebuild commands cannot depend on an executable built from source. `Package.swift`
must be declared among `inputFiles`, or a manifest-only edit leaves the stamp current and rule 4
never runs on an incremental build — which is how people build.

Use `context.tool(named:).path`, **not** `.url`: `URL.path()` percent-encodes Xcode's `${BUILD_DIR}`
placeholder into `$%7BBUILD_DIR%7D` and breaks `xcodebuild`.

### The known evasion set

Rules 1 and 2 read source text, so they must survive these from the first commit rather than
discovering them one at a time. Each gets a test:

- `@preconcurrency import AppKit`, `@testable import`, `@_exported import`, stacked attributes
- `import AppKit; import Foundation` — semicolon-joined, either order
- `import class AppKit.NSColor` — submodule form
- `import<TAB>AppKit`, `import AppKit //comment`
- string interpolation hiding real code: `"\(Date())"`, nested `"\(f("lit", Date()))"`
- raw-string interpolation: `#"\#(Date())"#`, `##"\##(UUID())"##`, multiline `#"""…"""#`
- must still PASS: `import Foundation`, `// import AppKit`, `#"Date()"#`, `#"a \(b) c"#`,
  `"Date() is banned"`, a multiline string whose second line mentions `CGRect`, and
  `import Foundation /* comment */`

---

## Test plan

Swift Testing (`@Test`, `#expect`, `#require`). No XCTest.

**Mandatory forms:**

- **Producer-value rule** — for every producer: supply a value the producer could not have derived,
  assert the supplied value and its review state survive.
- **Cache pairing** — every cache-hit test paired with an invalidation test.

**The verification rule, adopted after three failures:** *a check that has never been observed RED
is not a known check.* Every verification step records the observed failure as well as the pass, or
states plainly that the failure was never seen. This is not only for tests the plan writes — it
binds the plan's own verification commands, which is where it previously failed:

- the plugin's tests passing was read as "the rule is enforced"; it proved only that *imagined*
  violations were blocked
- `xcodebuild ** BUILD SUCCEEDED **` was read as "the plugin works under Xcode" while the app had no
  reference to the package, so the package was never built there
- a grep reporting one deployment target collapsed two values and reported the wrong one; settings
  are confirmed with `-showBuildSettings`, never grep

**Per-row completion criteria.** `KICKOFF.md` says `architecture-plugin` is done when `import
AppKit` "fails the build". **Which build?** That ambiguity is why the rule was enforced under
`swift build` for four rounds while never running under `xcodebuild`. It must fail **both**, and
each is verified separately.

| Row | Done when |
| --- | --- |
| `repo-skeleton` | `xcodebuild` succeeds **and the app launches to an empty window** — now performable, since a `.macOS(.v26)` binary runs on this machine |
| `architecture-plugin` | `import AppKit` fails **`swift build`** and fails **`xcodebuild`**, each observed |
| `geometry` | cross-revision comparison traps, observed out-of-process |
| `project-format` | a v1 document round-trips and a synthetic v0 upgrades |
| `derivation-graph` | the producer-value rule holds under test |

---

## Document corrections

| Document | Claim | Correction |
| --- | --- | --- |
| `ARCHITECTURE.md` D6 · `AGENTS.md` rule 1 | the compiler blocks `import AppKit` | false (F1); the plugin enforces it. SwiftPM does police edges *between package targets* (F2) |
| `ARCHITECTURE.md` D1 | `Packages/SoredemoCore/` | package is at the repository root (D-P0) |
| `ARCHITECTURE.md` D2 | `.macOS(.v27)`, "ships when 27 is a year old" | `.macOS(.v26)`. The no-availability-branches rule survives unchanged; the ship-date argument does not |
| `ARCHITECTURE.md` D5 | `WritableDocument`/`ReadableDocument`/`DocumentCreationSource` | hand-written `NSDocument` coordinator (F3, F4). § To verify item 1: the API handles packages but is macOS 27 only, so it is moot |
| `ARCHITECTURE.md` D3 | bottom-left "so the render path never flips" | true for render; CG, event and AX inputs are top-left. One flip, at capture entry |
| `ROADMAP.md` `project-format` | lists `ReadableDocument`/`WritableDocument` | `NSDocument` coordinator; the row spans the package/app boundary |
| `docs/TOOLCHAIN.md` § 2 | macOS 27 beta volume required | not required at a 26 floor. Xcode 27 beta stays — it is the SDK |

---

## Out of scope

Recording, rendering, framing, the timeline, variants, the app's real UI, and the MCP surface.
Phase 1 delivers an app that launches empty, a package that cannot violate its own rules, and the
three data structures every later phase is expressed in.
