# Kickoff prompts

Copy the block for the stage you are at.

Repo: `~/Documents/Soredemo/soredemo-main` · Reference: `../opensource/` (read-only)

**Done:** Prompt 0 (orient — found six contradictions and three wrong judgements, all fixed) ·
Prompt 1 (Phase 0 — see `docs/findings/phase0.md`).

---

## Prompt 1.5 — Phase 0.5: validate the hypothesis

> We are doing Phase 0.5 from `ROADMAP.md`. **This is disposable. None of it survives into the
> product, and you should write it that way** — fastest language, no tests, no architecture, no
> a skill chain design cycle.
>
> The claim being tested is not technical: *if you remove the friction, will teams actually record a
> demo per release?* Everything else assumes it is true and nothing has tested it. Phase 0 made this
> more urgent — the technical differentiator turned out to be designed rather than built, so the market
> assumption now carries more weight.
>
> Five rows: `spike-poller`, `spike-proposal`, `spike-manual-pack`, `spike-prepare`, `spike-findings`.
>
> The important one is `spike-manual-pack`: record and edit demos **by hand** for 5–10 real releases
> from repositories that are not mine. No Soredemo, no automation. The point is to learn what the
> output actually has to look like and how long it genuinely takes — the two-to-four-hour figure in
> `docs/PRODUCT.md` is an assertion, not a measurement.
>
> Write findings to `docs/findings/validation.md`: did anyone record when the card appeared, what did
> they say, what stopped them, and what is the real baseline release coverage.
>
> Two weeks, hard stop. If you find yourself improving the poller, stop — that is this phase's failure
> mode.

---

## Prompt 2 — Phase 1: foundation (first real a skill chain cycle)

> We are building Phase 1 from `ROADMAP.md`. Use the full a skill chain workflow: brainstorm the design
> with me first, then worktree, then plan, then subagent-driven TDD.
>
> Six rows in dependency order: `repo-skeleton`, `architecture-plugin`, `provenance-ledger`,
> `geometry`, `release-graph`, `project-schema`.
>
> Constraints already decided — treat as given, and push back only on a real contradiction rather than
> a preference:
>
> - `platforms: [.macOS(.v27)]`, Swift 6.4, strict concurrency, no availability branches (D2)
> - SwiftPM packages for pure logic, Xcode app target consuming them (D1)
> - `SoredemoCore` imports Foundation only — no AppKit, no ScreenCaptureKit, no AVFoundation. The
>   compiler is the enforcement mechanism. **This constrains the package, not the app** (D6)
> - No `CGPoint`/`CGRect` in a pure package's public API (D3)
> - `NormalizedPoint` is 0–1 bottom-left; `NormalizedFrame` carries `geometryRevision`, and comparing
>   across revisions is a precondition failure (D3)
> - App chrome is 100% standard SwiftUI. Never `.glassEffect()`, never `NSGlassEffectView` (D7)
>
> **The port specification is the old Rust tests, not the old Rust code.** For `geometry`,
> `release-graph`, and `project-schema`, read the crates at
> `../opensource/soredemo-main-old-rust+tauri/crates/` and translate their tests first. A ported module
> is correct when its translated tests pass, not when it compiles.
>
> Two mandatory test forms, and they are the ones most likely to be skipped:
> - **Producer-value rule** — supply a value the producer could not have derived; assert it wins.
> - **Cache pairing** — every cache-hit test paired with an invalidation test.
>
> Read `docs/reference/behaviour/release-graph.md` and `project-schema.md` before designing those two.
>
> Start with brainstorming. Ask me what you need to.

---

## Prompt 3 — SDK verification spike (run alongside Phase 1)

> `docs/ARCHITECTURE.md` § Unverified lists seven things taken from Apple's WWDC26 documentation but
> never checked against the SDK. Two change decisions if false. Verify on macOS 27 with Xcode 27 and
> write results back into that section.
>
> The two that matter most:
> 1. Do `WritableDocument`/`ReadableDocument` handle a **package** — a directory with large media
>    sidecars — or only single-file documents? *(If single only, D5 reverts to porting a Swift recorder's
>    `PackageManager`.)*
> 2. Does `SpeechAnalyzer` accept an `AVAssetReader` audio track for offline transcription of a
>    finished recording, or only live input? *(If live only, the `transcript` row grows substantially.)*
>
> Build the smallest thing that answers each. Do not build the app.

---

## Standing instructions — paste into `CLAUDE.md`

> **Provenance.** Every file derived from `../opensource/*` carries a header naming the source file and
> one word — `Adapted`, `Rewritten`, or `Copied` — accurately. Update `docs/PROVENANCE.md` in the same
> commit. Copying from a native editor Pro (GPL-3.0) is allowed during development; the header is what makes
> the exposure enumerable before shipping. Never read `a source-available project`.
>
> **The completion rule.** A row is not complete while the behaviour its name claims is not observable
> in the product. Phase 0 found this violation in the reference implementation itself — `FramingDecision`
> is computed and read by nothing. Take it seriously.
>
> **Origin discipline.** `ROADMAP.md` marks every row **[P]** ported, **[S]** inherited from a Swift recorder,
> or **[N]** new. If a row marked [P] turns out to have never been implemented, say so and re-mark it.
> That is what happened to `semantic-director`.
>
> **Read the implementation, not the summary.**
>
> **`../opensource/` is read-only.** Never modify `soredemo-main-old-rust+tauri` — it is the only
> executable specification of the behaviour being moved.
>
> **When a document is wrong, say so.** If the code disagrees with the design, the code usually wins and
> the document gets fixed in the same commit. Do not silently work around a document you think is wrong.
