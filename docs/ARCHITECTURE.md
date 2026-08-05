# Architecture

*Binding decisions. Changing one is a deliberate act, not a drift.*

---

## D1 — SwiftPM packages, Xcode app target

Pure logic lives in a SwiftPM package. The app is an Xcode target that consumes it.

```
Package.swift + Sources/   Foundation only — derivation graph, framing, timeline, variants, project
Soredemo.xcodeproj         App bundle, entitlements, Info.plist, assets, Sparkle, signing
```

**The package sits at the repository root, not under `Packages/SoredemoCore/`** (design doc D-P0).
One manifest, one `Sources/`, one `Tests/`; the Xcode project references the package by relative
path from the same directory.

The boundary is load-bearing, not cosmetic: a package that *cannot* import AppKit or ScreenCaptureKit
is a build-enforced version of the pure-domain rule. The enforcement is a build-tool plugin, not the
compiler — the compiler permits any system framework in any target. See D6.

*Rejected:* pure SwiftPM — Info.plist, icons, and asset catalogues all need excluding and stitching by
script. *Rejected:* pure Xcode project — the package manifest is what carries the target graph the plugin
enforces, so without it the pure/impure boundary is a convention rather than a build failure.

---

## D1a — Three tiers, and which one a new file belongs in

D1's two-way split (package / app) is now a three-way one. The third tier exists because
`swift test` **cannot link an `executableTarget` or an Xcode app target**: code in `Soredemo/` is
only ever read as text or run by a person, and defect `1a98402` lived in
`Soredemo/Render/StageCompositor.swift` for a whole phase because of it.

**The tiers are defined by what can exercise them, not by a framework list.** An allow-list of
frameworks is a mechanism with no principle behind it — a table that grows one row at a time.

| Tier | Invariant | Guard |
| --- | --- | --- |
| `Sources/Geometry…Render` | **Deterministic**: same input, same output. No GPU, no clock, no window | `ArchitectureCheck` — Foundation plus declared siblings; no CG geometry |
| `Sources/Headless` | **Runnable under `swift test` on a developer machine**, even where not bit-deterministic — real pixel buffers, GPU and wall time are all allowed | `HeadlessCheck` — no AppKit, no SwiftUI |
| `Soredemo/` | **Only a running app can reach it** | the app-side scans in `Tests/AppSourceTests` |

**Deciding where a new file goes: does it need a window or an app lifecycle?** If yes, it is
`Soredemo/`. If no, and it needs the GPU, a real pixel buffer, a real file or the wall clock, it is
`Sources/Headless`. If no to both, it is a deterministic target and the pure guard applies. The name
states the exclusion, which is why the invariant survives Phase 3A-2: `Render` as a tier name would
expire when `Capture` moves in; `Headless` does not.

**`Sources/Headless` carries `HeadlessCheck`, never `ArchitectureCheck`, and that is not a hole in
the pure guard.** Attaching the pure guard there is impossible rather than merely inconvenient: rule
1's allow-list would ban AVFoundation, CoreImage, CoreVideo, Metal and CoreGraphics, and rule 2
would ban the `CGRect` this tier exists to convert. Loosening the pure guard to fit is forbidden —
two guards with two rules, not one guard with an exception.
`everyLibraryTargetUsesTheCheckerPluginInTheResolvedManifest` asserts both directions against the
resolved manifest: every regular target carries the guard its tier requires, and no target carries
the other tier's. Attaching `HeadlessCheck` to a pure target is the dangerous direction because it
is **silent** — rules 1 and 2 would simply be off, and the build would stay green.

**Rule 5 has one bridge per tier, and neither test has an exception.** The app tier confines
`CGRect`/`CGPoint`/`CGSize`/`CGFloat` to `Soredemo/Capture/CGGeometryBridge.swift`
(`coreGraphicsGeometryTypesAppearOnlyInTheBridge`); `Sources/Headless` confines them to
`Sources/Headless/HeadlessGeometryBridge.swift`
(`coreGraphicsGeometryTypesAppearOnlyInTheHeadlessBridge`). The split is by tier — the AX and
ScreenCaptureKit *entrances* need `ApplicationServices`, the render *exits* need nothing — and it is
temporary: when `Capture` moves in 3A-2 the two bridges are reconsidered together.
`theTwoGeometryBridgesShareNoFunctionSignature` is what stops a conversion being defined on both sides
while both exist.

### The entry rule, and the two levels it is enforced at

**Every `public` type in `Headless` must have a test in `swift test` that CONSTRUCTS AND EXERCISES
it.** A target that can be linked is a target things get dumped into; the entry rule is the price of
entry.

The two levels are not the same thing, and conflating them would plant this project's own recurring
defect inside the gate built to prevent it:

* **the scanner** (`everyPublicTypeInHeadlessIsNamedByATestThatLinksTheProduct`) enforces a
  **necessary condition only** — the type's identifier appears at a word boundary in the code view
  of a file under `Tests/HeadlessTests`. A type annotation or an unused `import` satisfies it while
  the type is never built and never run, and for a generic name (`Frame`, `Track`, `Renderer`) it is
  close to vacuous. Its own failure message says so.
* **review** enforces the rule. There is no mechanical substitute, and claiming one is the failure
  mode D6a records over and over.

`public` on a member of an already-admitted type is a known free-entry gap: it needs no separate
scanner entry, so the surface can grow without the scanner noticing. Add `public` to a member only
when a caller outside the module already exists.

**The two test populations are kept apart by the build graph, not by a rule.** `HeadlessTests` is
the only test target that may depend on `Headless`; a deterministic target that cannot link it
cannot have a GPU-dependent or time-sensitive test written against it.
`noDeterministicTestTargetDependsOnHeadless` keeps the manifest honest, and
`scripts/count-tests.sh --split` reports the two counts with the partition verified rather than
printing one number that means two different things.

*Full reasoning: `docs/design/2026-08-04-phase-3a-foundation-design.md` §§ 2-4. This section is what
a reader of this file needs in order to place a new file; it is not a restatement of that document.*

---

## D2 — macOS 26, Apple Silicon, Swift 6.4, no fallbacks

`platforms: [.macOS(.v26)]`. Strict concurrency. No availability branches.

**Four version numbers, deliberately not the same.** They get conflated, and conflating them makes
correct settings look stale:

| | Value | Means |
| --- | --- | --- |
| Deployment target | **26.0** | the oldest macOS that runs the app |
| SDK | **27.0** | the API ceiling available at compile time |
| `swift-tools-version` | **6.3** | manifest format version |
| Swift compiler | **6.4** | language version |

Building against the newest SDK and deploying to an older system is the normal arrangement, so
`otool -l` reporting `minos 26.0 / sdk 27.0` is correct, not a leftover — measured on
`Soredemo.app/Contents/MacOS/Soredemo`. Likewise "Swift 6.4 strict concurrency" is current; only the
*manifest format* is 6.3.

**Why 6.3 and not 6.4, restated — the old reason had gone stale.** It used to read "because Xcode
26.6 ships SwiftPM 6.3.3 and refuses a 6.4 manifest", which describes a toolchain that is no longer
the selected one: `xcode-select -p` points at `Xcode-beta.app` (Xcode 27 beta 4, Swift 6.4), and
that toolchain **accepts** a 6.4 manifest — `swift package dump-package` exits 0 with
`// swift-tools-version: 6.4`, measured. The reason to stay at 6.3 is the *other* toolchain:
`TOOLCHAIN.md` § 1 keeps Xcode 26 installed on purpose, and its SwiftPM refuses the same manifest —
`error: package 'soredemo-main' is using Swift tools version 6.4.0 but the installed version is
6.3.3`, also measured. A tools version is a floor on the reader, so 6.3 is what keeps both
toolchains able to open the package. Raise it only when Xcode 26 is deliberately dropped.

macOS 26 is Apple Silicon only — Intel and Rosetta 2 are ended, so that part is Apple's position
rather than just ours.

**The ship-date argument that used to sit here is gone, and its removal is the point.** The floor
was `.macOS(.v27)` and the justification was "27 is a stability release, and this project ships when
it is roughly a year old". The floor came down to 26; the argument stayed, and for a while it read
as a live reason for a decision that had already been reversed. `AGENTS.md` cites exactly this as
the worked example of a justification outliving its reason. The real reason for 26 is smaller and
duller: a macOS 27 binary cannot be launched on this machine, so every "it builds" would have gone
unpaired with an "it runs".

What the floor buys: no two-tier material code and no `if #available` on ScreenCaptureKit, Speech,
or Accessibility. `SCContentSharingPicker`, `SCRecordingOutput`, `SpeechAnalyzer`,
`SpeechTranscriber` and `AssetInventory` are all available at 26 (design doc F5), as is native
Liquid Glass.

**What it costs, measured rather than assumed.** The SwiftUI `Document` API is **not** available at
this floor: `ReadableDocument` and `WritableDocument` are `@available(macOS 27, *)`, which is why D5
is a hand-written `NSDocument` coordinator (design doc F3, F4). `FEATURES.md` names Music
Understanding, generated subtitles and the Evaluations framework in the same position. Phase 4 and
Phase 5 must not be planned on any of them without either raising the floor or finding a macOS 26
equivalent.

### The cost of this floor, re-measured before Phase 2B — and it is smaller than it looked

**This is not a reversal. The reasoning above is intact; the world it refers to moved.** When 26 was
chosen, `scripts/scan-sdk-deprecations.py` did not exist and nobody had measured what the floor
excludes. It has now been measured, and the number belongs beside the decision rather than in a
scan's output — the same failure D2-17 records, where a correct argument outlived the state of the
world it cited.

**The media stack this project is about to be written against was condemned one version above this
floor** — 78 declarations at exactly 27.0, including `AVAssetWriter`, `AVAssetWriterInput` and its
four adaptors, `AVAssetReader` and its outputs, `AVAssetExportSession`, and three `AVVideoCompositing`
methods. See D6b-27.

So the question "what does staying at 26 cost" now has an answer instead of a shrug, and it is
**one path, not the stack**:

| | Reachable at 26.0? | Cost of the floor |
| --- | --- | --- |
| The successor write/read/compose/export stack — `Receiver`, `Provider`, `CVReadOnlyPixelBuffer`, `.init(configuration:)`, `export(to:as:)` | **yes**, typechecked | none. Write against the successors from the first line; the floor never enters it |
| `AVSampleBufferVideoRenderer.Receiver` / `AVSampleBufferAudioRenderer.Receiver` — the render-synchronizer preview path | **no**, `@available(macOS 27)` | its predecessor is condemned at 27.0 and its successor is unreachable at 26.0. Choosing that path means **two implementations, or moving the floor** |

**That is the whole measured cost, and it lands on exactly one decision**: whether preview is driven
through the sample-buffer renderers or through `AVVideoComposition`, which D8 leaves open. Taking
the composition path costs the floor nothing. Taking the renderer path is the only thing here that
would make "macOS 26" mean *write it twice, or drop every 26 user*.

Two things this does **not** say. It does not say the successors work — the field's only report on
`PixelBufferReceiver.append` is an unresolved hang, recorded in D6b-27. And it does not say raise
the floor: a macOS 27 binary still cannot be launched on this machine, which is the actual reason
for 26 and is unaffected by any of this.

---

## D3 — Coordinates: normalised, one conversion point

`NormalizedPoint` is 0–1 with a **bottom-left origin**, matching Core Image and `NSScreen.frame` so
the render path never flips. `NormalizedFrame` additionally carries a `geometryRevision`.

That origin claim is right about rendering and misleading about everything else: `CGDisplayBounds`,
`CGEventGetLocation`, and AX `kAXPositionAttribute` are all **top-left**. There *is* a flip — the
obligation is not that it never happens, but that it happens in exactly **one** place, on entry, and
never again. `NormalizationContext` is that one place, converting display-local top-left pixels (never
global ones, which would silently compute a plausible wrong answer) to normalised bottom-left. Routing
a global point to its display happens first, via `DisplayArrangement.route`.

This is the decision most likely to fail silently. Two rules make it loud:

1. **No raw `CGPoint` or `CGRect` crosses a module boundary.** Capture converts on entry, through
   `NormalizationContext`; render converts on exit. Nothing in between speaks in pixels.
2. **Comparing frames across `geometryRevision` is a precondition failure**, never a silent coercion.
   Displays get reconfigured mid-recording; a comparison that quietly succeeds against a stale
   revision lands a zoom on the wrong control with no error anywhere.

---

## D4 — Automatic framing: targets from evidence, motion from springs

Two stages that answer different questions, and they must not be collapsed.

```
observations (clicks + the AX control under each)
   ↓  framing            where to look, how deep, and why
zoom blocks               target, depth, pre-roll, hold, merge
   ↓  camera
spring simulation         how the camera actually gets there
```

**Framing decides *where*.** The AX control under a click, when it passes the gates. Otherwise the
pointer — and it records which gate rejected the control. Named rejections: confidence absent,
confidence low, observation stale, does not contain the click, degenerate rectangle, partly offscreen,
too large.

**Springs decide *how*.** Settle without overshoot, carry velocity across a re-aim, and use a safe zone
so small cursor movement does not move the camera.

