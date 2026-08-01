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

An undeclared import that is not also cyclic fails as `unable to resolve module dependency`.

**But only on a clean build.** Measured on this repository:

| | Result |
| --- | --- |
| `swift build` with a warm `.build` | `warning: 'Geometry' is missing a dependency on 'Graph'` → **Build complete!**, exit 0 |
| `swift build` after `rm -rf .build` | `error: unable to resolve module dependency: 'Graph'` → build fails |

Stale module artifacts leave the undeclared module visible, and the diagnostic degrades from error to
warning. `.treatAllWarnings(as: .error)` does **not** close this — the warning is emitted by the
dependency scanner rather than the compiler frontend, so warnings-as-errors never sees it. Verified.

Two consequences:

1. **Any verification of a dependency edge must clean first.** A warm `swift build` reports a false
   green, which is the failure mode this document's verification rule exists to catch — and it is
   how the very first task nearly recorded a passing check it had not observed.
2. **`ArchitectureCheck` rule 1 is stronger than SwiftPM here, not merely complementary.** The
   plugin reads source text and runs on every build, so it rejects `import Graph` in `Geometry`
   incrementally, where SwiftPM only warns. The contrast with F1 still holds — SwiftPM polices
   nothing about system frameworks — but the plugin also covers this incremental gap in the edges
   SwiftPM does police.

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
- **`swift-tools-version: 6.3`, not 6.4.** 6.4 is required only for `.macOS(.v27)`, which this
  design no longer targets, so it buys nothing — and it costs compatibility with the Xcode the
  project is actually opened in. Xcode 26.6 ships SwiftPM 6.3.3 and refuses a 6.4 manifest outright
  (`unexpectedly did not find the new dependency in the package graph`), while the command line
  points at Xcode-beta 27 and never showed it. Verified: tools 6.3 builds under **both** toolchains,
  and `.macOS(.v26)`, `.swiftLanguageMode(.v6)` and `.strictMemorySafety()` all survive at 6.3.

  The general shape is the one this document keeps running into: a check that only exercises one of
  two environments. `swift build` was green throughout while the environment the owner uses could
  not read the manifest at all.

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

**Why the package sits at the root is not "because a native editor does".** a native editor's manifest is at its
root because that package *is* the application — there is no app target to coexist with, so the
question never arises there and the reason does not transfer. The actual benefit here is smaller and
real: `swift build` and `swift test` run at the repository root with no `cd`, which is where every
command in the plan and every CI invocation starts. That is worth having; the resemblance to a native editor
is not an argument.

The cost is that `Sources/` at the root does not, by itself, say which code is the pure package and
which is the app. `Soredemo/` versus `Sources/` carries that distinction by name only — the
enforcement is D-P1's target boundaries, not the directory layout.

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

**Module names must not collide with the type names inside them.** `Timeline`, `Graph` and `Project`
are all names one would naturally give the main type in that module, and Swift cannot disambiguate
`Timeline.foo` between the module and the type — the workaround is writing `Timeline.Timeline`,
which then spreads. Renaming is free now and expensive later, so the principal types are named for
what they are rather than for their module: `Timeline` holds `Nanoseconds` and `TimeRange`, `Graph`
holds `Derived` and `Derivation`, `Project` holds `ProjectSnapshot`. No type may share its module's
name.

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

`GeometryRegistry` checks the same invariant in two places, with two different failure modes,
because the inputs differ in kind:

- **`insert` traps.** A collision reached during merge is a programmer error — a 64-bit
  non-cryptographic digest mapping two distinct geometries to one revision would make them compare
  **equal**, which is the silent direction, and it is detectable exactly there.
- **`init(from:)` throws.** A registry decoded from disk is *input*, not program state. A file that
  has been corrupted, hand-edited, or written by a future version must not crash the app on open.
  Decoding validates `key == recompute(value).revision` and throws on mismatch.

Trapping on untrusted input is how a bad file becomes an unopenable document.

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

### Canonical encoding

`approvalBytes` and every content digest depend on an encoding that is byte-identical for equal
values, across processes and across time. "Canonical" is defined here rather than assumed, because
three separate things break it and each fails silently.

**1. Swift's `Dictionary` does not encode deterministically.** When the key is not `String` or
`Int`, `Codable` synthesis emits an **unkeyed** container of alternating key/value in *iteration*
order — and iteration order comes from the per-process random hash seed. `JSONEncoder.sortedKeys`
does not help, because it sorts keyed containers only. Measured on a `[Revision: Geometry]` of the
same shape as `GeometryRegistry`, five runs produced five different encodings.

