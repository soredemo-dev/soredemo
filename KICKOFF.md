# Kickoff prompts

Copy the block for the stage you are at.

Repo: `~/Documents/Soredemo/soredemo-main`

## Setup, once

Toolchain setup is in `docs/TOOLCHAIN.md`. There is no plugin to install: the a skill chain
chain this file's prompts assume was dropped after Phase 3A — see `AGENTS.md` § Method.

---

## Phase 0 — Validate the hypothesis (optional, two weeks)

> We are doing Phase 0 from `ROADMAP.md`. **This is disposable. None of it survives into the product,
> and you should write it that way** — fastest language, no tests, no architecture, no a skill chain
> design cycle.
>
> The claim being tested is not technical: *if you remove the friction, will teams actually record a
> demo per release?* Everything else in the plan assumes it is true and nothing has tested it.
>
> Five rows: `spike-poller`, `spike-proposal`, `spike-manual-pack`, `spike-prepare`, `spike-findings`.
>
> The important one is `spike-manual-pack`: record and edit demos **by hand** for 5–10 real releases
> from repositories that are not mine. No automation. The point is to learn what the output actually
> has to look like and how long it genuinely takes — the two-to-four-hour figure in `docs/PRODUCT.md`
> is an assertion, not a measurement.
>
> Write findings to `docs/findings/validation.md`.
>
> Two weeks, hard stop. If you find yourself improving the poller, stop — that is this phase's failure
> mode. Delete it afterwards.

---

## Phase 1 — Foundation (the first real build)

> **⚠ This block is out of date and Phase 1 is already under way.** It is kept as the historical
> kickoff. Do not paste it to restart Phase 1 — read `docs/design/2026-08-01-phase-1-foundation-design.md`
> instead, which supersedes it.
>
> Corrections since it was written, all decided deliberately: the floor is **macOS 26.0**, not 27;
> the package sits at the **repository root**, not under `Packages/`; `project-format` uses a
> hand-written **`NSDocument`** coordinator, because `ReadableDocument`/`WritableDocument` are
> SwiftUI types requiring macOS 27; and there is **no git worktree**.
>
> The "Constraints already decided … Treat these as given" framing below is what makes this file
> dangerous when stale: an agent handed it will faithfully reinstate a decision that was reversed.

> Read `AGENTS.md`, `docs/ARCHITECTURE.md`, `docs/FEATURES.md`, and `ROADMAP.md` in full before
> planning anything. Read them properly — do not skim, do not summarise from headings.
>
> We are building **Phase 1 — Foundation** from `ROADMAP.md`. Five rows, in dependency order:
>
> 1. `repo-skeleton` — Xcode app target + `SoredemoCore` SwiftPM package, `.macOS(.v26)`, Swift 6.4
>    strict concurrency, builds and runs empty
> 2. `architecture-plugin` — `Plugins/ArchitectureCheck` enforcing pure-package imports and no
>    `CGPoint`/`CGRect` in the package's public API
> 3. `geometry` — `NormalizedPoint` (0–1, bottom-left origin), `NormalizedFrame` carrying
>    `geometryRevision`, all conversion in one place, cross-revision comparison is a precondition failure
> 4. `project-format` — versioned `Codable` document, atomic save, relative paths only, explicit
>    upgrade path
> 5. `derivation-graph` — observations → actions → beats → outputs, where every derived value carries an
>    origin (`generated` / `authored`) and a review state
>
> **Use the full a skill chain workflow.** Brainstorm the design with me first, then worktree, then plan,
> then subagent-driven TDD. Do not skip brainstorming — several of these have real design choices in
> them and I want to make them deliberately.
>
> ### Constraints already decided
>
> These are in `docs/ARCHITECTURE.md`. Treat them as given. Push back only if you find a genuine
> contradiction, not a preference:
>
> - **D1** — pure logic in `Packages/SoredemoCore`, app in an Xcode target that consumes it
> - **D2** — `platforms: [.macOS(.v26)]`, Swift 6.4, strict concurrency, no availability branches
> - **D3** — `NormalizedPoint` is 0–1 bottom-left, matching CoreGraphics so the render path never
>   flips. No raw `CGPoint`/`CGRect` crosses a module boundary
> - **D5** — the project is a document, not a database. Not SwiftData
> - **D6** — `SoredemoCore` imports Foundation only. No AppKit, no ScreenCaptureKit, no AVFoundation.
>   **This constrains the package, not the app** — the app target uses platform frameworks freely
> - **D7** — app chrome is 100% standard SwiftUI. Never `.glassEffect()`, never `NSGlassEffectView`
>
> ### What "done" means for each row
>
> Per the completion rule in `AGENTS.md`: a row is not complete while the behaviour its name claims is
> not observable. Concretely —
>
> - `repo-skeleton` is done when `xcodebuild` succeeds and the app launches to an empty window
> - `architecture-plugin` is done when adding `import AppKit` to `SoredemoCore` **fails the build**, and
>   there is a test proving it
> - `geometry` is done when comparing two `NormalizedFrame`s with different `geometryRevision` traps,
>   with a test
> - `project-format` is done when a v1 document round-trips, and a synthetic v0 document upgrades
> - `derivation-graph` is done when the producer-value rule holds under test
>
> ### Two test forms are mandatory
>
> These are the ones most likely to be skipped, and they are the ones that matter:
>
> - **Producer-value rule** — supply a value the producer could not have derived, and assert the
>   supplied value wins. Write it for every producer.
> - **Cache pairing** — every cache-hit test is paired with an invalidation test.
>
> Use **Swift Testing** (`@Test`, `#expect`), not XCTest.
>
> ### Things I want you to decide with me, not for me
>
> - Whether `SoredemoCore` is one package or several
> - How `geometryRevision` is allocated and stored
> - The document format: single file with embedded media references, or a package directory
> - How the derivation graph represents "this value came from that observation" — the shape of that
>   citation is load-bearing later, for `explain_framing` and the review UI
>
> ### One thing to check before designing `project-format`
>
> `docs/ARCHITECTURE.md` § To verify lists an open question: do `WritableDocument`/`ReadableDocument`
> handle a **package** — a directory with large media sidecars — or only single-file documents? Build
> the smallest thing that answers it before committing to a design. If the answer is single-file only,
> `project-format` needs a hand-written package coordinator and that changes the row.
>
> Start with brainstorming. Ask me what you need to.

