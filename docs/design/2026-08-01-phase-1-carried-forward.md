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
