# Working agreement — Soredemo

Read this before doing anything. Then `docs/PRODUCT.md`, `docs/FEATURES.md`,
`docs/ARCHITECTURE.md`, and `ROADMAP.md`.

macOS 27 · Apple Silicon · Swift 6.4 strict concurrency · SwiftUI

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

---

## Architecture rules — enforced, not aspirational

`Plugins/ArchitectureCheck` enforces these. If you change a rule, change the plugin in the same commit.

1. **`Packages/SoredemoCore` imports Foundation only** — no AppKit, no ScreenCaptureKit, no
   AVFoundation. The compiler enforces it; do not work around it.

   **This constrains the package, not the app.** The app target uses ScreenCaptureKit, AVFoundation,
   AppKit, and Metal freely — that is where recording, rendering, and UI live.

   ```
   Soredemo.xcodeproj   Capture/ Render/ Editor/ Agent/ UI/   ← platform frameworks
        │  captures, writes an observation log
        ▼
   observation log → evidence (plain data)
        │
        ▼
   Packages/SoredemoCore   Graph/ Framing/ Timeline/ Variants/   ← Foundation only
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