---

## Phase 2 — Record

> **⚠ Historical. Phase 2 shipped.** Kept as the record of what was asked for; the workflow line
> at the end of this block no longer applies — see `AGENTS.md` § Method.
>
> Read `AGENTS.md`, `docs/FEATURES.md` § Pillar 1, and `ROADMAP.md` Phase 2.
>
> We are building the recorder. Fourteen rows, ending at a build that records a demo, plays it back,
> and exports an MP4. **This phase alone is a shippable free recorder** — treat it that way.
>
> Two API decisions to make early, both from `docs/FEATURES.md`:
>
> 1. **`SCContentSharingPicker`** (macOS 14+) gives the system source picker, the Video menu-bar item,
>    and Presenter Overlay for free, and hands back a ready-made `SCContentFilter`. Use it. Do not build
>    a custom picker first.
> 2. **`SCRecordingOutput`** (macOS 15+) records a stream straight to a file with no manual
>    `AVAssetWriter`. Evaluate whether it satisfies the pointer-free master and the one-clock guarantee
>    before writing a frame-level path. If it does, a lot of this phase disappears.
>
> The non-negotiables:
> - **`showsCursor = false`.** The cursor is drawn at composite time, never baked in
> - **One clock.** `CMClock.hostTimeClock` taken once at session start; every timestamp derived from it.
>   A sample before the origin or moving backwards is an error, not something to clamp
> - **Keyboard evidence is filtered.** Approved shortcuts recorded as identifiers; ordinary typing never
>   recorded; secure input suppresses capture entirely. Write the test that proves typing is not stored
> - **`CADisplayLink`**, not `CVDisplayLink` — the latter is deprecated
>
> Full a skill chain workflow. Brainstorm first.

---

## Standing instructions — paste into `CLAUDE.md`

> **The completion rule.** A row is not complete while the behaviour its name claims is not observable
> in the product. A pure function with no caller does not satisfy a row that claims a product behaviour.
>
> **The producer-value rule.** An authored override always wins over a derived value and is never
> silently replaced. Test it by supplying a value the producer could not have derived.
>
> **Two derivations that disagree must say so.** If the story beats say six steps happened and the
> camera produced one move, that is a diagnostic, not silence.
>
> **Calibration constants get measured, not guessed.** Gate thresholds, merge gaps, and depth curves are
> fitted to real distributions. See `docs/ARCHITECTURE.md` D4 for the three ways this goes wrong.
>
> **`../opensource/` is reference for ideas, not a source of code.** Read to understand a problem; write
> the solution yourself. Never read `a source-available project`.
>
> **When a document is wrong, say so.** If the code disagrees with the design, the code usually wins and
> the document gets fixed in the same commit. Do not silently work around a document you think is wrong.
