# Working agreement — Soredemo

Read this before doing anything. Then `docs/PRODUCT.md`, `docs/FEATURES.md`,
`docs/ARCHITECTURE.md`, and `ROADMAP.md`.

macOS 26 · Apple Silicon · Swift 6.4 strict concurrency · SwiftUI · SDK 27

---

## What this project is

**You ship a feature; Soredemo carries it to published.** It watches your GitHub releases, proposes a
demo when something user-visible shipped, helps you record it, treats the recording as **evidence**,
and derives everything else from it — the framing, the story beats, the per-platform variants, and the
launch outputs. Then, behind a human approval gate, it publishes.

Every derived value carries its origin and a review state. **Automation proposes; the person decides.**
That is the product thesis and it is also the architecture.

### The publishing rule

> **Soredemo never posts anything without explicit, per-post human approval.** No auto-publish setting,
> no "approve all", no CI bypass. An agent may prepare a post; only a person may send one.
> `publish_post` returns "requires human approval" every time an agent calls it, and `soredemo publish`
> refuses to run non-interactively.

This is the thesis at the one boundary where getting it wrong is public and permanent. It is also the
rule most likely to be eroded by a well-meaning convenience feature. Do not add one.

---

## Method: a skill chain

This project uses the [a skill chain](https://github.com/a skill chain) skill chain:

1. **brainstorming** — before any code. Questions, alternatives, design presented in readable chunks.
2. **using-git-worktrees** — isolated branch, clean test baseline.
3. **writing-plans** — 2–5 minute tasks with exact file paths and verification steps.
4. **subagent-driven-development** — fresh subagent per task, two-stage review.
5. **test-driven-development** — RED-GREEN-REFACTOR. Code written before its test gets deleted.
6. **requesting-code-review** — between tasks. Critical issues block progress.
7. **finishing-a-development-branch** — verify, merge, clean up.

Design documents from `brainstorming` land in `docs/design/`. They are the durable record of *why*.

The SDD ledger that drives `subagent-driven-development` lives under `a skill chain/`, which
`.gitignore` excludes — it does not survive a clone. **At the end of a phase, promote what later
phases need into `docs/design/<date>-phase-N-carried-forward.md`** before the branch merges.
Phase 1's is the worked example: code with no caller yet, rules held by convention rather than
enforcement, and verification that runs only when a person runs it.

---

## Rules

**The completion rule.** A row is not complete while the behaviour its name claims is not observable in
the product. A pure function with no caller does not satisfy a row that claims a product behaviour. If
the caller belongs to a different row, rename the row to what it actually delivers.

**The producer-value rule.** Every generated value carries an origin. An authored override is never
silently replaced by a derived one. Test form: supply a value the producer could not have derived, and
assert the supplied value wins. Write it for every producer.

**Cache invalidation pairing.** Every cache-hit test is paired with an invalidation test. A cache never
proven to invalidate is a correctness bug waiting for a demo.

**Two derivations that disagree must say so.** If the story beats say six steps happened and the camera
produced one move, that is a diagnostic, not silence.

**Read the implementation, not the summary.** Documentation summaries are not a substitute for reading
the code — yours or Apple's.

**When a document is wrong, say so.** If the code disagrees with the design, the code usually wins and
the document gets fixed in the same commit. Do not silently work around a document you think is wrong.

**A correct conclusion does not excuse its reasoning.** Verify the justification as carefully as the
result — including the justification for options you rejected. A decision whose stated reason is
false looks settled, and an audit whose stated reason is false looks discharged; both are worse than
having none, because nothing prompts anyone to re-examine a conclusion that happens to be right.

This has surfaced twice already in Phase 1. `.macOS(.v27)` was retained for "the newer manifest API
surface" long after the only real reason for it had gone, and the stale reason made it look
deliberate. An audit of the checker's string handling concluded the code was safe "because the
force-close only triggers on source that does not compile" — the conclusion held, the reason did
not, and disproving the reason exposed a defect the audit had passed over. Neither was found by
re-reading the conclusion. Both were found by testing the sentence underneath it.

**Every fixture set needs a non-identity value for every transform applied to it.** A fixture
chosen at a transform's identity element cannot test that transform, and the test passes for a
reason unrelated to the code being right. This has happened three times in Phase 1, each time with
a different operation:

| Fixture | Identity of | Consequence |
| --- | --- | --- |
| a vertically centred rect | the Y-flip | the centre-point test passes whether the flip is right or inverted |
| a display at origin `(0,0)` | translation | a mutation making routing ignore the global origin survived |
| `scale: 1` | scaling | 97 green tests while pixels and points were being compared directly |

So: alongside the centred rect, an off-centre one. Alongside `(0,0)`, a non-zero origin. Alongside
`scale: 1`, `scale: 2`.

**Never `git add -A` while an agent is working in the same directory.** This project runs
subagents in the main checkout with no worktree isolation, so `-A` stages whatever they have
written but not yet committed. It has already happened once: a documentation commit silently
absorbed two source files from a task still in flight, and the commit message described only half
of what it contained. Stage explicit paths. The damage is not corruption — the files were correct —
it is that the history stops describing what happened, which is the one thing history is for.

**A measurement that counts something must first assert it counted anything.** `sort -u | wc -l`
returns `1` for empty input, so a probe reporting "1 distinct result" reports the same number
whether the values agreed or the binary failed to build. This is the vacuous pass, one level up
from the code: `Tests/DeterminismTests` carries `#require(!objectFiles.isEmpty, "…would pass
vacuously")` for exactly this reason, and the shell probe that verified it did not. Assert non-empty
input before reporting an aggregate — a wrong API call surfaces on its own, a false green does not.

The same failure has a quieter twin: **a filter that drops rows reports a smaller number, not an
error.** `swift test` writes `1 test` for a one-test target and `N tests` for the rest, so a grep
for `tests` undercounted this suite by three and the wrong figure reached a committed progress
table and a task brief before an implementer measured it independently and disagreed. Neither half
of the pattern announces itself: `wc -l` returns 1 for nothing, and `grep` returns silence for a
row it does not match. Where a number is going into a document, derive it twice.

**Name the artefact, not the concept.** "The app binary" is not a file.
`Soredemo.app/Contents/MacOS/Soredemo` is a 59 KB launcher stub in a Debug build; the app's code is
in `Soredemo.debug.dylib`. `nm` on the stub reports zero `Geometry` symbols before the app's first
`import SoredemoCore` and zero after — the check answers identically whether or not the work
happened. On the dylib the count moves 1191 → 1197, because SwiftPM's static product is force-loaded
whole and the symbols were there when nothing imported them. Both readings are facts about a file;
neither is the fact that was claimed.

This is the "which build" rule one level down: having picked the right tool and the right state, you
can still measure the wrong file. Before quoting a number, say which path produced it — **and which
flags**. The counts above are plain `nm`. The same dylib under `nm -a`, which includes debug
symbols, gives `Minting` 20, `CGGeometryBridge` 22, `ProjectDocument` 234 and a total of 16662
against 5192. Both are correct measurements of different things, and this document and Task 18's
report each quoted one without naming it — the rule unmet by the entry that introduces it.

**The instrument can have state.** Every entry above is about a claim never compared to the thing.
This is the case where you did compare them and the comparison still lied, because the API answered
from its own cache instead of from the world. `URL.resourceValues(forKeys: [.fileResourceIdentifier
Key])`, read twice through the same `URL` binding, returns the identical value across a
`replaceItemAt` that genuinely changed the file's inode — `NSURL` caches resource values per
instance. `FileManager.attributesOfItem(atPath:)[.systemFileNumber]` `stat()`s each call and sees
`130435918 → 130435919` for the same two states.

The failure direction matters: the cached read made a **correct** implementation look broken. A
measurement that reads stale is not the safe kind of wrong. When an assertion is the only thing
standing between you and an unverified mechanism, prove it fails against the mutation *and* passes
against the real code, in a throwaway probe, before you keep it.

**A hand-computed constant in a task brief is a guess until something computes it.** Three times in
Phase 1 an implementer has been handed a wrong number by whoever wrote the brief and has been right
to override it: an FNV-1a vector for `"foobar"`, a test-suite total of 226 that was 229, and a
`droppedBytes` of 12 that was 11. Each was a value the author worked out by hand and wrote down
without running anything. The first came with the instruction *"do not adjust the vectors"* — which,
followed, would have pinned the error into a test and made the code wrong in the direction of the
document.

So: **an implementer who checks a supplied constant against an independent computation and disagrees
is doing the job.** A brief's numbers are requirements about intent, not about arithmetic. If you
are writing the brief, compute the values with a tool and paste the output; if you are implementing
from one, verify before you pin it.

**A compile failure is not a RED.** This project's rule is that an unobserved red light is not a
check. But writing the test before the type means the first failure is always `cannot find 'Foo' in
scope` or an unresolved symbol at link time — which satisfies the rule's words and not its meaning.
A missing symbol proves the test file names the API. It proves nothing about whether any assertion
discriminates correct behaviour from incorrect. The red that counts is **behavioural**: the code
compiles, the tests pass, you break the behaviour, and a test goes red.

**A mutation's red set is evidence at the granularity it is recorded.** A parameterised test that
reddens under a mutation has not been shown to catch it — only that *some* of its cases did. Task 5
recorded `commentAndRawStringOpenersInsideARawIdentifierAreContent["\`a/*b\`"]` as the red set for
disabling the raw-identifier branch, and read it as the branch being covered. It named one fixture
of three; the other two passed with the branch deleted, rescued by unrelated defensive code. The
disconfirming evidence was inside the artefact being used as proof, one level of detail below where
it was read. When a mutation reddens fewer cases than a test has, that gap is the finding.

In this workflow, **mutation checks are the only mechanism that produces a behavioural red.** They
are not a bonus round. A task that shipped without one has tests that were never shown to be able
to fail, whatever colour they were at the start. Task 16 is the evidence: thirteen tests, all
passing on their first run after a compile-level red, three covered by mutations — and the review's
two Important findings landed on exactly the tests the mutations did not reach, one of which passed
identically under the very implementation the requirements forbade.

**Mutation testing is bounded by fixture diversity, and that ceiling is invisible.** Breaking a code
path changes nothing if no fixture ever reaches it — so a mutation check that finds nothing is
evidence about the fixtures as much as about the tests. Four consecutive mutation checks found real
defects in this phase; none of them could have found the `scale: 1` problem, because no fixture had
a scale to get wrong.

**Check the claim against the thing, not against another claim.** Most errors in this project have
had one shape: an assertion about state that was never compared to the state. A grep that collapsed
two build settings and reported the wrong one. `main` recorded as sitting at a commit it had already
moved past. Every `swift build` green while the toolchain the app is opened in could not read the
manifest at all. A green light is evidence for exactly the proposition it tests, and usually that is
narrower than the one being claimed.

**Which build, and from what state.** The question has two axes and this project has been caught on
both. *Which tool* — `swift build` does not build test targets, so a suite can be green in `swift
test` and a package still fail under `xcodebuild`. *From what state* — every green light in Phase 1
was observed on a warm `.build`, and no clean build was run until Task 16, because nothing in the
plan asked for one and there is no CI to run one unasked. The gap was real whether or not it hid a
defect: a verification never performed covers nothing. Every phase ends with `rm -rf` on a scratch
path and `swift build --build-tests` from nothing.

---

## Architecture rules — enforced, not aspirational

**The numbering below is `ARCHITECTURE.md` D6's, which is the only one.** Do not restate it
elsewhere and do not renumber it here; this section is a reader's copy, and D6 is the authority. Two
schemes were in circulation until Task 19, both cited from source — `CGGeometryBridge.swift` had to
carry a parenthetical saying which "rule 5" it meant.

**Each rule says what enforces it, because the mechanisms differ and the difference matters.** The
plugin enforces rules 1, 2 and 4 — those fail `swift build` and `xcodebuild`, on every build. Rules
3 and 5 are tests: they fail `swift test` and **not** an `xcodebuild` of the app, because the Xcode
project has no test target. Rules 6 and 7 are inert; the code they constrain does not exist yet.
If you change a rule, change its mechanism in the same commit — and if it has no mechanism, say so
rather than writing it as though it had one.

1. **The `SoredemoCore` package imports Foundation only** — *plugin; fails both builds* — — `Package.swift` and `Sources/` sit at the repository root — no AppKit, no ScreenCaptureKit, no
   AVFoundation. **The compiler does not enforce this.** It constrains edges *between package
   targets*, and even that degrades to a warning on a warm `.build`; it places no restriction at all
   on system frameworks, so a target with no declared dependencies can import AppKit and build fine.
   `Plugins/ArchitectureCheck` is what makes it a build failure, on every build. Do not work around
   it, and do not detach the plugin from a target to make a build pass.

   **This constrains the package, not the app.** The app target uses ScreenCaptureKit, AVFoundation,
   AppKit, and Metal freely — that is where recording, rendering, and UI live.

   ```
   Soredemo.xcodeproj + Soredemo/   App/ UI/ Capture/ Resources/   ← platform frameworks
        │  captures, writes an observation log
        ▼
   observation log → evidence (plain data)
        │
        ▼
   Sources/   Geometry/ Timeline/ Graph/ Framing/ Variants/ Project/   ← Foundation only
   ```

   The core does not record; it reasons about a recording. Pure logic tests with no screen, no
   permissions, and no display — and derivation stays a deterministic function of its input, which is
   what makes staleness and content-hash approval mean anything.

2. **No `CGRect`, `CGPoint`, `CGSize` or `CGFloat` anywhere in the package** — *plugin; fails both
   builds.* **Anywhere, not just in the public API** — the checker scans every line of every file,
   and the weaker "public API" wording that stood here until Task 19 stated the rule two ways
   looser than the one that fails the build. Capture converts on entry, render converts on exit.
   Nothing in between speaks in pixels. And the compiler is no help: Foundation on Darwin
   re-exports these types, so `let r: CGRect? = nil` compiles clean in a Foundation-only target.
3. **No ambient time or randomness** — *tests; fails `swift test` only.* `Tests/DeterminismTests`
   reads link-time symbols for the package; `Tests/AppSourceTests` scans text for the app, where
   ambient values enter at `Soredemo/Support/Minting.swift` and nowhere else.
4. **No manifest declares a package dependency** — *plugin; fails both builds.* Every
   `Package*.swift`, not just `Package.swift`. This is what keeps rule 1's import allow-list
   complete: with zero dependencies there is no unlisted module to smuggle one in through.
5. **CG types in the app appear only in `Soredemo/Capture/CGGeometryBridge.swift`** — *test; fails
   `swift test` only.* A test rather than a plugin rule because the plugin attaches to SwiftPM
   targets and cannot see the Xcode app target at all.
6. **One owner for the observation-log → graph join** — *inert.* No mechanism; the code does not
   exist. Becomes real in Phase 3.
7. **`applyingProduced` is the sole writer of a `Derived`** — *inert.* `Derived`'s public
   initialiser is what this will have to constrain; see `ARCHITECTURE.md` D4.

**Not in this numbering, deliberately** — these are decisions with letters, not architecture rules
with mechanisms, and giving them numbers here is what produced two colliding schemes:
comparing `NormalizedFrame` across `geometryRevision` is a precondition failure (D3) · Swift 6
strict concurrency, no exceptions (D2) · app chrome is 100% standard SwiftUI, never
`.glassEffect()`, never `NSGlassEffectView`, content surfaces opaque (D7).

---

## Reading other people's code

`../opensource/` holds checkouts of comparable projects. **They are reference for ideas, not a source
of code.** Read them to understand a problem; write the solution yourself.

If you ever do adapt something concrete, put a header on the file naming the source and one accurate
word — `Adapted`, `Rewritten`, or `Copied` — and say so in the commit message. Licences differ and some
are copyleft, so an untracked copy is a problem that surfaces at the worst possible moment. Keeping the
count at zero is the simplest way to never have that conversation.

**Do not read `a source-available project`** — it is source-available for personal non-commercial use only, and
nothing in it is unavailable elsewhere.

---

## Testing

**Swift Testing** (`@Test`, `#expect`, `#require`), not XCTest for new work.

- Pure logic in `SoredemoCore` runs with no screen and no permissions. Keep it that way.
- **Golden-image tests** prove preview and export produce identical frames. They fail the build.
- **Evaluations framework** for anything the model touches — specifically, that a claim with no valid
  supporting evidence cannot reach an approvable state.
- Calibration constants (gate thresholds, merge gaps, depth curves) get tested against **measured
  distributions**, not chosen by intuition. See `ARCHITECTURE.md` D4.
