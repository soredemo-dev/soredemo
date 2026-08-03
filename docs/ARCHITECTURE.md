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

Rules that are not executable stop being true. Three mechanisms, in descending order of strength.

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

Rules 3 and 5 do not fail an `xcodebuild` of the app, because `Soredemo.xcodeproj` has no test
target. Rules 6 and 7 fail nothing at all; they are commitments about code Phase 2 and Phase 3 will
write.

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

## D6b — The platform-premise register: what this app believes about macOS

**Every row is a claim about the operating system that this code depends on and that Apple has not
promised.** Several were measured *because* the header does not say — which is the honest position,
and also the one that expires without warning.

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
| 14 | ~~A pointer-only `.listenOnly` tap needs no Input Monitoring grant; a keyboard tap does~~ **VOID — never measured** | inferred from which step first failed. Every one of those steps ran under `com.cmuxterm.app`, which already held both grants, so no step ever tested the spike's own permission state | — | `CapturePermissions`' degradation model, and what a first-run user can do before granting anything |
| 15 | `mach_timebase_info` is 125/3 on this hardware | measured twice, a day apart | Apple Silicon, 26.5.2 | nothing directly — every conversion goes through `CMTime`/`Nanoseconds`. Kept because it is the constant a hand-rolled conversion would need, and hand-rolling it is the mistake |
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
