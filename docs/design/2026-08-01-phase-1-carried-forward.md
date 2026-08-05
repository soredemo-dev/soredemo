# Phase 1 — what it does not deliver

The SDD ledger that ran Phase 1 was never committed and no longer exists. This file is the part of
it that later phases need, promoted into the repository before the branch merged.

The design document says what Phase 1 decided and why. `AGENTS.md` says how to work. This says what
is missing, unenforced, or true only by convention — the things that will bite someone who assumes
Phase 1 finished them.

---

## Code that exists and has never run

The completion rule in `AGENTS.md` exists because of these. None of them is a defect; each is a
surface built for a caller that arrives in a later phase. They are listed because a ROADMAP row can
read as covering them.

| Symbol | Intended first caller |
| --- | --- |
| `NormalizationContext` (all conversion methods) | Phase 2 `input-observation` / `ax-observation` |
| `ProjectDocument.addMedia`, `.unreferencedMedia`, `.compactMedia`, `MediaError` | Phase 2 recording path |
| `Minting.now()` | Phase 2, whenever an observation first needs a wall-clock stamp |
| `CGGeometryBridge` (all four functions) | Phase 2 `input-observation` |
| `ReverseIndex` | Phase 4 `text-based-editing` |

`Minting.newIdentifier()` is reachable only through the dead `addMedia`, so **two of the three
functions in the file that exists to justify the package's no-ambient-values rule are unexercised.**
Only `digest(of:)` is live.

## Rules that are not enforced by anything

1. **`CheckerLexer` is outside architecture rules 1 and 3.** It cannot carry `plugins: archCheck` —
   the plugin depends on `architecture-checker`, which depends on `CheckerLexer`, and SwiftPM
   refuses the cycle (verified by attaching it). `Tests/DeterminismTests` derives its module list
   from plugin-attached targets, so the exclusion follows. Two guards remain:
   `everyLibraryTargetUsesTheCheckerPluginInTheResolvedManifest` fails on any regular target outside
   the exemption set, and the cycle makes attachment impossible rather than merely undone. **What is
   unguarded is the exemption list itself** — one edit drops a target out of both rules silently.

2. **`Derived`'s public initialiser, not `applyingProduced`, is what architecture rule 7 must
   constrain.** `Sources/Graph/Derived.swift` exposes
   `public init(value:origin:review: = .pending)`, so a producer can write
   `Derived(value: v, origin: .generated(d), review: .approved)` in one call and never touch the
   guarded path. Rule 7 is currently inert and held by convention. Phase 3's `framing-targets` is
   the first row that writes producers, and it is where this has to be decided.

3. **File coordination is unresolved, not decided.** `super.writeSafely` performs an
   `NSFileCoordinator` coordinated write; the override drops it along with the whole-package copy.
   Atomicity was relocated deliberately (D-P3) and durability declined deliberately
   (no `F_FULLFSYNC`); this third thing was neither. It bites first when a project package sits in
   a synced folder, and again in Phase 2 if anything writes concurrently with the document.

4. **`ArchitectureChecker.bannedCGTypes` is mirrored, not shared,** between the checker and
   `Tests/AppSourceTests`. Nothing enforces that the two lists agree. Sharing was rejected because
   the only target both sides can reach is `CheckerLexer`, which is the one target outside plugin
   enforcement — a policy list would then live in the least-guarded place in the package. A fifth
   banned type means editing both.

5. **The app-side determinism scan is a text scan, and the design doc's F7 rejects text scanning.**
   It was adopted anyway because the app target has no object files a package test can reach. Its
   three known misses are in the gap table; the one worth repeating is
   `typealias Moment = Date` followed by `Moment()`, because unlike the other two it is not
   deliberate-authorship-only.

## Defaults this phase depended on and never decided

Distinct from the section above. Those are rules stated and not enforced; this is a setting nobody
ever stated an opinion about. **This is the third instance of one class of problem, and reading it
beside the other two is the point:**

| | The gap |
| --- | --- |
| `applyingProduced`'s doc comments | claimed to be "the only way" and "the enforced write path" while `init` is public with `review` defaulted |
| architecture rule 7 | written against `applyingProduced`, when what it must constrain is `Derived`'s public initialiser |
| `ENABLE_APP_SANDBOX = YES` | reads as an architectural decision; no document discusses it and no task chose it |

Each is a distance between what the documents say is true and what is actually enforced or chosen.