### Three calibration risks, named up front

**The size gate decides whether this works at all.** A threshold that is too loose accepts a 20–28%
editor pane or terminal as a "control" and zooms confidently at the wrong thing with no diagnostic —
which is worse than a rejection, because named rejection reasons do not help when the failure is a
false accept. Measure real control sizes before choosing the threshold. The honest number is closer to
**5% of screen area than 60%**.

**Merge can swallow the whole feature.** With a 2.5 s hold and a 2.5 s merge gap, any two clicks under
~5.3 s apart land in one zoom block. Demo clicks are typically 1–3 s apart, so a naive merge turns an
entire demo into a single zoom and every framing decision after the first is computed and discarded.
Tune against real click cadence, and **make it an error when the storyboard reports six beats and the
camera reports one block.** Two derivations that disagree must say so.

**Depth must actually vary.** If depth only changes across a narrow band of control sizes, and real
controls cluster outside that band, "adaptive depth" collapses into two constants. Fit the curve to
measured sizes, or drop the claim.

### The hand-off must have exactly one consumer

The framing decision is produced in one place and read in one place, and there is a test that fails if
nothing reads it. A framing origin that nothing consumes is a pure function with no caller — see the
completion rule. This is also what `explain_framing` and the review UI read, so it has to be durable,
not recomputed.

### Rule 7's target is `Derived.init`, and the first row that has to close it is `framing-targets`

Rule 7 — `applyingProduced` is the sole writer of a `Derived` — is inert in D6 because no producer
exists. When one does, **the gap will not be the missing producer; it will be `Derived`'s public
initialiser.** `Sources/Graph/Derived.swift` declares
`public init(value:origin:review: = .pending)`, so a producer can write
`Derived(value: v, origin: .generated(d), review: .approved)` and never touch the guarded path. The
default makes the honest call short and the dishonest one one argument longer. Held today by two doc
comments and nothing else, and the comment on `applyingProduced` claimed to be "the enforced write
path" until Task 19, when it was not.

The initialiser cannot simply be closed: the app mints authored values through it and the decoder
needs it. So rule 7 has to be a check that a *producer* does not name it — the same shape as rule 5,
over `Sources/` instead of `Soredemo/`. **Phase 3's `framing-targets` is the first row that writes a
producer, and therefore the row that must bring the mechanism with it.** A producer landing before
the check would make the producer-value rule a convention on the exact code it exists to constrain.

---

## D5 — Project format: a document, not a database

A versioned `Codable` document with a schema number and an explicit upgrade path. Atomic writes.
Relative paths only, so a project folder can move. Media lives beside the project file as sidecars.

**I/O:** a hand-written `NSDocument` coordinator — `Soredemo/UI/ProjectDocument.swift`.
`read(from:ofType:)` receives the package **directory** and decodes `project.json` alone, so opening
a document is independent of how much footage it holds; `writeSafely(to:ofType:for:)` is overridden
to bypass `NSDocument`'s whole-package copy and let `ProjectPackageIO` make the manifest alone
atomic.

**Corrected from `WritableDocument`/`ReadableDocument`/`DocumentCreationSource`** (design doc F3,
F4). Those protocols *do* handle a package — their `Source`/`Destination` associated types merely
default to `URL` — so the original verification question was answered *yes*. They are unusable
anyway for a different reason: they live in **SwiftUI**, not Foundation, and are
`@available(macOS 27, *)`, above this project's macOS 26 floor (D2). `DocumentCreationSource.init(id:)`
is separately `@available(macOS, unavailable)`, as is its only consumer `NewDocumentButton`, so the
claim that it maps onto the entry points was never true on macOS.

**The cost of the substitute, recorded rather than discovered later.** `NSDocument`'s `read` and
`writeSafely` are `nonisolated`; marking an override `@MainActor` is a hard compile error. Document
state therefore lives in a `Mutex` instead of behind the class's own main-actor isolation, and every
piece of state this coordinator grows pays that tax. The newer protocol avoided it by making
`snapshot(contentType:)` `@MainActor` and handing a `sending` value to a `@concurrent` writer.

**File coordination is unresolved, not decided — the one open item in this decision.**
`super.writeSafely` does two things: it copies the whole package, and it performs the write inside an
`NSFileCoordinator` coordinated write, which tells other coordinated readers — Finder previews, a
sync daemon, a second instance of this app — to stand off while the document changes. The override
drops both. Dropping the copy is the point, and atomicity was *relocated* to
`ProjectPackageIO`'s `replaceItemAt` rather than lost. Durability was *declined* on a stated
argument (D-P3: one save's edit state is an acceptable loss, the media it references is already
durable). Coordination was neither relocated nor argued — it was simply dropped, and nothing
replaces it. Phase 1 gets away with it because `save` is single-writer by construction and
`autosavesInPlace` is `false`. It bites first when a project package sits in a synced folder, which
is a normal place to keep one. **Revisit before Phase 2 ships a recording path that writes while the
user has the document open.**

*Rejected:* SwiftData. The project is a document users open, move, and version — not a store.

---

## D6 — Architecture rules, enforced by the build

Rules that are not executable stop being true. Four mechanisms, in descending order of strength.

### The numbering, stated once

**This table is the one numbering.** Other documents point at it; they do not restate it. There were
two schemes in circulation until Task 19 — this one, and a different `1…6` in `AGENTS.md` where 3 was
`geometryRevision` and 5 was strict concurrency — and both were cited from source, twice in the same
file two lines apart, with `CGGeometryBridge.swift` carrying a parenthetical to say which 5 it meant.
A rule you have to disambiguate by document name is a rule nobody can cite.

"Enforces these" was also broader than the truth: of the rules below, the plugin enforces **four**.

| # | Rule | Enforced by | Fails |
| --- | --- | --- | --- |
| 1 | The package imports Foundation only, plus each target's declared siblings | `Plugins/ArchitectureCheck`, source text | `swift build` **and** `xcodebuild` |
| 2 | No `CGRect`/`CGPoint`/`CGSize`/`CGFloat` **anywhere in the package** — not merely in its public API | `Plugins/ArchitectureCheck`, source text | `swift build` **and** `xcodebuild` |
| 3 | No ambient time or randomness | `Tests/DeterminismTests`, link-time symbols (package) · `Tests/AppSourceTests`, source text (app) | `swift test` only |
| 4 | No manifest declares a package dependency — this is what keeps rule 1's allow-list complete | `Plugins/ArchitectureCheck`, scans every `Package*.swift` | `swift build` **and** `xcodebuild` |
| 5 | CG types in the app appear only in `Soredemo/Capture/CGGeometryBridge.swift` | `Tests/AppSourceTests`, source text — the plugin cannot see the Xcode target | `swift test` only |
| 6 | One owner for the observation-log → graph join | **inert** — the code does not exist yet | nothing |
| 7 | `applyingProduced` is the sole writer of a `Derived` | **inert** — see the note in D4 below | nothing |
| 8 | A type with a validating initialiser (`throws` or a `precondition`) and a `Codable`/`Decodable` conformance must have an explicit `init(from decoder:)` | `Plugins/ArchitectureCheck`, source text | `swift build` **and** `xcodebuild` |
| 9 | The package builds under `.strictMemorySafety()` (`Package.swift`) with zero `StrictMemorySafety` warnings | `scripts/check-strict-memory-safety.sh`, greps an incremental `swift build`'s output for the diagnostic's own tag, with a positive-evidence guard against an unobserved (empty or success-marker-less) log | its own script only — see below |

Rules 3 and 5 do not fail an `xcodebuild` of the app, because `Soredemo.xcodeproj` has no test
target. Rules 6 and 7 fail nothing at all; they are commitments about code Phase 2 and Phase 3 will
write. Rule 9 fails neither `swift build` nor `xcodebuild` automatically — both exit 0 on a warning —
so it fails only its own script; see mechanism 4 below.

The project's other binding rules are **not** in this numbering and never were: comparing
`NormalizedFrame` across `geometryRevision` is a precondition failure (D3), Swift 6 strict
concurrency (D2), and native-only Liquid Glass (D7). They are decisions with their own letters, and
giving them numbers in a second list is what produced the collision.

**1. A build-tool plugin — not the compiler.** `SoredemoCore` imports Foundation only. `import AppKit`
in the package is a build failure, not a review comment — but the *compiler does not produce that
failure*. The compiler constrains edges **between package targets** (F2), and even there SwiftPM
degrades an undeclared-target import to a warning on a warm `.build`; it places no restriction
whatever on system frameworks (F1). A target with zero declared dependencies can `import AppKit` and
`import ScreenCaptureKit` and compile cleanly, and `.treatAllWarnings(as: .error)` does not close the
gap, because the diagnostic comes from the dependency scanner rather than the compiler frontend.

What actually enforces the rule is `Plugins/ArchitectureCheck`, a SwiftPM build-tool plugin attached
to all six library targets. It runs `architecture-checker` over each target's sources on every build —
clean or incremental — and exits non-zero with `file:line: error:` on any import outside the target's
allowed set. Its allow-list is not a copy of the dependency edges — the plugin reads each target's
**declared** dependencies out of `PluginContext` and passes them on the command line, so the
allow-list *is* the manifest, and it enforces F2 as an error on warm builds too. Direct edges only:
the transitive closure would silently permit `Framing → Timeline` and `Variants → Geometry`, which
are precisely the undeclared edges SwiftPM downgrades to a warning.

The checker reads source text through a file-scoped lexical scan, so comments, string literals of
every flavour, and string-interpolation bodies are classified correctly; `public import AppKit` and
the other SE-0409 access-level spellings are caught, as is `#if canImport(AppKit)`. It tokenises by
maximal *identifier* run rather than by a list of separators, because Swift accepts space, tab,
newline, CR, form feed, vertical tab, NUL and U+00A0 between `import` and the module name, and ends a
token at any punctuation besides — a form feed is invisible in every diff viewer, so an enumerated
separator list is a standing invitation. A backtick both closes and opens a run, because Swift
terminates the keyword there: `` import`AppKit` `` needs no space and typechecks. Every one of the
128 ASCII code points and 22 Unicode oddities has been swept as a separator against `swiftc` and the
checker together; Swift accepts exactly eight, and all eight are caught. SE-0451 raw identifiers and
extended regex literals `#/…/#` are modelled as their own lexical spans, because a `"` inside either
is ordinary content — without that, `` @Test func `rejects import AppKit`() `` is reported as a
violation, which is the failure that actually occurs, sentence-shaped test names being the reason raw
identifiers exist.

`codeViewLines` is a hand-rolled lexer, and therefore a list of Swift's literal forms — one that will
be a version behind each time the language gains another. Deriving it from SwiftSyntax is the durable
fix if this area is ever revisited. Every I/O failure is a hard error: a missing sources
directory, a directory with no `.swift` files, and an unreadable or undecodable file all fail the
build. Unreadable must never mean compliant. Verified to fail the build under **both** `swift build`
and `xcodebuild`.

**Determinism is checked over link-time symbols, not source text, and it is a test rather than a
plugin rule.** Ambient time and randomness break derivation identically to a framework call and are
far easier to introduce by accident, but `Date()`, `UUID()`, `.random(in:)` and `ContinuousClock`
are all Foundation or standard library, so no import allow-list can see them. A text scan is a proxy
for a semantic question and leaks — a prior implementation caught plain `Date()` while `"\(Date())"`
and `#"\#(Date())"#` both passed. Mangled symbols have no such gaps: every syntactic evasion
collapses into `_$s10Foundation4DateVACycfC`, measured. The check cannot live in the plugin, because
a build-tool plugin's command runs *before* its own target compiles and `PluginContext` exposes no
accessor for any target's build products. It lives in `Tests/DeterminismTests`, whose declared
dependency on all six library modules is what orders their compilation ahead of it; it only *reads*
already-built object files with `nm -u`, so there is no nested build and no `.build` lock. The
banned list is derived from this toolchain rather than guessed, and a fixture in the suite recompiles
every banned construct and fails if a mangling has changed. Two guards make a vacuous pass
impossible: no object files found, and no undefined symbols read, are each a hard failure — an empty
search finds no violations and would otherwise read as a clean bill of health. The **types** `Date`
and `UUID` stay legal; `Geometry.o` references `Foundation.UUID` and never `UUID.init()`, because
identifiers and timestamps are minted in the app and passed in as plain values.

**This constrains the package, not the app.** The app target uses ScreenCaptureKit, AVFoundation,
AppKit, and Metal freely — that is where recording, rendering, and UI live.

```
Soredemo.xcodeproj   Capture/ Render/ Editor/ Agent/ UI/   ← ScreenCaptureKit, AVFoundation, Metal
     │  captures, writes an observation log
     ▼
observation log → evidence (plain data)
     │
     ▼
Sources/                Graph/ Framing/ Timeline/ Variants/ Project/   ← Foundation only
```

**The core does not record; it reasons about a recording.** Three reasons this line matters:

- Pure logic tests with no screen, no permissions, and no display — so the derivation suite runs in CI
  in milliseconds.
