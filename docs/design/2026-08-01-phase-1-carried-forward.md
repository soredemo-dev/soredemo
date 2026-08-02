# Phase 1 — what it does not deliver

The SDD ledger that ran Phase 1 lives under `a skill chain/`, which `.gitignore` excludes. It does
not survive a clone. This file is the part of it that later phases need, promoted into the
repository before the branch merged.

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

Distinct from the section above. Those are rules stated and not enforced; these are settings that
were never stated at all — they are Xcode's defaults for a new macOS app target, and they survived
into a shipped architecture because nothing ever asked.

**`ENABLE_APP_SANDBOX = YES`, with `com.apple.security.files.user-selected.read-only` as the only
file entitlement.** Verified against the signed product with `codesign -d --entitlements`. It looks
like a decision. It is not one; no document in this repository discusses it, and no task chose it.

Two consequences reach Phase 2 on its first day:

1. **`ax-observation` cannot work under App Sandbox.** The sandbox blocks the Accessibility API
   against other processes — this is a layer *in front of* TCC, so granting Accessibility does not
   help. `input-observation`'s `CGEvent.tapCreate` is restricted for the same reason.
   ScreenCaptureKit is unaffected.
2. **`read-only` cannot save a project.** Everything Phase 1 built in `Sources/Project` —
   `ProjectPackageIO.save`, the atomic manifest replace, write-once sidecars — is denied at a
   user-selected location. `files.user-selected.read-write` is the floor.

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