**`ENABLE_APP_SANDBOX = YES`, with `com.apple.security.files.user-selected.read-only` as the only
file entitlement.** Verified against the signed product with `codesign -d --entitlements`. Precisely:
it is written explicitly into both configurations of `project.pbxproj` — Xcode puts it there when a
macOS app target is created — so it is not a fallback default, it is a line nobody read.

**Resolved before Phase 2 began: the sandbox is off.** The question that settled it was not "sandbox
or not" but *"without `ax-observation`, is this still the product?"*, and the answer follows from
`PRODUCT.md`'s own thesis — one recording is evidence, everything else is derived from it, and every
derived value is traceable. Semantic evidence is what makes that sentence mean anything.

Measured after flipping it, not assumed: `ENABLE_APP_SANDBOX = NO` in both configurations,
`plutil -lint` clean, `xcodebuild` exit 0, `com.apple.security.app-sandbox` gone from the signed
entitlements, hardened runtime still on (`flags=0x10000(runtime)` — notarization needs it), the app
still launches and opens a `.soredemo` package, and 290 tests unchanged.

Two consequences that made it necessary:

1. **`ax-observation` cannot work under App Sandbox.** The sandbox blocks the Accessibility API
   against other processes — a layer *in front of* TCC, so granting Accessibility does not help.
   `input-observation`'s `CGEvent.tapCreate` is restricted for the same reason. ScreenCaptureKit is
   unaffected.
2. **`read-only` cannot save a project.** Everything Phase 1 built in `Sources/Project` —
   `ProjectPackageIO.save`, the atomic manifest replace, write-once sidecars — would be denied at a
   user-selected location. Moot now the sandbox is off; `files.user-selected.read-only` survives in
   the entitlements as an inert leftover and should be removed when the signing story is revisited.

### How load-bearing, stated honestly

A dependency-closure count over `ROADMAP.md` says cutting `ax-observation` costs 40 of 69 rows and
cutting `input-observation` as well costs one more. **Do not use either number.** Both are artefacts
of `observation-log` being a join node, and a join node distorts in both directions at once: it
*overstates* a necessary dependency, because everything downstream of the join inherits it, and it
*understates* a joint dependency, because a second input's marginal contribution is absorbed by the
first. The 40 was discounted on the first ground and the 1 was then accepted without applying the
second — the same bias, read once and missed once.

**The honest number is three**, and it is enough:

1. `written-steps` — semantic output. "Click the Save button", not "click at (412, 88)".
2. `framing-targets` — what the camera should aim at.
3. The thesis itself — a derived value traceable to evidence. A coordinate is weak evidence for a
   claim about what a person did.

If the product's argument is that derived values are traceable to evidence, then losing the ability
to produce semantic evidence is losing the argument, however many rows it touches.

**And the two rows are one mechanism, not two.** `CGEvent.tapCreate` says *when and where* a click
happened; `AXUIElementCopyElementAtPosition` says *what was there*. In "click the Save button" the
verb comes from `input-observation` and the object from `ax-observation`; neither produces that
sentence alone. So `input-observation` is not the cheap one to defer — it is half of a pair, and
what Phase 2 must verify is **the timing accuracy of the pairing**: the latency between the click
event and the AX tree snapshot decides whether the hit-test returns the element that was under the
cursor at click time. That goes wrong during UI animation, which is exactly when people click
buttons.

### Work that App Sandbox was absorbing, now ours

None of this is in the 69 rows. It arrives with direct distribution and belongs in a plan before
Phase 5, not discovered during it.

- **Auto-update** — Sparkle or equivalent. The App Store is no longer delivering updates.
- **Notarization requires hardened runtime**, which is already on. It does not conflict with
  Accessibility or Input Monitoring, but it blocks JIT, `DYLD_*` environment variables, and loading
  unsigned dylibs. Audit dependencies for anything needing an exception entitlement before the
  first notarized build, not after a rejection.
- **Signing and bundle-ID stability moves from advice to requirement.** With no App Store–managed
  identity, every TCC grant is bound to this signing identity alone; change it and the Accessibility
  grant silently stops applying, with the row in System Settings still looking correct.
- **Crash reporting, and licensing or payment** if the product is ever charged for.