This is the same seeding hazard already recorded for `Hashable.hashValue` in D-P2, arriving through
a different door. Catching one and not the other is precisely the failure this document exists to
prevent.

> **Rule.** No type whose bytes are digested may rely on synthesised `Codable` for a dictionary.
> `GeometryRegistry` hand-writes `Codable`, encoding entries as an array sorted by `revision.id`.

**2. Field order and shape must be frozen.** Adding a field to `Derivation` in Phase 3, or
reordering existing ones, changes every previously computed digest. The failure is not a validation
error — it is validation silently checking a different thing, which is worse. Every canonical
encoding therefore begins with a **one-byte encoding version**, and the encoding is frozen: changing
it is an explicit breaking change that ships with a re-approval path.

> This version is **not** `ProjectSnapshot.schemaVersion`. A document schema upgrade must leave
> existing approvals verifiable; the two version lines move independently.

**3. Floating point needs a bit-exact rule.** `scale` and all normalised coordinates are digested as
`.bitPattern`, never as a decimal rendering, with preconditions rejecting non-finite values so the
encoding is well-defined.

A test encodes the same value in two separate processes and compares bytes. Running it twice in one
process proves nothing — the seed is fixed for a process's lifetime, which is why this class of bug
survives ordinary testing.

---

## `Plugins/ArchitectureCheck`

Given F1, this is the primary enforcement of D6, so it runs on every build.

| # | Rule | Mechanism |
| --- | --- | --- |
| 1 | Import allow-list per target | source text |
| 2 | No `CGPoint`/`CGRect`/`CGSize`/`CGFloat` in the package | source text |
| 3 | No ambient time or randomness | **link-time symbols** — mechanism unresolved, see below |
| 4 | Manifest declares no package dependencies | source text — scan **every** manifest for `.package(` |
| 5 | CG types in the app appear only in `Capture/CGGeometryBridge.swift` | a package **test** — the plugin attaches to SwiftPM targets and cannot see the Xcode app target |
| 6 | One owner for the observation-log → graph join | inert in Phase 1 |
| 7 | `applyingProduced` is the sole writer of a `Derived` | inert in Phase 1 |

The plugin is a build-tool plugin using `.buildCommand` with a stamp file. `.prebuildCommand` cannot
be used: SwiftPM prebuild commands cannot depend on an executable built from source. `Package.swift`
must be declared among `inputFiles`, or a manifest-only edit leaves the stamp current and rule 4
never runs on an incremental build — which is how people build.

Use `context.tool(named:).path`, **not** `.url`: `URL.path()` percent-encodes Xcode's `${BUILD_DIR}`
placeholder into `$%7BBUILD_DIR%7D` and breaks `xcodebuild`.

### Rule 3's mechanism is unresolved, and that is written here rather than discovered

Rule 3 reads link-time symbols, but a build-tool plugin's command runs **before** its target
compiles, so the object files do not exist when it runs. The mechanism must be established before
the approach is committed to. Candidates:

- **A test that builds and inspects.** Preferred. It needs no one to remember to invoke it, and it
  runs wherever the suite runs. The whole point of D-P4 is to avoid *a validator someone might
  forget to call*; a rule with the same weakness is the same mistake one level up.
- A separate check target that depends on the six libraries, so its command runs after they compile.
- A post-build script phase in the Xcode project — but that only fires under `xcodebuild`, which is
  half the enforcement, and it needs a pbxproj edit (F8).

If none works cleanly, the honest outcome is a documented gap, not a symbol check nobody can prove
runs.

### Rule 4 reads source text too, so it needs its own evasion list

The rules that read source text are 1, 2 **and 4**. Rule 4 currently sits where rules 1 and 2 sat
before four rounds of hardening, and `.package(` being unforgeable says nothing about *which file*
gets scanned.

- **Version-specific manifests.** SwiftPM honours `Package@swift-6.4.swift` in preference to
  `Package.swift`. Verified: a dependency declared there is resolved and built while `Package.swift`
  declares none, and a scanner reading only `Package.swift` sees nothing. **Every** `Package*.swift`
  in the package root must be scanned.
- The dependency array assembled under any name and passed in by identifier, or mutated after
  construction — both defeated an earlier syntactic scan, and are why the rule is `.package(`
  rather than a `dependencies:` shape match.
- `.package(` inside a comment or string literal must **not** fire.

### What this plugin is for

**It catches the ordinary mistake.** A stray `import AppKit`, a `CGRect` that drifted into the
package — written by someone who knows the rule and slipped. It is **not an adversarial boundary,
and there is no attacker.** Anyone able to edit `Sources/` can also edit the checker.