- Derivation must be a deterministic function of its input. A framing stage that could call
  ScreenCaptureKit could observe the world mid-derivation, and then staleness, `isCurrent`, and
  content-hash approval all stop meaning anything.
- The boundary cannot be violated by accident, only by deleting the rule.

**2. `Plugins/ArchitectureCheck`** for what the compiler cannot see. As of Phase 1 that is rule 2 —
no `CGRect`/`CGPoint`/`CGSize`/`CGFloat` **anywhere in the package**, not merely in its public API,
because the conversion belongs at the app boundary — and rule 4, no package dependency in any
`Package*.swift`, which is what keeps rule 1's allow-list complete. Rule 6 (one owner for the
log→graph join) and rule 7 (`applyingProduced` is the sole writer of a `Derived`) are **inert**: the
code they constrain does not exist yet, and an unwritten rule is not an enforced one.

`CGRect` in the package is worth a sentence on its own, because the compiler is no help and it looks
like it should be. Foundation on Darwin re-exports the CG geometry **types**, so
`let r: CGRect? = nil` in a Foundation-only target compiles with no diagnostic at all; only the
plugin fails that build. This is F1's shape a second time — measured, not assumed.

**Rule 8 — a validating initialiser under a synthesised `Decodable`** — is the fourth plugin rule and
the one aimed at code not yet written. Swift's synthesised `init(from:)` assigns stored properties
directly and never calls yours, so every `precondition` and every `throw` that defines a type's
invariant is skipped *exactly* on the path carrying untrusted input: a `.soredemo` package is a
shareable document. The scan is per **type**, over the whole file, because the conformance may be
declared on an extension and so may `init(from:)` — a scan keyed on the declaration line misses
`GeometryRegistry`, `ContentDigest` and `Evidence`, which is the mistake the first hand-written
version made and survived only because all three were closed (Phase 2 design doc, D2-14).

It answers per **target**, not per file. Per-file was the obvious shape and it is wrong in the
silent direction: `Sources/Graph/Derivation.swift` already carries eight extensions of types
declared elsewhere, so a validating type in one file with `extension Foo: Codable {}` in another is
the house style — and per-file that is a pass, while the mirror case (the decoder init in the other
file) would have been a loud false positive. The asymmetry ran the wrong way. Conformance is also
resolved **through protocols**: `ObservationRecord: Codable, Sendable` makes every observation record
`Decodable` without any of them naming `Codable`, and Tasks 9-11 write exactly those types.

**An `init?` counts as validating**, and the tree contains both shapes of the argument.
`Evidence.init?(_ refs:)` returns nil on the empty array and its own comment calls that half of a
guarantee whose other half is `init(from:)` — delete that decoder init and a rule that knew only
`throws` and `precondition` stays green on precisely the defect it exists to catch, verified against
the real file. But `Nanoseconds.init?(rationalSeconds:timescale:)` is a *conversion* on a type whose
`init(_ rawValue: Int64)` accepts every `Int64`: no invariant, nothing for a decode to bypass. No
text scan separates those, so the conversion pays with an exemption line that says it is not a debt.

Its exemption list, `ArchitectureChecker.decodeValidationExemptTypes`, is a **literal list of nine
names** and never a predicate: a predicate widens once per good reason until it matches everything,
and a literal list fails on the tenth type. Eight of the nine are types with no decode path today —
closing them now would be designing error handling with no caller — and the ninth is `Nanoseconds`,
labelled on its line. **Closing one means deleting its line**, and
`theDecodeValidationExemptionListIsExactlyWhatStillViolatesRule8` fails if a name in the list no
longer violates, which is the only failure the build itself cannot see.