**Phase 1 never exercised any of this**, and the reason is specific: `scripts/cross-boundary-digest-
probe.swift` is compiled by `swiftc` into a bare executable, so it runs **outside the sandbox** and
**without a bundle identity**. It validates logic that the real app may not be permitted to perform.

That second divergence got worse recently. Reported behaviour on **macOS 26.1**: a bare executable
no longer appears in the Screen Recording list in System Settings at all — it still prompts, and
still captures once granted, but never appears, and adding it manually with "+" does not work. The
same was reported for Full Disk Access, working on 26.0.1 and broken on 26.1. *(Researched by the
project owner; not independently verified here. Verify before designing against it.)*

So a probe binary differs from the product in **two** layers, not one.

## TCC behaviour Phase 2 must design around

*(Researched by the project owner. Marked here because it shapes the development loop, and because
TCC behaviour already changed once inside a point release — 26.0.1 to 26.1. Record the OS version
beside every permission observation; do not assume 26 → 27 is stable.)*

- **Screen Recording re-confirms monthly.** Introduced in macOS 15, weekly during beta, reduced to
  monthly after pushback; the per-reboot re-authorisation was dropped at the same time. Neither the
  user nor the developer can disable it — only enterprise MDM can pre-authorise. The development
  loop must assume one unavoidable interruption per month.
- **The monthly approval state is keyed on the executable's path**, in a plist whose value is a
  date. A third reason to verify against a build at a fixed installed path rather than DerivedData.
- **Toggling the switch in System Settings does not take effect until the app fully quits and
  relaunches.**
- **A revoked Screen Recording grant does not produce an error. It produces black frames.** This is
  a failure mode `capture-*` must detect actively. A capture test that only checks "frames arrived"
  passes on a fully black recording.
- **Accessibility has no periodic re-confirmation.** Once granted it persists until revoked by hand
  — or until the app's bundle identifier changes, at which point the grant silently stops applying.
  The signing identity here is stable (`Apple Development`, team `GJRVCWA2U3`, bundle
  `video.soredemo.Soredemo`, verified with `codesign -dvv`), which is the good case; keep it that
  way.
- **macOS 27 ships during Phase 2.** Announced at WWDC on 2026-06-08, first public beta 2026-07-13,
  expected release September 2026; Apple Silicon only. Phase 2's permission work will straddle it.

## Verification that runs only when someone runs it

**The cross-boundary SHA-256 vector is hand-run.** `scripts/run-cross-boundary-probe.sh` checks that
`Minting.digest(of:)` produces the pinned digest for the pinned canonical bytes. The app has no test
target, so nothing runs it on a schedule. The **package** half — pinned bytes to pinned digest,
compared never computed — is a standing test. The app half is not.

Phase 8's `approval-gate` rests on the app half. Either give the app a test bundle or accept that
drift in CryptoKit, in the encoding, or in the bridge is caught only by a person.

**Two in-process blind spots, both recorded where they occur:** the cross-revision precondition in
`NormalizedFrame` cannot be covered in process — disabling the guard leaves the whole suite green,
because Swift Testing has no crash expectation — so it is verified out of process. And
`ReverseIndex` has no self-triggering staleness detection: `dependents(of:)` keys on
`EvidenceRef.id`, and whoever owns the observation-log-to-graph join must call
`invalidate()`/`rebuild(from:)` at the right moments. The type guarantees only the interval between.

---

## What the phase learned about its own verification

`AGENTS.md`'s Rules section is the durable form of this and should be read first. Two things about
its shape are worth stating once here, because they are not visible from any single rule.

**Six times, a constant or a measurement supplied by the task author was wrong and the implementer
was right to override it** — an FNV-1a vector, a suite total, a `droppedBytes` count, a symbol
count read off the wrong binary, a claim about which toolchain refuses a manifest, and a claim about
what `DeterminismTests` derives its module list from. One of them shipped with the instruction *"do
not adjust the vectors"*. A brief's numbers are requirements about intent, not about arithmetic.

**Mutation checks were the only mechanism that produced a behavioural red, and passing four of them
did not mean the mechanism was tested.** Task 17 ran four mutations, all genuinely red, while the
atomic-replace mechanism they were meant to protect stayed unverified — none of them aimed at it. A
plain `Data.write(to:)` left all fifteen tests green. Task 18 then found the next layer: a mutation
that *does* aim at the mechanism can still be intercepted before reaching the assertion. Aim at the
mechanism, and check that the red light is coming from the assertion you intended to exercise.