That distinction is load-bearing, because it decides what counts as a defect and what counts as
work worth doing:

- A **false positive on idiomatic Swift** is the serious failure. It blocks real work and teaches
  people to route around the rule. Round 3 existed because `` @Test func `rejects import AppKit`() ``
  — an ordinary Swift Testing name, in a suite that is literally about imports — was being rejected.
- A **theoretical evasion** is not. Nobody types a form feed by accident.

**If a future round is proposed on the grounds of closing an evasion, that ground is false and the
round does not happen.** Rule 1 is capped. It reopens on exactly two triggers: a second contributor
joining the project, or a rule-2 false positive that blocks work. Nothing else.

### Known gaps, with reachability

The reachability column is the point. It separates *we chose not to close this* from *we did not
know*. Every row was measured — `swiftc -typecheck` exit 0 means the construction really compiles
and really imports the module.

| # | Construction | Direction | Reachable how |
| --- | --- | --- | --- |
| 1 | `import<FF>AppKit`, `import<VT>AppKit`, leading `<FF>` | miss | Deliberate authorship only. Invisible in every diff viewer, which is exactly why nobody produces one by accident |
| 2 | `@_spi(A)@_spi(B)import AppKit` — punctuation glued to the keyword | miss | Deliberate only. The spaced form is caught |
| 3 | `// note<CR>import AppKit` | miss | Deliberate only. Closed in round 2 by promoting lone CR to a line terminator; listed because the class persists for any terminator Swift adds |
| 4 | `import<NBSP>AppKit` | miss | ⌥-space is one keystroke, so marginally more reachable than 1–3, but still requires the module name to follow it on the same line |
| 5 | Unterminated `#/…` or `"""…` blanks the rest of the file | miss | **Unreachable in a passing build** — requires source that does not compile, so it cannot hide anything from a build that would otherwise succeed |
| 6 | Bare `/…/` regex literals are not modelled | neither | No opener can occur inside one: Swift rejects a quote or backtick there, verified |
| 7 | `.product` dependencies resolve to nothing | false positive | Loud. The package has no products; the first one added produces a visible rejection, not silence |
| 8 | Astral-plane identifier characters (U+10000–1FFFD) | false positive | Loud. Swift accepts them as identifier heads, `Character.isLetter` does not |

**Rows 1–4 were closed anyway**, because closing them cost less than arguing about them. They are
listed so that the next person can see they were considered rather than missed.

**Row 5 is the honest residual.** It is the only miss that survives, and it survives on source that
does not build.

### The standing structural gap

`codeViewLines` is a hand-rolled lexer, which makes it **a list of Swift's literal forms** — and a
list lags by however long it takes someone to write the probe. Two forms were absent for exactly
that reason:

- **Raw identifiers** (SE-0451, Swift 6.2). A `"` inside `` `…` `` opened a string frame, blanking
  the rest of the file on code that compiles. Found in round 3.
- **Extended regex literals** (`#/…/#`, Swift **5.7**). Live in both directions. Absent for several
  releases, and found by an audit rather than by the language moving.

The lag is unbounded and silent in both directions. **SwiftSyntax is the durable fix** — it makes
the checker share the compiler's notion of what a literal is, rather than maintaining a parallel
list that is correct until it quietly is not. Deferred: at one contributor the failure mode is a
loud false positive, which is survivable. It becomes urgent when a second contributor arrives, which
is one of the two triggers that reopen this rule.

### The evasion set the rule is tested against

61 rejection forms and 41 acceptance forms, all executing the real built binary against fixtures.
The acceptance forms matter as much as the rejections — they are what keeps the rule from being
routed around. Notable members:

- `import` and the module name separated by a **newline**: valid Swift, defeats any scanner that
  extracts one statement per line
- SE-0409 access levels: `public`/`package`/`internal`/`fileprivate`/`private import`
- attributes, stacked attributes, semicolon-joined imports in either order, `import class AppKit.NSColor`
- string and raw-string interpolation hiding real code
- must PASS: `` import `Foundation` ``, `` public let `import` = 1 ``, `` @Test func `rejects import AppKit`() ``,
  `#/import AppKit/#`, `// import AppKit`, `#if canImport(AppKit)`, `func doImport() {}`

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
| `architecture-plugin` | **all five active rules observed red**, individually — see below |
| `geometry` | cross-revision comparison traps, observed out-of-process |
| `project-format` | a v1 document round-trips and a synthetic v0 upgrades |
| `derivation-graph` | the producer-value rule holds under test |