`CheckerLexer` sits outside rules 1 and 3. It cannot carry `plugins: archCheck` without closing a
dependency cycle (the plugin's own executable depends on it), and `Tests/DeterminismTests` derives
its module list from plugin-attached targets, so it is outside rule 3 for the same reason. Both
constraints on that one module are **held by hand**. `Package.swift` says so; so does this.

**3. Tests as specification.** Two forms are mandatory and are the ones most likely to be skipped:

> **Producer-value rule.** Supply a value the producer could not have derived; assert the supplied
> value wins. Write it for every producer.
>
> **Cache pairing.** Every cache-hit test is paired with an invalidation test. A cache never proven to
> invalidate is a correctness bug waiting for a demo.

**4. A standalone script, for a diagnostic the compiler itself does not fail on.** Rule 9 —
`.strictMemorySafety()` (`Package.swift`, every regular target) with zero warnings — is the weakest
mechanism here on purpose: `swift build` and `xcodebuild` both exit 0 with `StrictMemorySafety`
warnings present, because the mode reports them as warnings and neither build adds
`-warnings-as-errors`. Turning every warning in the tree into a hard error would be a much larger
change than this rule asks for, so the check lives in `scripts/check-strict-memory-safety.sh`
instead: it runs an **incremental** `swift build` (not `rm -rf .build && swift build` — that is
minutes, and this pays the same incremental cost every other gate here already pays), greps the
output for the diagnostic's own `StrictMemorySafety` tag, and fails loudly — file, line and the
unsafe construct named — on any hit. It also refuses to pass on an unobserved build: an empty log or
one missing `swift build`'s own `Build complete!` marker fails with a distinct exit code and message
rather than reading as clean, closing the hole `Tests/AppSourceTests`'s entry-rule scanner and
`scripts/count-tests.sh --split` were each separately caught with earlier in this same phase — a gate
that passes having measured nothing is worse than one that fails. Not folded into
`scripts/run-cross-boundary-probe.sh`, whose own `swift build` step exists only to produce link
products for the `xcrun swiftc` invocation after it; conflating the two would make a probe failure
ambiguous between an actual cross-boundary defect and an unmarked unsafe construct. Like the probe,
nothing runs this automatically — there is no CI in this repo yet — so it is a gate a person runs,
not one the build enforces for them. First run (Phase 3A-1 Task 3's fix round) found four sites: one
pre-existing (`Sources/Project/ObservationLog.swift`, `String(format:)`'s C varargs initialiser) and
three new (`Sources/Headless/CoreImageFrameRenderer.swift`'s `cursorCanvases` cache and its
`CGContext(data: nil, ...)` construction). All four are marked `unsafe` at the expression with a
comment at the site saying why each is safe despite the diagnostic, not merely silenced.

---

## D5a — Attribution is by time

**A record belongs to a segment if and only if its `instant` falls inside that segment's
`hostRange`. Attribution is decided by time, never by which variable happened to be non-nil when
the record arrived.**

Written down because it was derived three separate times, from three unrelated symptoms, each at
the cost of a review round — and because the third derivation is what showed it was one rule rather
than three fixes:

| Symptom | What the rule says | What was happening |
| --- | --- | --- |
| an AX chain answering after its segment closed | the CLICK's instant decides, not the answer's | already correct — D2-12 — but for a reason nobody had generalised |
| observations arriving while a segment finalises | inside the closing `hostRange` → **members, and lost** | dropped silently; now counted |
| observations arriving before any segment exists | inside no `hostRange`, past or future → **not lost** | counted as "dropped", conflating a classification with a defect |

**Two forbidden routes follow, and they are the same move in opposite directions.** Appending a
late record into the segment that is closing, and buffering an early record to flush into segment
0, both write a record into a segment whose `hostRange` does not contain its `instant`. Buffering
is *not* the thing banned — for a record whose instant is inside, flushing it later is exactly
right. The mismatch is.

**It is enforceable, not merely stated.** `HostRange.contains(_ instant:)` already exists, so
`assert(segment.hostRange.contains(record.instant))` before an append costs one line and turns a
future attribution mistake into a test failure. Where a per-record assert would sit on a callback's
hot path, pin the ordering it depends on with a static test instead and write that test's blind
spot beside it.

The rule's own test is that it works without its author present: given only the sentence, a
different implementer re-derived the fourth case unprompted — no `hostRange` past or future can
contain an instant arriving after the last segment closed on a session that is stopping — and
reached the same verdict.

`MasterSegment` carries this in its own doc comment, because that type owns `hostRange`.

---

## D6a — The gap register: every place this app can fail to observe

**A registry, not a rule.** "Record a gap as an interval, not a count" was written as prose in
`AGENTS.md` and was then missed by the very next task, whose author had the correct implementation
open one file away. A prose rule is checked against memory. A table is checked against itself: the
sixth site missing from it is visible, and a row that says *a count* next to four rows that say
*an interval* is conspicuous.

**Add a row here when you add any new source of unobserved time or lost data.** Not a paragraph in
`AGENTS.md` — a row.

| Site | What is unobserved | How it is recorded | Enough? |
| --- | --- | --- | --- |
| `Sources/Project` JSONL reader | bytes in a truncated or corrupt record | `droppedBytes` — a byte count, and the reader continues — **paired since Task 11 with `bytesScanned`, without which `droppedBytes: 0` reads the same over a clean log and over no file at all**. Reported by `ObservationLogReadReport`, **not** by a producer's trailer: see below | yes: the loss is bounded and quantified in the unit that was lost, and the pair says whether anything was read |
| `AXObserver` ancestor walk | levels beyond the depth cap or the time budget | an explicit truncation reason on the record, plus the `depthCap`/`walkBudgetNanos` in force — the record carries the bounds it was measured against | yes: the record says it stopped and why, so a short chain is not read as a shallow tree; and a run with no chains at all is `GapWatch(site: .axAncestorWalk).looks == 0`, not an empty list |
| `CaptureSession` video | frames the display did not produce | `SCFrameStatusIdle`, counted separately from `.complete`, over `frameStatusCounts` — the count of callbacks that arrived at all is the companion | yes: "nothing changed" is distinguishable from "nothing arrived", and both from "the stream never delivered" |
| `InputObserver` secure input | every event while another app holds a password field | `SecureInputInterval`, with `.secureInputDisabled` vs `.observationStopped` as its two end reasons — **paired since Task 11 with `secureInputChecks` over `secureInputCheckSpanNanos`**, because the predicate is consulted per event and a run that received no events asks zero times and reports zero intervals | yes: a measured span, the end reason says whether its end was observed or merely assumed, and the check pair says whether anything asked |
| `InputObserver` tap disabled, by timeout or by user input | every event between the disable and the re-arm | `TapDisabledInterval`, populated by **polling `CGEvent.tapIsEnabled` from a queue that is not the callback's**, with `detectedBy`, `disabledBy` (nil when polled — the poll cannot know why) and `lowerBoundFrom`; **paired with `tapEnabledPolls` over `tapPollingSpanNanos`, without which an empty list is not a measurement** | yes, with two caveats on the type: it is an enclosing bound rather than the window itself, and the poll interval (100 ms) is the floor on how tight its left edge can be. **Verified against real hardware** (Task 10 human half): a window brackets a known `T_off` with a 4.9 ms lead, 601 of 601 windows under a real OS timeout were found by *polling* and none by notification, and under a persistent cause the record reaches 8 windows/second with 81% of the span marked blind |
| `CursorArt` / `StageCompositor` drawn pointer (Phase 2B Task 8) | the real cursor's own shape (an I-beam over text, a resize handle over a window edge, a hand over a link, a spinner while something loads — `CursorArt` draws one fixed arrow for all of them), and whether the real cursor was hidden at all at the frame's own instant | **not recorded — measured to have no available mechanism, not merely unimplemented.** `CursorArt.swift`'s own header calls the shape loss "a known, recorded limitation", not a placeholder feature. The hidden-state question was put to an actual measurement rather than assumed: `spikes/2026-08-03-cursor-visibility` (Spike E) hid the real cursor with `CGDisplayHideCursor` and read it back two ways — `NSCursor.currentSystem` came back **identical** hidden and visible, and `CGCursorIsVisible`/`CGCursorIsDrawnInFramebuffer` are both **unavailable at this project's 26.0 floor** (a compile error, not a deprecation warning) — so neither candidate exists to build a detector on | **No, and by measurement rather than by omission.** Every other row in this table names a mechanism that records what it misses; this row has none to name — Spike E's two reds are the record. A reviewer must read every drawn pointer as "a generic arrow, at the recorded *position*, of unknown real shape and unknown real hidden-state" — never as a faithful cursor — and that reading has to come from this row, because nothing in a recording itself can carry the correction |
| `StageCompositor.startRequest` preview frame drop (Phase 2B Task 8) | a composition time AVFoundation asked for that the compositor could not turn into a composed frame — `context.newPixelBuffer()` returning `nil` under real memory/pool pressure during live playback, or (structurally, not yet observed) a thrown render | `StageCompositor.Diagnostics.framesDropped` — a count, reset to zero each time a recording is opened (`StageWindow.load()` calls `StageCompositor.resetDiagnostics()`), incremented at exactly the two `finish(with:)`-with-error sites in `startRequest` and no others; that type's own header gives the exhaustive two-cause account, mechanically pinned by `Tests/AppSourceTests/ProductionCallerTests.swift theDroppedFrameCounterHasExactlyTwoCallSitesEachImmediatelyBeforeAnErrorFinish` | **Partial, on four grounds, not three — code review (Task 8, fix round 1) named the fourth.** It is a count, not an interval, unlike every row above it — deliberately: AVFoundation gives no guarantee it will ever re-request the same composition time, so there is no bounded span to measure the way `BlindInterval`/`TapDisabledInterval` measure one, only a discrete "this frame did not arrive". It is also **shared between the preview and the export path** (one `static`, since `StageCompositor` instances belong to AVFoundation and this app never holds one — D8), so a drop counted here does not yet say which consumer produced it; export already throws loudly on its own `framesRead == framesWritten` mismatch (`MP4Exporter.swift`), so the redundant half is harmless, but the preview half — the only place this counter is the *only* signal — is not yet surfaced anywhere a person reads without inspecting the property directly. **Fourth: `startRequest` is the compositor's own boundary, not the preview's** — `AVPlayerItemAccessLogEvent.numberOfDroppedVideoFrames` (real display-time drops `AVPlayer` itself discards) and a scrub that abandons a pending request (`StageCompositor` implements no `cancelAllPendingVideoCompositionRequests()`, grepped absent) both happen on either side of this file and increment nothing here — so a viewer can see the preview visibly stutter or skip on a scrub while `framesDropped == 0`. Real, tested (`scripts/cross-boundary-digest-probe.swift` § 16 drives both causes directly), and complete for what it counts; not yet sufficient for a reviewer to notice a drop without looking, and blind to two drop sources a viewer would actually notice |
| `StageStyle.shadowRadius`/`.shadowOpacity` — modelled, persisted, validated, unread (Phase 2B Task 8) | not an observation gap in this table's usual sense — **what the persisted value fails to reach**: every pixel a shadow would occupy. `RenderPlan.init(from:)`'s hand-written decoder (rule 8) validates and accepts both fields, and any `RenderPlan`/`StageStyle` a project saves carries them, but zero code paths read either to draw anything | **Nothing records this as a gap except this row.** Grepped over `Sources/` and `Soredemo/`: `shadowRadius`/`shadowOpacity` appear only in `RenderPlan.swift`'s own declaration and its Codable `init(from:)`/`encode(to:)` — `CoreImageFrameRenderer.render()` applies no shadow filter. The Codable round-trip test for `StageStyle` is green and proves the VALUE SURVIVES SERIALISATION; it says nothing about whether anything consumes it, and a green test here reads as evidence the feature works | **No.** A user's saved project can carry `shadowOpacity: 0.35` that has never touched a pixel and will not until a shadow filter is added to `CoreImageFrameRenderer.render()`. This is the exact "a passing test proves the value survives serialisation while nothing reads it" shape this phase has spent a week hunting elsewhere (D2-12, the observation counters), found this time sitting in the persisted project format itself. Disposition: modelled and persisted correctly, validated on decode, silently ignored on render — not implemented, and this row is what keeps a reader of the project format from assuming otherwise |

**The magnitudes are a requirement on the log format, not a footnote.** A `.listenOnly` tap that
the OS disables is **invisible**: the cursor does not lag (it is not in the delivery path), no
notification is delivered (measured), and nothing surfaces to the operator. Three of the four
channels a person could notice it through are silent. The only place the hole can ever be found is
this record — so `observation-log` must carry a blind span as a **first-class field**, not a
diagnostic counter, and it must hold the shape and the volume measured above:

    { start, end, causeChannel: poll | notification, reArmed: Bool }

Eight per second under a persistent cause is the load the format has to survive, and 81% blind is
the fraction a reader has to be able to see at a glance. A format that treats these as rare
annotations is designed against a case that has been measured not to hold.

### The same register, for what the build-enforced rules cannot see

**Deliberately a second table under the same heading, and the same rule applies: a row, not a
paragraph.** The table above is about the app failing to observe the world; this one is about the
enforcement failing to observe the source. Both fail the same way — silently, with everything green
— and both were previously recorded in task reports, which nothing reads twice.

| Rule | Blind to | Direction | Reachable how |
| --- | --- | --- | --- |
| 8 | a conformance or `extension` in **another target** | **silent** | The plugin is invoked once per target, so the scan's whole world is one target's sources. A `Project` type conforming to a `Graph` protocol, or extended from another module, is unresolved. Within a target this is closed |
| 8 | a conformance or an `init(from:)` produced by a **macro** | **silent** | No macro is expanded by a text scan. The package uses none today |
| 8 | a validating `init?` that is really a conversion | loud, and paid for | `Nanoseconds` — the rule cannot tell a guarantee from a conversion, so it fires and the conversion carries an exemption line saying so. The alternative (ignore `init?`) is silent on `Evidence` |
| 8 | two types of the same **qualified** name in one target | **silent** | Types are keyed by nesting-qualified name, so `A.Entry` and `B.Entry` are distinct; two `A.Entry` in different files of one target would still merge. Not reachable in Swift within a module |
| 3, app side | a needle that matches nothing, in the CG-bridge, keystroke and user-content lists | **silent** | A ban scan asserts *absence*; a misspelled needle is absent from everything and green forever. Closed for the **ambient** list at Task 11.5 by `everyAmbientNeedleMatchesACallSiteInACompiledFixture`, which compiles one call site per needle and fails if any needle matches none. The other three lists have no such fixture |
| 3, app side | `typealias Moment = Date` then `Moment()`, and two spacing forms | **silent** | The rule-3 reachability table in the Phase 1 design doc, which enumerates and dates them |

**Why "enough?" is a column.** Each row's mechanism was adequate when written and the question is
whether it still is. The last row was the one that was not, and it was visible here in a way it was
not in prose: the four rows above it all record a *span* or a *quantity in the unit that was lost*,
and it recorded neither. It was closed in Task 10 (`ax-observation`), which is also the task that
made it matter — an AX hit-test on the callback thread is a synchronous IPC into an application that
is busy, and F2-2 measured one at 125.47 ms against a tap timeout the header does not quantify.

**The remaining honest gap in this table is the direction of the bound.** `SecureInputInterval` is
*contained within* the true interval; `TapDisabledInterval` *contains* it. Neither is the interval.
Both say so on the type, and a consumer that treats either as exact is wrong in a direction the type
names.

**A row must say what is looking, not only what is recorded.** The tap row was written once as an
interval and was still wrong, because the interval was fed by
`kCGEventTapDisabledByTimeout` — and a `.listenOnly` tap is disabled **without that notification
ever being delivered**. Measured: a deliberate callback stall swept 10/50/100/200/400/800/1600 ms
produced **0 notifications at every rung**, including the rungs where `CGEvent.tapIsEnabled(tap:)`
showed the tap really was disabled, with a `.defaultTap` control receiving the notification in the
same run. So the mechanism in that row could not fire, and its output — an empty list of gaps —
reads as *no gaps*. That is worse than the count it replaced: it looks more thoroughly checked and
the blind spot is the same size.

A later run corrected what that sweep's *thresholds* meant — it stalled every `mouseMoved` at
60–120 Hz, which is sustained overload, and 125 ms of stall on clicks alone leaves the tap enabled
across 18 such stalls in 30 s — but not this row: the notification was absent whether the tap was up or
down, so polling is what this row rests on either way.

The general form, and the reason this paragraph is in the register rather than in a task report:

> **An empty gap record and an absent gap detector produce the same bytes.** Every row here must
> therefore carry evidence that something was looking — a poll count over a span, a frame count, a
> sample count — beside the gaps it found. `tapEnabledPolls: 1247 over 124.7 s` is what makes
> `tapDisabledIntervals: []` a measurement.

**That rule became a schema rule in Task 11, which is why the rows above gained companions in one
edit rather than four.** Each companion carries `looks` (how many times the detector ran) and
`watchedSpanNanos` (over what span) beside `gapsFound` and `lost`, and `isAMeasurement` answers
`false` when `looks == 0`. The three states a reader must be able to tell apart — *the site is
absent*, *nothing looked*, *something looked and found none* — are three different things on disk.

**But the five rows are reported from two places, and that split is itself a finding.** The trailer
of an observation log is written by the **producer**, at segment close, and carries a `GapWatch` for
each of the four rows below that name something a producer measured while recording. It refuses to
decode if one of those four is missing.

Row 1 is not one of them. Bytes lost to a truncated or corrupt record are a property of **reading the
file back**, discovered after the writer is gone; `JSONLReader.Result.bytesScanned` measures what a
*reader* examined, and a writer has no reader. Asked for that row anyway, a producer fabricates it —
measured, not predicted: the first version of this design carried the site, and the only assembler of
gap watches in the tree wrote `looks: 1` for it over a fixture in which not one byte had been
scanned, with a check three subsections later asserting the fabricated row *was* a measurement. Every
log would then have carried a number for that site meaning nothing, indistinguishable from a real
one, forever. So row 1 lives in `ObservationLogReadReport`, produced by the code that scanned the
bytes, and `GapSite` has no case a producer could use to claim it.

The consequence for this table: **a sixth row here needs a sixth `GapSite` case if a producer can
measure it**, and adding one makes every log written before it fail to decode — deliberate, and the
loud direction. A sixth row that only a reader can measure belongs on `ObservationLogReadReport`
instead, and the question to ask when adding one is *which side of the file is holding the
instrument*.

This is the seventh time in this project that a check has read a proxy for its subject rather than
the subject: the number consulted was *notifications our callback received*, whose subject is our
callback, not the tap.

**The consumer this exists for.** `framing-gates` refuses a beat with `observation stale` (D4). "This
beat spans a gap in the pointer record" is that refusal, and it needs a range to compare against — a
count gives it nothing to test.

### D6a-N — A name is an assertion, and nobody checks assertions written as names

**A name that describes what something covers is a claim about coverage, and it is the one kind of
claim no reviewer reads as a claim.** Four instances, all found on 2026-08-04, all in this tree:

| The name | What it asserts | What was true |
| --- | --- | --- |
| probe § 12's title, "a real `ObservationWriter` log" | the section runs against a real log | true of the writer, false of the clock — the fixture's samples were composition-relative while a real log is absolute host time |
| probe § 7.2, "the standing check on the unit" | it stands guard over the nanosecond unit | deleting the `mach_timebase` multiply leaves it GREEN; it mints its own stamp from the clock it checks |
| `ROADMAP.md`'s `geometry-types` row, "the AX and input conversion sites have still never executed" | that half of the bridge had never run in the product | a person's four-second recording wrote 327 pointer, 4 button and 2 AX records through exactly those sites. The row's stated reason — Input Monitoring denied on this machine — was true of the OLD bundle identifier and outlived the rename. **This table's own first draft got this row wrong too**, claiming the "zero callers" clause was still live when the row had already corrected it; the stale clause was the next sentence |
| `StageWindow.swift`'s header, "`NavigationSplitView` + `Inspector`, 100% standard SwiftUI" | the window has an inspector | **no `Inspector` exists anywhere in `Soredemo/`** — that header is its only occurrence in the tree, so the sentence describing the code is the sole evidence for it |
| `Tests/RenderTests/PointerPlacementTests.swift` | it tests pointer placement | it tests `StagePlanner.placement`'s GEOMETRY, five ways. `StageCompositor.pointerPlacement` — the function whose time conversion was wrong for a whole phase — has no `swift test` coverage at all |

**This class is more general than the fixture-shares-the-code's-frame class it was found beside.**
Sharing a frame of reference takes a coincidence: two independent things happening to be wrong the
same way. A name lying takes only that someone named it — at the moment it was accurate, and then
the code moved. The fourth row is the mildest and the most instructive: `PointerPlacementTests` is
not a lie, it is an AMBIGUITY between two real things called placement, and the untested one is
where the defect lived.

**Why the general form cannot be a gate, and it is not a tooling problem.** "Any
identifier whose every occurrence in the tree falls inside comments" was measured
here: 72 candidates, perhaps three real. The reason is that three different things
produce identical text, and the difference is not in the text:

| Class | Example in this tree | Truth value |
| --- | --- | --- |
| **the road not taken** | `DocumentGroup`, `AVMutableVideoComposition`, `SCRecordingOutput` | true and valuable — a rejected alternative is what a good doc comment exists to record |
| ~~**the road not yet walked**~~ **VOID** | ~~`SoredemoCore` — the library target app logic will move into~~ | **This class had exactly one instance and the instance dissolved.** `SoredemoCore` was never a promise: it is the Foundation-only product, and has been since KICKOFF, enforced by the build plugin and stated in five places (`KICKOFF.md` D6 and the `architecture-plugin` completion criterion, `ARCHITECTURE.md` D1, `AGENTS.md`, `Minting.swift`'s header — "the three things `SoredemoCore` is FORBIDDEN to do"). The sentence the scan found was written into `ROADMAP.md` hours earlier **by the author of this table**, and it names the wrong target. A class with no surviving instance is VOID, like row 14, rather than left standing for the next person to hang something else on |
| **the lie** | `Inspector` — a header describing this view as composed of one | false, and the description was the only evidence |

**How the misclassification happened, which is the part worth keeping.** The scan
did its job: it found a sentence naming something that does not exist in code.
The error was in reading it as a promise, and the reason was that the author
remembered writing it and remembered meaning it as one. **You do not audit what
you just wrote, because you remember the intent** — and intent is exactly what
distinguishes the three classes above, so remembering it feels like knowing the
answer. Same family as `ROADMAP.md`'s `251` (D6b's grading rule): credibility
borrowed from a neighbour. Here the neighbour was the author.

A scanner sees "mentioned, never coded" for all three. It cannot see tense or
intent. **`SoredemoCore` is the instructive one**: it is neither dead nor
fictional, it is a commitment — and a commitment is the one of the three that is
always NAMED. That is why the narrow form works where the general one does not:
`componentsAssertedInProseDoNotExistOnlyInProse` pins named claims, and a named
claim flipping from absent to present is the signal to retire its row rather than
a failure.

**What to do with it.** When sweeping comments or reviewing a diff, treat every identifier, section
title and register row as a proposition to be falsified once, the same as any sentence in a doc
comment. The question is always the same and always cheap: **what would have to be true for this
name to be honest, and is it?**

### D6a-E — `MediaError` is a live path with no exit, and that is not a documentation gap

**`MediaError.documentHasNoURL` is thrown at three sites in `ProjectDocument.swift`
(`:195`, `:212`, `:222`) and caught nowhere in the first-party tree.**

This is deliberately NOT filed under D6a-V above. Dead public API is a *static*
claim nothing exercised. An error that is thrown and never caught is a *live*
path whose behaviour at the moment it runs nobody has established: does it
propagate to a `try!` and trap? Get swallowed at an AppKit or SwiftUI boundary?
Reach a user as an alert, as a beachball, or as nothing at all? It is the same
shape as Task 6's throwing/non-throwing mismatch — **an error not translated into
anything a person will read.**

**The Phase 3 item is a question, not an edit: when `MediaError` is actually
thrown, what does the person using the app see?** The current answer is that
nobody knows, and no test, probe or human run has ever taken that path — a
document with no `fileURL` is the precondition, and every recording so far has
gone through `TemporaryFileMediaSink` instead.

---

### What the test count covers, and what it cannot

**`swift test`'s 462 tests do not link the app.** There is no app test target:
an `executableTarget` cannot be imported by a `testTarget` (`Package.swift`'s own
comment), so `Tests/AppSourceTests` reads `Soredemo/`'s sources **as text**
through `CheckerLexer` — it checks that code SAYS the right things, and cannot
run a line of it. Everything under `Sources/` is genuinely linked and executed.

The consequence is precise and worth stating wherever a count is quoted: for app
code, the executing instruments are `scripts/run-cross-boundary-probe.sh` (349
checks, `swiftc`-compiled against the real app sources) and a person running the
built `.app`. **`1a98402` lived in app code, and it was the person who found it.**

`Sources/Framing` and `Sources/Variants` are one file of three lines each —
placeholders that satisfy the module graph and contain no behaviour, so their
appearance in `libraryModules` should not be read as coverage of anything.

---

### D6a-V — Unexercised public API is an unverified capability claim

**A `public` symbol nothing calls, an enum case nothing produces, a field nothing
reads: each asserts a capability that has never been shown to work.** Four
instances in this tree on 2026-08-04:

| Symbol | The claim | Uses outside its own file |
| --- | --- | --- |
| `StageStyle.shadowRadius` / `.shadowOpacity` | the stage draws a shadow | **0** — six uses, all inside `RenderPlan.swift`'s initialiser and `Codable` conformance. Constructed, stored, encoded, decoded, never consulted |
| `CapturePermissions.blockingFailures()` | callers can ask what blocks recording | **0** |
| `Sources/Timeline/TimeRange.swift` | an epoch-less interval type is useful | **0** — its stated first caller moved to `HostRange` |
| `Degradation.noMicrophoneTrack` | a denied microphone degrades mildly | **0** — measured false; a denied microphone fails the whole `SCStream` |
| `Minting.now()` | callers can take a wall-clock reading | **0** — the recording path needs no wall clock, and inventing a caller is what this row refuses to do |
| `ProjectDocument.addMedia(_:fileExtension:)` | media can be added under a minted name | **0** — capture names its file at `beginSegment` |

**These numbers are pinned by `theUnexercisedPublicAPITableMatchesTheTree`**
(`Tests/AppSourceTests/AppSourceAllowListTests.swift`), not maintained by hand. A
table whose entire content is a set of counts must not be prose: that is how
`geometry-types`' "never executed" clause outlived the bundle-identifier rename.

**The instrument was wrong twice before these six numbers were right, and both
corrections changed an answer.** First draft used `grep`: three hits for
`TimeRange`, two of them a doc comment and a string in the architecture checker's
own exemption list — a deadness verdict counting a scanner's configuration as
usage. Second draft used `codeLinesNaming` (comments and strings blanked by
`SwiftSourceLexer`) but counted bare occurrences: `shadowRadius` came back with
six, every one inside its own type. Third draft counts uses OUTSIDE the declaring
file and still matched `CMTimeRange(` as a use of `TimeRange` — the lexer is
right about comments and naive about word boundaries. **Only the fourth is the
number.** Publish counts from an instrument that has been wrong about counts, and
the table inherits the error while reading exactly as confident.

**The policy: delete it, or mark it VOID with the register's discipline** — what
it claims, why that is unverified, and what would verify it. A symbol in neither
state is a promise the codebase is making on behalf of code that has never run.
The `noMicrophoneTrack` row shows why this is not pedantry: it did not merely go
unused, it was **wrong**, and the only thing consuming it was a `print`.

**Determining "no caller" requires the lexer, never `grep`.** Use
`codeLinesNaming(_:in:)` (`Tests/AppSourceTests/AppSourceAllowListTests.swift`),
which scans `SwiftSourceLexer.codeViewLines(of:)` — comments and string literals
blanked. A raw `grep` for `TimeRange` returns three hits, and **two of them are a
doc comment and a string in the architecture checker's own exemption list**: a
deadness verdict that counts a scanner's configuration as usage. That mistake was
made here, caught by eye, and would not have been caught by the next person. The
instrument already exists; the rule is to use it.

### D6a-R — The recorded fixture: redacted by schema, not by instance

**`Tests/HeadlessFixtures/segment-00-redacted.jsonl` is a real observation log from
a real recording of the task author's own screen** (row14,
`soredemo-preview-98460A97-…`, 411 lines: 251 `pointer`, 149 `tapDisabled`, 6
`button`, 3 `axChain`, 1 `logHeader`, 1 `logTrailer`), redacted and committed as
the first fixture Phase 3A-1's headless compositor tests read as a bundle
resource. **Half its value is that it is dirty**: 149 tap-disabled windows, an
`accessibilityUnavailable` flip in the header's `blindness`, two different blind
rates in one session. A four-second synthetic recording against an empty desktop
would not produce any of that, and it would repeat probe § 12's failure mode —
a fixture whose values were produced by the same misunderstanding as the code
under test — which a value the real writer recorded, through the real capture
path, before this test existed, structurally cannot.

**Adjudicated by schema, not by instance.** Enumerating the string fields
PRESENT IN THIS FILE finds one piece of user data (`AXElementRecord.title`).
Enumerating the string fields IN THE SCHEMA finds two: the second,
`KeySample.shortcut`, has **zero occurrences** in this file (no `"kind":"key"`
line exists in it at all) — an instance scan can never find it, and the next
fixture recorded by someone who used a keyboard shortcut would carry their
typing into git. `Tests/AppSourceTests/FixtureRedactionTests.swift`'s
`everyStringFieldInTheObservationLogSchemaHasAVerdict` walks every
`String`/`String?`/`[String]`-typed stored property of every record type under
`Sources/Project` (not only the observation-log record types — the scan is
directory-scoped, not file-scoped) and fails the build the day an unadjudicated
one appears:

| Field | Verdict | Reason |
| --- | --- | --- |
| `AXElementRecord.title` | **REDACT** | user data — UI text (button/window labels), already legible in the recording's own video; appears in `hit`, `ancestors[]`, `children[]` |
| `KeySample.shortcut` | **REDACT** | reflects what key combination a person pressed, even filtered to an approved-shortcut identifier by `InputObserver`; zero occurrences in this fixture, which is exactly why an instance scan cannot find it |
| `AXElementRecord.role` | keep | system AX role constant (e.g. `AXButton`), not user-authored text |
| `PointerSample.kind` | keep | literal discriminator `"pointer"` |
| `ButtonEvent.kind` | keep | literal discriminator `"button"` |
| `KeySample.kind` | keep | literal discriminator `"key"` (unused in this fixture; still schema) |
| `SecureInputInterval.kind` | keep | literal discriminator `"secureInput"` |
| `TapDisabledInterval.kind` | keep | literal discriminator `"tapDisabled"` |
| `AXChainRecord.kind` | keep | literal discriminator `"axChain"` |
| `ObservationLogHeader.kind` | keep | literal discriminator `"logHeader"` |
| `ObservationLogTrailer.kind` | keep | literal discriminator `"logTrailer"` |
| `ObservationLogHeader.mediaFilename` | keep | app-minted relative filename (`ProjectPackageIO`), never typed by a person; the log↔recording join key, not content |
| `MasterSegment.mediaFilename` | keep | same app-minted filename, on `SegmentTable`; not present in this observation log (lives in `project.json`) — reported because the scan walks all of `Sources/Project` |
| `ProjectSnapshot.mediaFilenames` | keep | array of the same app-minted filenames, on the project manifest; not present in this observation log either, same reason as above |

**A correction to this task's own brief, recorded rather than silently fixed.**
The brief's first-draft table (one person's reading of the schema, offered as the
reason this scan has to exist rather than a substitute for running it) named
`KeyRecord.shortcut` — the type is `KeySample`, not `KeyRecord` — `kind (×6
types)` where the scan finds **8** (`AXChainRecord`, `ButtonEvent`, `KeySample`,
`ObservationLogHeader`, `ObservationLogTrailer`, `PointerSample`,
`SecureInputInterval`, `TapDisabledInterval` each carry their own `kind: String`),
and `epoch.id`, `blindness[]`, `detectedBy`, `disabledBy`, `phase`, `button`,
`truncation`, `lowerBoundFrom`, `gapWatches[].site`, `gapWatches[].lostUnit` —
none of which the scan reports, because every one of those is stored as an
**enum** (`BootEpoch`, `[ObservationBlindness]`, `TapDisableDetection`,
`TapDisableReason?`, `ButtonPhase`, `PointerButton`, `ChainTruncation`,
`TapBlindWindowLowerBound`, `GapSite`, `GapUnit`), several with a `String` raw
value. That is exactly the distinction "by schema" exists to draw: the STORED
PROPERTY's type is the enum, a small closed set of ASCII case names, not open
`String` text — real discipline this schema already had, not a scan failing to
see something. The corrected table above is what the scan actually reports,
verified by running it (`swift test --filter FixtureRedaction`), not transcribed
from the brief.

**Two gates, both in `FixtureRedactionTests.swift`, both observed red before
being trusted green:**

1. **Content** — `noCommittedFixtureCarriesAnUnredactedStringField` reads every
   `.jsonl` under `Tests/HeadlessFixtures/` and requires every `"title":"…"` and
   `"shortcut":"…"` value to be exactly the placeholder `[redacted]`. Observed
   red against a synthetic scratch fixture (`"title":"SYNTHETIC-NOT-REAL-USER-DATA"`,
   never real user data, deleted immediately after). **Fixed en route**: the
   brief's `#expect(value == "[redacted]", …)` form leaks the compared value into
   Swift Testing's own auto-diagnostic regardless of the message text — measured
   directly, the framework printed `value → "SYNTHETIC-NOT-REAL-USER-DATA"`
   despite the custom message never naming it. The gate now computes the
   `Bool` first (`let isRedacted = value == "[redacted]"; #expect(isRedacted, …)`)
   so there is nothing left for the macro to decompose — the framework's own
   diagnostic machinery does not become a second leak path alongside the one the
   message text guards against.
2. **Consumption** — `theRenderPathNeverReadsARedactedField` scans
   `Sources/Headless` and `Sources/Render` for a `.title` or `.shortcut` read.
   Observed red against a scratch symbol temporarily appended to
   `Sources/Headless/CursorArt.swift` and reverted in the same step.

**The redaction script, `scripts/redact-observation-log.swift`, is a text
transform over the raw bytes — not a decode/re-encode.** It walks the file once,
rewriting only the value span of a `"title":"…"` or `"shortcut":"…"` key
(JSON-escape-aware, so an embedded `\"` does not end the value early) to the
placeholder, and copies every other byte through unchanged. **Nothing the
compositor consumes is touched**: every timestamp, every coordinate, the
`anchor`, the boot epoch, the geometry revision, and all 149 `tapDisabled`
intervals in the committed fixture are byte-for-byte what the real writer
recorded. Verified two ways after producing the fixture, neither of which prints
a field value: (a) every `title`/`shortcut` occurrence in the output equals the
placeholder (4 `title`, 0 `shortcut`); (b) `diff` between the original and the
redacted file, with both sides' `title`/`shortcut` values independently
normalised to the same placeholder text by `sed` — a tool distinct from the
redaction script itself — returns empty, twice (once cross-checked against the
script's own normalisation of the original). An empty diff under that
normalisation is evidence about **every other byte** in a 98,155-byte, 411-line
file.

**The reproducibility cost, stated rather than left as zero by omission.**
Reproducing this exact redaction run needs the unredacted original, which exists
only on the machine that recorded it and is never committed. **This redaction is
auditable by its author and not by its readers.** A future reader of the
committed fixture can mechanically verify the negative — Gate 1, forever, on
every commit — that no `title` or `shortcut` value is anything but the
placeholder. What a reader cannot do is verify that the right things were
removed and nothing else changed, because the original is not there to diff
against. That is a known, accepted cost of choosing a recorded fixture (dirty,
uncomputed, half its value the recording's own mess) over a synthetic one, and
it is written down here because an unwritten cost reads as a zero cost, and this
one is not zero.

**Resource path, decided by measurement.** `HeadlessTests`' `Package.swift`
target declares `resources: [.copy("../HeadlessFixtures/segment-00-redacted.jsonl")]`
— the parent-directory form SwiftPM was expected to possibly reject. It did not:
`swift build` succeeded and the file was found copied into
`.build/…/SoredemoCore_HeadlessTests.bundle/Contents/Resources/segment-00-redacted.jsonl`.
The fixture therefore stays at `Tests/HeadlessFixtures/`, sibling to `Tests/`
rather than nested under `Tests/HeadlessTests/`, so a future fixture shared by a
second test target does not have to live inside the first one's directory.

## D6b — The platform-premise register: what this app believes about macOS

**Every row is a claim about the operating system that this code depends on and that Apple has not
promised.** Several were measured *because* the header does not say — which is the honest position,
and also the one that expires without warning.

**Grading rule: if the source is a conversation rather than a file, the grade is `[prose]` — no
matter how hard the sentence reads.** The test is asked of each assertion AS IT IS WRITTEN, never
of the row as a whole: **which file, and which field?** A claim that cannot name both is `[prose]`,
and a row may carry both grades in different sentences.

This rule exists because grading a row by reading it does not work. On 2026-08-04 `ROADMAP.md`'s
`cursor-render` row claimed probe § 12.1 ran "off Task 5.5's row-14 REAL recording (251 real
pointer samples…)". It never did — § 12.1 writes a three-record fixture, and `grep -rn 'row-14'`
returns nothing. The `251` was recalled in conversation, not counted from a file; it is even
*self-consistent* with the trailer arithmetic elsewhere (`411 = 1 + 1 + (251+6+0+3+149)`), so
nothing about the sentence looks soft. **What made it credible was its neighbours**: rows 62, 64
and 67 cite that same recording correctly. Credibility was inherited from adjacency, which is
exactly what a per-row reading cannot detect.

**Why this is a table and not the design doc's prose.** These claims are currently scattered across
design-doc sections, code comments and commit messages. Each was true when measured; none of them
announces itself when it stops being true. And unlike a rule that a scan can enforce, the trigger
here is external: **a macOS major version bump.** The floor is 26 and 27 already exists, so this
table is, today, the list of what has to be re-measured when 27 becomes the floor.

**The re-written expectation is not a substitute for the row.** Task 10's `which-channel` expectation
was rewritten from "the OS delivers this notification" (unwitnessable — no mutation here makes the OS
behave otherwise) into "we record the channel we were told about" (witnessable, and it has a red).
That rewrite is correct and it **erases the original claim's exposure**: if the OS changes, the
rewritten expectation still passes — we go on faithfully recording — while the conclusion built on
the original claim is quietly wrong. So a rewritten row leaves a row here. They are a pair.

**This register is also where the third kind of check belongs.** Task 12's red-certificate sampling
of the probe found three classes, not two: reddenable, tautology, and **a check whose subject is the
platform rather than this repository** — no change to these sources can alter its answer, so it can
never earn a certificate, and it is not decoration either. In the wild that class was **1 of 20**,
which makes it an ordinary population rather than a theoretical corner. The sample's instance is the
probe's `check(!IsSecureEventInputEnabled(), "precondition: secure input is off before this check
starts…")`, whose premise is **row 13** below; it guards the toggle experiment that produced that
row, and deleting it would let the experiment measure — and then release — somebody else's state.

Two consequences. Such a check must not be counted among the ones that gate the product; and when
one is written, the premise it asserts should already be a row here, or become one. A precondition
with no row is a belief about macOS held only in a guard.

| # | The claim | How it was established | On | What breaks if it changes |
| --- | --- | --- | --- | --- |
| 1 | `SCRecordingOutput` mixes the microphone into the system-audio track; `mixesAudioWithMicrophone` is macOS 27+ | measured over four runs (F2-4), header confirmed | 26.5.2 | the whole reason `CaptureSession` hand-writes three `AVAssetWriterInput`s instead of using `SCRecordingOutput` |
| 2 | `SCFrameStatusIdle` is 42–84% of callbacks; `minimumFrameInterval` is a **floor**, not a cadence (9–37 fps observed against 60 requested) | measured, four runs | 26.5.2 | "a callback is not a frame" — every frame count and the conservation law's shape |
| 3 | `SCStream` stamps presentation times as host time at timescale 1e9, so `pts.value` is nanoseconds since boot | measured: `value=451316246248958 timescale=1000000000` | 26.5.2 | the `Int64` overflow guard in `Nanoseconds(rationalSeconds:timescale:)` is sized for this |
| 4 | System audio arrives 2ch/32-bit float/48 kHz **planar**; the microphone 1ch/32-bit float/44.1 kHz **interleaved** | measured, printed by `CaptureSession` on every run | 26.5.2 | `AudioInterleave` exists only for the planar case; the two are told apart by format in Task 8 step 2 |
| 5 | A `.mov` cannot store non-interleaved LPCM — a passthrough input refuses it with `-11800 / -12780` | measured; four offline configurations, only one reproduces the code | 26.5.2 | if it became storable, `AudioInterleave` is dead weight rather than load-bearing |
| 6 | `SCStreamFrameInfoContentRect` arrives as a CGRect **dictionary representation**, not an `NSValue` | measured — an `as? NSValue` cast failed silently on every frame of a whole recording | 26.5.2 | `CGGeometryBridge.pointRect(fromFrameAttachment:)` accepts both forms for this reason |
| 7 | With `destinationRect` unset, ScreenCaptureKit anchors window content at the buffer's **origin** | measured; `SCStream.h` says only "the entire output surface is used" and promises nothing about placement | 26.5.2 | nothing — this is why `destinationRect` is now set explicitly. The row stays as the reason |
| 8 | A display's backing scale changes with its mode: a native 2704×1690 mode reports points == pixels where the Retina mode reports 2:1 | measured across a programmatic mode change | 26.5.2 | `CaptureSession` re-derives scale on every reconfiguration instead of trusting its constructor argument |
| 9 | A `.listenOnly` event tap is disabled by the OS **without** `kCGEventTapDisabledByTimeout` being delivered — and the notification channel is unreliable even for `.defaultTap` | measured; a `.defaultTap` control received it on one run and not the next while the OS reported both disabled | 26.5.2 | polling `CGEvent.tapIsEnabled` is the only detection. If the notification became reliable, the poll is redundant but harmless |
| 10 | Sustained overload (a stall on every pointer event at 60–120 Hz) disables a tap between 10 and 20 ms; a **125 ms cost per click** does not, over 30 s and 18 stalls | measured, two sweeps with a positive control | 26.5.2 | not the reason AX runs off the callback thread — that is failure-mode asymmetry (D2-18). If this tightened, the asymmetry argument is unaffected |
| 11 | `CGEventTapEnable(tap, false)` from inside the process **does** deliver `kCGEventTapDisabledByUserInput` | measured, Task 10 human step 1 | 26.5.2 | that step validates edge arithmetic, not the poll. If the notification stopped, the step silently starts testing the poll instead — and its label would be wrong |
| 12 | `CGEventTimestamp` is nanoseconds on the same base as `CMClockGetHostTimeClock` | measured: 395 real tapped timestamps inside the plausible band; `CGEvent(source: nil)!.timestamp` is **0**, so there is no permission-free source of one | 26.5.2 | every instant in the observation log, and the `implausibleEventTimestampCount` band |
| 13 | Terminal's Secure Keyboard Entry is **off** by default, and a `sudo` password prompt does **not** raise system-wide secure input | measured, with the credential verified expired beforehand so the cached-credential explanation was excluded | 26.5.2 | only the verification instruction. Recorded because the wrong answer cost a run |
| 14 | ~~A pointer-only `.listenOnly` tap needs no Input Monitoring grant~~ **FALSIFIED AS A UNIVERSAL, and the two states are not the same.** Direct observations only; the mechanism is deliberately not stated — see D6b-14a | **two instruments, one subject, opposite answers.** Both ran as `video.soredemo.Soredemo` on 26.5.2 (25F84). Harness, `.denied`: `tapCreate` non-nil, `tapIsEnabled` **false on 50 of 50 polls** over 4.9 s, five synthetic mouse-moved events posted, **zero delivered**. Real recording, `notDetermined` after `tccutil reset ListenEvent`: over the 9.35 s before the grant landed, 82 disabled windows losing 8.40 s (**89.9%**) — and **49 pointer samples and 2 button events were delivered anyway** | 26.5.2 (25F84) | `CapturePermissions`' degradation model, and what a first-run user can do before granting anything. "Creates successfully but delivers nothing" is false as a universal: it holds under `.denied` and not under `notDetermined` |
| 15 | `mach_timebase_info` is 125/3 on this hardware | measured twice, a day apart | Apple Silicon, 26.5.2 | nothing directly — every conversion goes through `CMTime`/`Nanoseconds`. Kept because it is the constant a hand-rolled conversion would need, and hand-rolling it is the mistake |
| 18 | **`CGPreflightScreenCaptureAccess()` returning `granted` is not evidence that capture will work.** The absence direction still holds; the presence direction does not | measured twice, Phase 2B human step: `tccutil reset ScreenCapture video.soredemo.Soredemo` → "Successfully reset", then `CGPreflightScreenCaptureAccess()` → `granted`, then `SCStream.startCapture()` → **-3801** | 26.5.2 (25F84) | any guard of the form `status(of: .screenRecording) != .granted` — it never fires on this machine, so a first-run path gated on it is dead code. `CapturePermissions.degradation` is unaffected: it is about absence |
| 19 | **`SCStreamErrorUserDeclined` (-3801) names screen recording, and the service actually denied may be the microphone.** The error code's subject and the failing service are not the same thing | measured, Phase 2B human step. `log show --predicate 'subsystem == "com.apple.TCC"'` says verbatim: *"Prompting policy for hardened runtime; service: kTCCServiceMicrophone requires entitlement com.apple.security.device.audio-input but it is missing"* → *"Policy disallows prompt"* → *"access to kTCCServiceMicrophone denied"* | 26.5.2 (25F84) | every diagnosis that reads -3801 as a Screen Recording problem. The instrument that answers correctly is the TCC log, not the error code |
| 16 | Foundation's `JSONDecoder` refuses **every** route to a non-finite `Double` — `1e400`, `-1e400`, bare `NaN`, `"NaN"` | measured, four cases | Xcode 27.0 (27A5228h) | `AXChainRecord`'s validating decoder is untestable through JSON and is demonstrated through a property list instead. If this loosened, the JSON path needs its own case |
| 17 | ~~re-signing invalidates a grant while the Settings pane still shows it enabled~~ **FALSE AS STATED.** TCC binds a grant to signing identity **and** bundle identifier, and re-signing with the *same* identity and identifier does **not** invalidate it | **MEASURED, with the subject known.** SpikeA under `open -n`: all three permissions granted, `build.sh` re-signs it, all three still granted — identical. The original observation (pane enabled, API not granted) had TWO SUBJECTS: the pane was showing `SoredemoSpikeB` while the API was answering for `com.cmuxterm.app`. | — | every spike's grant lifecycle, and `capture-permissions`' first-run flow being testable at all |

**Audited after the identity finding, and two rows did not survive.** Every row was checked for
whether its "how it was established" column could actually be filled — the same audit the ledger
got. Fifteen were measurements with a recorded command, a control, or a number. Two were not:

- **Row 14 is void.** It was inferred from the order in which steps failed, and every one of those
  steps ran under an identity that already held both grants. Nothing was measured; a sequence was
  read as a cause. It is the row that reads most like a finding, which is why it stood for two days.
- **Row 17 was re-measured and is false as stated.** Its observation was real — the pane said
  enabled, the API said not granted — but the two halves had different subjects: the pane was
  showing `SoredemoSpikeB` while the API was answering for `com.cmuxterm.app`. Re-run with the
  subject known: SpikeA under `open -n` holds all three permissions, `build.sh` re-signs it, and all
  three are still held, byte-identical in the report. **Re-signing with the same identity and the
  same bundle identifier does not invalidate a grant** — which is what a Developer ID designated
  requirement implies, and it went unchecked for two days because a plausible story arrived first.

**A row that cannot fill its second column is marked unmeasured, not re-labelled.** That is the
difference between this audit and the mislabelled-record register in `AGENTS.md`: there, correct
results were filed under the wrong subject and re-labelling is the whole remedy. Here, two rows
never had a measurement to file.

**Row 17 is the one with a cost attached.** The "never asked" state for Screen Recording on the
**product's** bundle identifier is a spent-once asset: `capture-permissions` needs it to test the
first-run degradation path. Every spike therefore uses its own identifier (`video.soredemo.SpikeA`,
`SpikeB`, `SpikeC`) so a throwaway tool cannot consume it.

### D6b-14a — the row-14 recording, as direct observation

**Written before the mechanism is settled, on purpose.** Two of this project's own instruments gave
opposite answers about the same subject, and a register row that picks one of them before the
conflict is resolved becomes a row that contradicts its own evidence. What follows is what was
observed. Nothing here depends on why.

**Subject.** macOS 26.5.2 (25F84), `video.soredemo.Soredemo`, 2026-08-04 08:04, one segment of
19.90 s. Evidence: `observations/segment-00.jsonl`, 411 lines, with `media/master-00.mov`, plus a
`log show --predicate 'subsystem == "com.apple.TCC"'` capture.

**The cut between the two halves is the TCC log's `kTCCServiceListenEvent` reading `authValue=2`
at 08:04:04.775**, which is +9.345 s into the recording. It is *not* the `kTCCServiceAccessibility`
`Modify` at 08:04:03.674 — those are 1.1 s apart and picking the other one moves every boundary
below. Named because these numbers cannot be rebuilt without it.

| | disabled windows | lost | share | pointer | button |
| --- | --- | --- | --- | --- | --- |
| before the grant (9.35 s) | 82 | 8.40 s | **89.9%** | **49** | **2** |
| after the grant (10.55 s) | 67 | 6.55 s | **62.1%** | 202 | 4 |

**What this settles on its own.** "Creates successfully but delivers no events" is **false as a
universal**: delivery before the grant was non-zero. And the grant does not end the disabling —
62.1% of the span after it is still blind. So the grant explains the step from 89.9% to 62.1% and
does not explain the remainder.

**One quantity left unexplained rather than smoothed.** The single alive stretch longer than 300 ms
begins at **9.173 s**, which is **172 ms before** the grant reading at 9.345 s. The poll interval is
100 ms, so 172 ms is **not** within polling resolution and must not be written as though it were. It
may be nothing. It may be the first hint that the grant is not what revived the tap.

**`[hypothesis]`, not measured:** that the residual 62.1% is the callback-overload disabling of D6b
row 10. The knob that would settle it: run once with the compositor off and once with the AX walk
off, and see whether 62.1% moves. **A number that does not move when you change the resource was
never about that resource** — the same discriminator that saved an hour on the writer-receiver
stall, used here in the positive direction.

**`authReason` is not decoded.** The TCC log reports `authReason=4`; no machine-checkable table maps
those values, so the number is recorded and not interpreted.

**Still open, and it is what row 14 now turns on:** whether `.denied` and `notDetermined` genuinely
differ in tap behaviour, or whether something else separates the two runs. Both reported
`authValue=0` before their grants, so TCC's own value does not distinguish them — which is D6b
row 18's shape again, one service over.

---

### D6b-27 — the 78 declarations condemned at exactly macOS 27.0

**Same register, same trigger, one instrument.** Every row above is a belief about macOS that
Apple has not promised and that expires on a version bump. These 78 are the subset where Apple
*has* said it, in the SDK, with a version — so they are not beliefs at all, and they belong here
for the trigger rather than for the uncertainty: **an SDK or floor bump is what makes them act.**

They were not read off a changelog. `scripts/scan-sdk-deprecations.py` derives the module list
from this repository's own `import` lines, reads both the ObjC headers and the `.swiftinterface`
files, and reproduces seven hand-measured rows before it will report anything. Re-run it; do not
maintain this table by hand. Its numbers on Xcode-beta `MacOSX27.0.sdk`: 2120 deprecated
declarations over 15 modules — 1620 already dead at our 26.0 floor, these 78 at 27.0, 110 carrying
Swift's no-version sentinel, 312 whose version it cannot parse.

**78 is a count, not a lower bound, and that took settling.** Twenty of the 312 unparsed rows were
sampled by index; all twenty were the same kind of thing — a deprecation with no macOS version
assigned — in four spellings. Knowing the spellings, all 312 were then classified exhaustively
rather than estimated: 191 `API_TO_BE_DEPRECATED`, 109 `@available(*, deprecated)`, 5 bare
`__deprecated`, 3 `@available(macOS, deprecated)` with no version, 4 `#define` templates whose
version is a macro parameter. **None of them can be a hidden 27.0 row**, because 27.0 would have
been written as a number. The sample found the forms; the census closed the question.

Two real parser bugs surfaced on the way, both of which had silently deleted true rows: a message
containing an unbalanced `(` hid `macos(10.3,10.11)` from the argument capture, and the whole-file
quote-state machine written to fix that was inverted by a stray `"` in a comment — `NSError.h` came
back with its *code* blanked and its *strings* intact, and both of its genuine 27.0 rows vanished
with no other symptom. Both are now in the scan's parser control.

## The replacement column, which is what the decision turns on

Every row's deprecation names — or fails to name — a successor, and the three cases have nothing in
common: reachable at our floor (migrate now), introduced at 27.0 (unreachable — two implementations
or move the floor), or no successor named at all (a direction signal, not a migration path).

**They are one successor stack, not eight independent rows.** The replacement names converge:
`Receiver` types replacing `AVAssetWriterInput` and its four adaptors, `Provider` types replacing
`AVAssetReaderOutput` and its adaptors, `CVReadOnlyPixelBuffer` and `CMReadySampleBuffer` replacing
bare buffers, `.init(configuration:)` replacing the mutable classes, `export(to:as:) async`
replacing the imperative export. That is one Swift-concurrency-native, value-typed redesign of the
read/write/compose stack, so the unit of analysis is the successor stack — not an API at a time.

**And the stack Phase 2B needs is reachable at 26.0.** Typechecked at `arm64-apple-macos26.0` by
`scan-sdk-deprecations.py --floor`, which commits the probes rather than describing them:
`AVAssetWriter.inputPixelBufferReceiver(for:pixelBufferAttributes:)`,
`AVAssetWriterInput.PixelBufferReceiver.append(_:with:)`,
`AVAsynchronousVideoCompositionRequest.finish(withComposedPixelBuffer:)`,
`AVVideoComposition.Configuration`, `AVAssetReader.outputProvider(for:)`, and
`AVAssetExportSession.export(to:as:)`. **The one exception is the sample-buffer renderer path**:
`AVSampleBufferVideoRenderer.Receiver` and `AVSampleBufferAudioRenderer.Receiver` are
`@available(macOS 27)`, measured — a reference to either fails at 26.0 and compiles at 27.0.

**A deprecation on this list names a successor that does not exist.** `AVVideoCompositionRenderContext.newPixelBuffer`
says *"Use `newReadOnlyPixelBuffer()` instead"* — and `newReadOnlyPixelBuffer` appears exactly once
in this entire SDK: inside that message. It is on no type, the compiler knows it at neither
`arm64-apple-macos26.0` nor `27.0`, and `grep -rn` over every AVFoundation header returns only the
string telling you to call it. This is the second wrong successor measured in one day and the
stronger of the two: `finish(withComposedVideoFrame:)` was a wrong name for a real selector, this is
a name for nothing. Phase 2B's compositor therefore uses `newPixelBuffer()`, which is correct and
warning-free at the 26.0 floor, and the successor is unavailable rather than declined.

**WHERE THESE CALLS LIVE IN THIS REPOSITORY, so the trigger reaches code and not only a table.**
A version bump is only a trigger if someone can tell which files it fires on:

| File | Calls on this list | Behind a seam? |
| --- | --- | --- |
| `Soredemo/Capture/MasterWriter.swift` (`LegacyMasterWriter`) | `addInput:`, `startWriting`, `AVAssetWriterInput.append(_:)` | **yes** — `MasterWriting`, with a second conformance already written |
| `Soredemo/Export/MP4Exporter.swift` | `AVAssetReader.addOutput`, `startReading`, `AVAssetWriter.addInput`, `startWriting`, `AVAssetWriterInput.append(_:)`, `readyForMoreMediaData`, `expectsMediaDataInRealTime` | **no** — nothing to swap |

The second row is the one to read twice. It is **new** media-writing code, written directly against
the API set the seam one row above exists to keep new code away from — and it was written that way
for two measured reasons, not an oversight: `appendImmediately(_:)` stalls whenever three receivers
are *created* (12/12 runs, frames 77–123, even with only one fed), and both `MasterWriting`
conformances hardcode `fileType: .mov` and mandate three tracks, which a one-track `.mp4` export
cannot use at all. The second reason holds even if the stall is fixed tomorrow.

Leaving it unseamed may well be right — seven calls, one track, no concurrent multi-track shape to
get wrong. **That judgement belongs in the file, and its absence is what this row exists to fix**:
until this table existed, a floor bump would have found `LegacyMasterWriter` by its seam and missed
`MP4Exporter` entirely.

**Every successor mapping on this page is `[prose]` grade, including the one this project depends
on most.** 0 of 32 named successors in the 27.0 bucket come from a machine-checkable field
(`API_DEPRECATED_WITH_REPLACEMENT`, `renamed:`); all are read out of `API_DEPRECATED` message text
written for a human. That includes *"`AVAssetWriterInput.append(_:)` becomes
`SampleBufferReceiver.append(_:)`"* — the sentence Spike D's whole subject rests on. If that mapping
is wrong, the spike reproduced and then un-reproduced a stall in a type unrelated to our write path.
It is almost certainly right; it is still prose, and it must be read at prose confidence.

Probes are **type references, never calls**. Three call probes written from the deprecation messages
failed at 26.0 and read exactly like unavailability; all three were signature mistakes, and one
message names an API that does not exist — it says `finish(withComposedVideoFrame:)` and the shipped
selector is `finish(withComposedPixelBuffer:)`. A deprecation message is prose, not a signature.

**A second instrument, because the SDK cannot answer everything.** The SDK says what Apple has
decided; it does not say whether the successor works. Searched: there is no published migration
guide for this stack, and the one field report on `AVAssetWriterInput.PixelBufferReceiver.append`
is an [indefinite hang](https://developer.apple.com/forums/thread/813867) — the task suspends and
never resumes, no crash, no error, CPU to zero, filed January 2026 with no Apple reply. So the two
instruments point opposite ways: the SDK condemns the predecessor, and the field says the successor
hangs. Neither alone is the answer, and this row exists so that neither gets read as one.

## The successor stack works at the floor for ONE receiver — and stalls at three

**The headline of this section used to stop at "works at the floor", and Phase 2B's Task 6 showed
that reading was too wide.** What was measured was one receiver at a time. A real capture session
needs three — video, system audio, microphone — and under three simultaneous receivers
`appendImmediately(_:)` stalls between frames 64 and 112 and never recovers: no error, no crash, no
diagnostic. Codec-independent (h264 and ProRes4444 both), reproduced across a dozen runs, and the
*same* workload through the awaiting `append(_:)` completes 120 frames in under 0.3 s every time.

`MasterWriting.append` is synchronous and non-throwing by design — a compositor callback must not
suspend — so a conformance has no choice but `appendImmediately`. **The successor conformance is
therefore not usable for a real multi-track recording today**, which is a second and much stronger
reason for the ruling that the shipping capture path stays on `LegacyMasterWriter`. That ruling was
made for verification cost; it now also holds on capability.

Read `Soredemo/Capture/SuccessorMasterWriter.swift`'s known-gap paragraph before wiring the
successor anywhere.

**What survives from the original measurement, unchanged:** the successor APIs exist at the 26.0
floor, they are reachable, they produce byte-identical output to the legacy path on the two
properties that decided `AVAssetWriter` over `SCRecordingOutput` — two audio tracks and the
ITU_R_709_2 colour triple, compared by reading the finished files back — and the frame-137 stall
that started all of this really was a lifecycle mistake and not an API fault. None of that is
withdrawn. What is withdrawn is the leap from "one receiver works" to "the stack works".

## The one-receiver measurement, after a wrong answer

`spikes/2026-08-03-writer-receiver-hang`, on **macOS 26.5.2 build 25F84**:

| Writer lifecycle | `PixelBufferReceiver` | `SampleBufferReceiver` |
| --- | --- | --- |
| `add(input)` + new receiver + `startWriting()` | **stalls at frame 137, forever** | stalls at 135 |
| receiver attaches the input + `start()` | **900 / 900**, 3000 / 3000 on a longer run | **900 / 900** |

**One knob, opposite outcomes, so the knob is the cause.** The successors carry
their own lifecycle — `addInput:`'s deprecation says *use the appropriate
`AVAssetWriter.inputReceiver(for:…)` overload*, `startWriting`'s says *use `start()`* —
and the first version of that spike called `add(input)`, took a receiver for the same input, and
started with the deprecated `startWriting()`. Three APIs from two generations on one writer. The
stall was the writer in a state nobody designed.

**The wrong answer is recorded because of how it was wrong.** It read "the successor stack cannot
write a recording", which is the conclusion that costs the least work: migrate nothing, change
nothing, file it under someone else's name. Three knobs had already failed to move the stall index
— pool threshold 20 to 5000, frame area 1/16 to full, holding every buffer alive — and a number
that does not move when you change the resource was never about a resource. The legacy control
reaching 600/600 ruled out "the rig is broken" and nothing more, because it differs from the
treatment along exactly the axis that failed.

**The trigger, which is what this belongs in D6b for:** re-run Spike D on every OS or SDK version
bump. It needs no permission, writes to a temp directory, deletes it on both exit paths, and takes
under a minute. `26 fails / 27 works` and `both fail` point at opposite strategies, and the run
costs nothing.

**The [field report](https://developer.apple.com/forums/thread/813867) is not thereby refuted.**
Nobody here has seen its code. What is established is narrower and still useful: the reported
symptom is producible from a usage error, so the report on its own is not evidence of an API fault.

**What breaks if it changes: most of Phase 2B's intended API surface.** `export-basic` was to be
`AVAssetWriter` + `AVAssetWriterInputPixelBufferAdaptor`; `render-core` was to be
`AVVideoCompositing`. Both are on this list, one version above the floor, before either row has a
line of code. `AVMutableVideoComposition` is *not* here — it is in the 26.0 bucket, dead at the
floor since before this phase began, which is how this scan started.

**We call none of them.** Two clean builds — `swift build` for the package, `xcodebuild` for the
app — report zero deprecated call sites. Measured with `--in-use`, because a warm build recompiles
nothing and prints nothing, and that reads exactly like a clean bill of health.

| Module | Declared in | Condemned at 27.0 (78 total) |
| --- | --- | --- |
| AVFoundation | `AVAssetDownloadTask.h` | `AVAggregateAssetDownloadTask`, `AVAssetDownloadTaskMediaSelectionKey`, `AVAssetDownloadTaskMediaSelectionPrefersMultichannelKey`, `AVAssetDownloadTaskMinimumRequiredMediaBitrateKey`, `AVAssetDownloadTaskMinimumRequiredPresentationSizeKey`, `AVAssetDownloadTaskPrefersHDRKey`, `AVAssetDownloadTaskPrefersLosslessAudioKey`, `URLSession`, `aggregateAssetDownloadTaskWithURLAsset`, `assetDownloadTaskWithURLAsset`, `loadedTimeRanges`, `options` |
| AVFoundation | `AVAssetWriterInput.h` | `AVAssetWriterInputCaptionAdaptor`, `AVAssetWriterInputMetadataAdaptor`, `AVAssetWriterInputPixelBufferAdaptor`, `AVAssetWriterInputTaggedPixelBufferGroupAdaptor`, `appendSampleBuffer`, `expectsMediaDataInRealTime`, `readyForMoreMediaData`, `requestMediaDataWhenReadyOnQueue` |
| AVFoundation | `AVSampleBufferVideoRenderer.h` | `NSError`, `NSNumber`, `error`, `flushWithRemovalOfDisplayedImage`, `payload`, `property`, `requiresFlushToResumeDecoding`, `status` |
| AVFoundation | `AVAssetReaderOutput.h` | `AVAssetReaderOutputCaptionAdaptor`, `AVAssetReaderOutputMetadataAdaptor`, `alwaysCopiesSampleData`, `copyNextSampleBuffer`, `markConfigurationAsFinal`, `resetForReadingTimeRanges`, `supportsRandomAccess` |
| AVFoundation | `AVQueuedSampleBufferRendering.h` | `?`, `enqueueSampleBuffer`, `flush`, `hasSufficientMediaDataForReliablePlaybackStart`, `stopRequestingMediaData` |
| AVFoundation | `AVVideoCompositing.h` | `AVAsynchronousCIImageFilteringRequest`, `finishWithComposedVideoFrame`, `newPixelBuffer`, `sourceFrameByTrackID`, `sourceSampleBufferByTrackID` |
| AVFoundation | `AVAssetExportSession.h` | `cancelExport`, `outputFileType`, `outputURL`, `progress` |
| AVFoundation | `AVSampleBufferAudioRenderer.h` | `AVSampleBufferAudioRendererFlushTimeKey`, `AVSampleBufferAudioRendererOutputConfigurationDidChangeNotification`, `AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification`, `flushFromSourceTime` |
| AVFoundation | `AVVideoComposition.h` | `videoCompositionCoreAnimationToolWithPostProcessingAsVideoLayer`, `videoCompositionCoreAnimationToolWithPostProcessingAsVideoLayers`, `videoCompositionWithAsset` |
| Foundation | `NSItemProvider.h` | `initWithItem`, `loadItemForTypeIdentifier`, `registerItemForTypeIdentifier` |
| AVFoundation | `AVAssetReader.h` | `addOutput`, `startReading` |
| AVFoundation | `AVAssetWriter.h` | `addInput`, `startWriting` |
| AVFoundation | `AVPlayerItem.h` | `accessLog`, `errorLog` |
| AVFoundation | `AVPlayerItemOutput.h` | `copyPixelBufferForItemTime`, `initWithPixelBufferAttributes` |
| AVFoundation | `AVPlayerOutput.h` | `defaultPixelBufferAttributes`, `setOutputPixelBufferAttributes` |
| Foundation | `NSError.h` | `init`, `new` |
| AVFoundation | `AVAsset.h` | `audiovisualTypes` |
| AVFoundation | `AVContentKeySession.h` | `AVSampleBufferAttachContentKey` |
| AVFoundation | `AVExternalStorageDevice.h` | `notRecommendedForCaptureUse` |
| AVFoundation | `AVPlayerLayer.h` | `copyDisplayedPixelBuffer` |
| AVFoundation | `AVRenderedCaptionImage.h` | `pixelBuffer` |
| AVFoundation | `AVTimedMetadataGroup.h` | `initWithSampleBuffer` |
| AppKit | `NSPanGestureRecognizer.h` | `numberOfTouchesRequired` |

`NSError` and `NSNumber` name deprecated **categories** declared on those types in the header
given, not the types themselves. `?` rows, where the scan could not attribute a declaration, are
in the full table with their `file:line` rather than guessed at here.

---

## D7 — Liquid Glass: native only, never custom

App chrome is 100% standard SwiftUI. `.glassEffect()` is never called to build chrome.
`NSGlassEffectView` is never touched. Content surfaces are deliberately opaque.

Standard components — `NavigationSplitView`, `Inspector`, `.toolbar`, `.sheet` — adopt Liquid Glass
automatically, and **the glass tint responds to the system-level Liquid Glass slider without any
code**. That slider is the decisive argument: a hand-rolled glass surface does not respond to it, so it
looks correct on your machine and wrong for every user who has moved that control.

| Layer | Approach |
| --- | --- |
| Window, sidebar, inspector, toolbar, sheets, menus | 100% standard SwiftUI. Zero glass code |
| Video preview, timeline canvas, waveform, transcript | Custom drawing, deliberately **opaque** |

Glass is for controls floating above content, and a timeline is content. `NavigationSplitView` +
`Inspector` gives the three-pane editor shape with system glass for free.

A video editor's instinct is heavy custom chrome — bespoke timeline header, custom transport bar.
**That instinct forfeits native Liquid Glass and has to be resisted.**

---

## D8 — One render path for preview and export

Preview and export call the same renderer. Same time, same project, same output size produces an
identical frame within a documented tolerance.

This is not an optimisation — it is what makes "what you review is what ships" true. Prove it with
golden-image tests that fail the build, not with care.

The renderer is an `AVVideoCompositing` implementation over Core Image and Metal. Preview drives it
with `CADisplayLink`; export drives it with `AVAssetWriter` frame pacing.

### The transport is `AVVideoComposition`, and this is closed

Preview and export both drive the compositor through an `AVVideoComposition`
built from `AVVideoComposition.Configuration` — a `Sendable` value type carrying
`customVideoCompositorClass`, constructed once and handed to both consumers.
"One render path" is then a fact about a type rather than a rule two call sites
must remember, which is what D8 asks for and what golden-image tests would
otherwise have to establish by hand.

**Not** the sample-buffer renderer path (`AVSampleBufferVideoRenderer` +
`AVSampleBufferRenderSynchronizer`), and not a hand-driven `CADisplayLink`
transport. The ROADMAP's `preview-playback` note says "not `CVDisplayLink` —
deprecated", which rules out one API; it does not mandate hand-driving the clock,
and it is satisfied here.

**Three independent reasons point the same way, and they do not expire
together — which is the part worth writing down.**

| Reason | Kind | Survives the floor moving to 27? |
| --- | --- | --- |
| D8: one compositor drives both, as a type rather than a convention | architectural, and older than all of this | **yes** |
| the floor costs nothing on this path; the renderer path is the only thing that would mean *write it twice* | measurement, today | no — at a 27 floor the renderer path becomes reachable |
| the successor stack is usable at 26.0, so no `if #available` anywhere | measurement, today | no — trivially true at 27 |

**When the floor moves, two of the three stop applying and the first does not.**
Without that written down, a floor bump reads like a trigger to reopen this
decision, and it is not one: it removes two supporting arguments from a
conclusion that never rested on them. Reopening needs a reason against D8, and
none of the measurements above is one.

`AVMutableVideoComposition` — the obvious way to build a composition — has been
deprecated since **26.0**, this project's own floor, so it was never available
here. `Configuration` is the replacement and it is what makes the type-level
version of D8 possible at all.

---

*Rejected:* a fast preview path plus a separate accurate export path. Two renderers means two sets of
bugs and a class of "it looked different when I exported it" reports that cannot be reproduced.

---

## Module map

```
Sources/                         Foundation only, at the repository root
  Geometry/                      NormalizedPoint, NormalizedFrame, geometryRevision
  Graph/                         observations → actions → beats → outputs; origin + review state
  Framing/                       AX targets, named rejections, depth, zoom blocks
  Timeline/                      integer-nanosecond output↔source mapping
  Variants/                      16:9 · 9:16 · 1:1 re-framing, platform profiles
  Project/                       versioned document model, upgrades, atomic save

Sources/Headless/                NOT Foundation-only — the tier `swift test` can link and run
                                 (D1a). Product: SoredemoHeadless. Guard: HeadlessCheck
  CursorArt.swift                the drawn pointer and click ripple, as vector paths
  HeadlessGeometryBridge.swift   the render tier's CoreGraphics exit — the only file here
                                 allowed to name CGRect/CGPoint/CGSize/CGFloat

Soredemo/                        Xcode app target
  Capture/                       ScreenCaptureKit, audio, permissions
  Observation/                   CGEventTap, AXUIElement, the one clock, the log writer
  Render/                        AVVideoCompositing, Core Image, Metal, cursor and effects
  Editor/                        trim, cut, speed, transcript editing
  Launch/                        title scenes, transitions, music, poster
  Agent/                         MCP server, tool surface
  CLI/                           Swift Argument Parser
  UI/                            SwiftUI shell, native Liquid Glass
```

---

## Agentic security

Any text arriving from outside the app — release notes, changelogs, PR titles — is
attacker-controllable in a repository that accepts contributions, and it flows toward a publish action.

```
release notes → evidence → post draft → publish
 (untrusted)     (graph)   (model phrases it)  (public, permanent)
```

Three mitigations, and the design already provides two:

1. **The approval gate.** Per-post human approval bound to a content hash. Injected text cannot publish
   itself. This is why refusing an auto-publish convenience is a security property, not only a
   philosophical one.
2. **The citation requirement.** Text with no valid supporting evidence cannot be approved, so an
   injected instruction cannot manufacture an approvable claim.
3. **Framing, which must be built deliberately.** The prompt treats external text as quoted material to
   summarise, never as instruction to follow — with a test that proves it.

---

## To verify against the SDK

Taken from documentation, not from running code. Two of these change decisions.

- [x] Do `WritableDocument`/`ReadableDocument` handle a **package** (directory with large media
      sidecars), or only single-file documents? *(If single only, D5 needs a hand-written package
      coordinator.)* — **Resolved (design doc F3).** They handle a package; `Source`/`Destination`
      are associated types merely defaulting to `URL`, verified by compilation. It changes the
      decision anyway, for the reason the question did not anticipate: they are SwiftUI protocols
      gated at `macOS 27`, above the macOS 26 floor. D5 therefore gets the hand-written coordinator
      the parenthetical predicted, arriving by a different route.
- [ ] Does `SpeechAnalyzer` accept an `AVAssetReader` audio track for offline transcription of a
      finished recording, or only live input? *(If live only, the transcript work grows.)*
- [ ] Is `SCRecordingOutput` sufficient for the master, or is per-frame `AVAssetWriter` control needed
      for the pointer-free requirement and the one-clock guarantee?
- [ ] Does `AVCaptionRenderer`'s style preview work against a custom compositor, or does it assume
      `AVPlayerLayer`?
- [ ] Is on-device subtitle **translation** exposed to apps, or only inside the system player?
- [ ] Foundation Models Private Cloud Compute free-tier eligibility — Apple's own pages state it two
      different ways.
- [ ] Does standard SwiftUI chrome pick up Liquid Glass correctly in a document-based app with a
      hosted `NSView` content area? That combination is what this project needs and the least-trodden
      path in the guidance.
