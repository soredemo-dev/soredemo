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

---

## Architecture rules — enforced, not aspirational

`Plugins/ArchitectureCheck` enforces these. If you change a rule, change the plugin in the same commit.

1. **The `SoredemoCore` package imports Foundation only** — `Package.swift` and `Sources/` sit at the repository root — no AppKit, no ScreenCaptureKit, no
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

2. **No `CGPoint` or `CGRect` in the package's public API.** Capture converts on entry, render converts
   on exit. Nothing in between speaks in pixels.
3. **`NormalizedFrame` carries `geometryRevision`.** Comparing across revisions is a precondition
   failure, never a silent coercion. Displays get reconfigured mid-recording.
4. **One owner for the observation-log → graph join.**
5. **Swift 6.4 strict concurrency, no exceptions.**
6. **App chrome is 100% standard SwiftUI.** Never `.glassEffect()`, never `NSGlassEffectView`. Content
   surfaces are opaque. Custom glass does not respond to the system Liquid Glass slider.

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