**`architecture-plugin` needs five negative cases, not one.** Stating the criterion as "`import
AppKit` fails the build" proves rule 1 and silently assumes the other four — the same shape of
ambiguity as "which build", in the same document that just adopted the observed-red rule. Each rule
is done when its own violation has been seen to fail:

| Rule | Negative case that must be observed failing |
| --- | --- |
| 1 · imports | `import AppKit` in a package source — under **both** `swift build` and `xcodebuild` |
| 2 · CG types | `let r: CGRect` in a package source |
| 3 · determinism | `Date()` in a package source — **and** `"\(Date())"`, since the text-scan predecessor passed exactly this |
| 4 · manifest | `.package(path:)` in `Package.swift` — **and** in `Package@swift-6.4.swift` |
| 5 · CG bridge | `CGRect` in an app source outside `Capture/CGGeometryBridge.swift` |

Each pairs with its positive case: the legitimate form still builds. A rule seen only green is not
a known rule.

---

## Document corrections

**This table was itself wrong.** Its first version listed only `ARCHITECTURE.md`, `ROADMAP.md` and
`TOOLCHAIN.md` — and omitted `README.md`, `AGENTS.md` and `KICKOFF.md`, which are the three documents
a person or an agent reads *first*. A corrections list that was never checked against the repository
is the same failure this document keeps recording: a claim about state, never compared to the state.

`KICKOFF.md` was the dangerous omission. It is a **copy-pasteable prompt** whose Phase 1 block says
*"Constraints already decided … Treat these as given. Push back only if you find a genuine
contradiction."* Handed to an agent unchanged, it faithfully reinstates `.macOS(.v27)` as a settled
constraint. A stale instruction with authority framing does not sit there inertly; it actively
undoes the decision.

| Document | Claim | Correction |
| --- | --- | --- |
| `README.md` | `macOS 27 · Swift 6.4`; TOOLCHAIN described as "macOS 27 setup" | macOS 26; a macOS 27 volume is not required at this floor |
| `AGENTS.md` header | `macOS 27 · … Swift 6.4` | macOS 26, SDK 27 |
| `AGENTS.md` rule 1 | the compiler enforces Foundation-only; package at `Packages/SoredemoCore` | the compiler does not (F1); package is at the repository root (D-P0) |
| `KICKOFF.md` Phase 1 | `.macOS(.v27)` under "Treat these as given" | macOS 26, plus a header marking the block superseded by the design and plan |
| `ARCHITECTURE.md` D2 | macOS 27, "ships when 27 is a year old" | macOS 26. The no-availability-branches rule survives; the ship-date argument does not |
| `ARCHITECTURE.md` D1 | `Packages/SoredemoCore/` | package at the repository root (D-P0) |
| `ARCHITECTURE.md` D5 | `WritableDocument`/`ReadableDocument`/`DocumentCreationSource` | hand-written `NSDocument` coordinator (F3, F4) |
| `ARCHITECTURE.md` D3 | bottom-left "so the render path never flips" | true for render; CG, event and AX inputs are top-left. One flip, at capture entry |
| `ARCHITECTURE.md` D6 | the compiler blocks `import AppKit` | false (F1); the plugin enforces it |
| `FEATURES.md` header | `Target: macOS 27` | macOS 26, built against the 27 SDK |
| `ROADMAP.md` `project-format` | lists `ReadableDocument`/`WritableDocument` | `NSDocument` coordinator; the row spans the package/app boundary |
| `TOOLCHAIN.md` § 2 | macOS 27 beta volume required | not required at a 26 floor. Xcode 27 beta stays — it is the SDK |

### What must NOT be changed

Three categories of `macOS 27` are correct and deleting them would destroy information:

1. **The SDK.** `otool -l` reporting `minos 26.0 / sdk 27.0` is the normal arrangement — build
   against the newest SDK, deploy to an older system. Likewise the Swift **compiler** is 6.4; only
   the *manifest format* is 6.3. See D2's four-version table.
2. **The reasoning record.** `AGENTS.md` and `PRODUCT.md` cite the `.macOS(.v27)` decision as the
   worked example of a justification that outlived its reason. Deleting it deletes the lesson.
3. **APIs genuinely above the floor.** `FEATURES.md` names Music Understanding, generated subtitles,
   the Evaluations framework and `WritableDocument` as macOS 27. Those rows are **marked**, not
   removed — they describe capability we would want, and Phase 4 and Phase 5 must not be planned on
   them without either raising the floor or finding a macOS 26 equivalent.

---

## Out of scope

Recording, rendering, framing, the timeline, variants, the app's real UI, and the MCP surface.
Phase 1 delivers an app that launches empty, a package that cannot violate its own rules, and the
three data structures every later phase is expressed in.
