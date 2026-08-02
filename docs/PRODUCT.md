# Product

*Why this product exists, who buys it, and what it deliberately is not.*

Features and the frameworks behind them are in `FEATURES.md`.

---

## Positioning

**Every team ships. Almost nobody sees what they shipped.**

Soredemo turns each release into a published demo — detected from GitHub, recorded once, derived into
video and launch copy, reviewed by a person, and posted.

### The thesis, in one sentence

> One recording is treated as **evidence**, everything else is **derived** from it, every derived value
> is **traceable and reviewable**, and nothing goes out without a person approving it.

Most features here exist to make derivation trustworthy, not to make editing powerful. That is why the
list looks different from a screen recorder's.

### The metric

> **Release coverage — the share of a team's releases that resulted in a published demo.**

Baseline is 5–15%. The job is 60%+. This is also the test for whether a feature is worth building:
*does this raise release coverage, or is it craft for its own sake?* Applied honestly it deletes a lot
of work — see § Scope.

Secondary: **time from tag to published post.** Hours today, minutes as the target.

### Why now

Coding agents made shipping three to five times faster. Marketing did not. The gap widens fastest at
exactly the teams most likely to buy. Meanwhile the tooling to close it finally exists: MCP lets an
agent drive an editor, and on-device speech plus Metal export mean the pipeline runs locally at zero
cost per video.

---

## The loop

```
 1. Watch     GitHub release / tag / merged PRs / CHANGELOG, polled locally
 2. Propose   "v0.4.0 shipped 3 user-visible changes. Record a demo?"  ← dismissable
 3. Record    screen + audio + input evidence, one clock
 4. Derive    evidence → graph → framing → storyboard → variants
 5. Review    every value shows origin, review state, and why
 6. Pack      mp4 · gif · poster · steps · launch post
 7. Approve   ← hard human gate, per platform, bound to content hash
 8. Publish   X · Threads · Instagram
```

### The architectural point

**A GitHub release is evidence, not a trigger.** Modelling it that way makes four things free: the post
cites real PR titles rather than guessing from the video; staleness works through the mechanism that
already handles re-recording; `isCurrent(for:)` already exists; and the producer-value rule extends
unchanged, so a hand-written post is never silently regenerated.

### The publishing rule

> **Soredemo never posts anything without explicit, per-post human approval.** No auto-publish setting,
> no "approve all", no CI bypass. An agent may prepare a post; only a person may send one.

Three reasons, in order of weight: it is the thesis at its highest-stakes boundary; it protects the
user's account from being flagged; and it protects the user from a draft that is wrong about what
shipped. Wrong in a local file is a typo; wrong on X is a correction thread.

### Publishing reality

No X, Threads, or Instagram MCP connector exists. All of it is built here.

| Platform | Auth | Cost | Media |
| --- | --- | --- | --- |
| **Threads** | Tech Provider Verification | Free | MP4/MOV ≤5 min, 250 posts/24h |
| **Instagram** | Business account + Page + Professional + **Meta app review (weeks)** | Free | Reels **9:16, 5–90 s** |
| **X** | Developer account | **$0.015/post — $0.20 with a link** | — |

X's link surcharge is a 13× multiplier on exactly the post this generates. Show the cost before
approval and cap the spend.

Instagram's 9:16 + 5–90 s is an *input* to the variant compiler, not a post-processing detail. The
compiler should say the demo is too long rather than exporting something that will not appear in Reels.

**Ship publishing in two tiers.** *Tier 1 — Prepare:* render the right variant, stage text and media,
open the platform's web composer. No API, no OAuth, no cost, works day one everywhere, and it is the
most honest version of the approval gate — the user literally presses post. *Tier 2 — Publish:* Threads
first (free), Instagram second (start the Meta review early), X last (needs cost display).

---

## Scope — what is deliberately not built

Saying no is part of the definition.

| Not built | Why |
| --- | --- |
| **Full NLE** — ripple, snapping, multicam, clip transitions | Wrong product. A demo needs four operations |
| **Camera / webcam overlay** | Not what a product demo needs, and it doubles the capture surface |
| **Region capture** | Display and window cover the case. Adds a selection UI and a geometry edge case for little gain |
| **Colour grading, LUTs** | This is not a colourist's tool |
| **Generative video, images, audio** | Contradicts the thesis. Everything is derived from what happened |
| **Auto-publishing** | Never. The approval gate is the thesis at its highest-stakes boundary |
| **Cloud rendering, hosted projects** | Local by default is a product value |
| **FCPXML export, device frames** | Escape hatches. Neither moves release coverage |
| **Windows, Intel, macOS < 27** | See `ARCHITECTURE.md` D2 |
| **Keystroke logging** | Ordinary typing is never recorded. Only approved shortcuts |


## Feature set

See **`FEATURES.md`** — four pillars (record, edit, launch video, CLI + agent) with the Apple
framework behind each piece.

## Distribution

> **The premise under this section changed in Phase 1 and the conclusion has not been re-examined.**
> The floor is now **macOS 26.0**, not 27 — see the design doc's D2. Both arguments below rest on
> "requires the newest macOS", which is no longer what the product requires: macOS 26 shipped
> earlier and the addressable install base is correspondingly larger.
>
> This is left standing rather than rewritten because the conclusion — hand-sold, slow at the start —
> may well survive the change on its own merits, and that is a go-to-market decision, not a
> documentation fix. What is not honest is the section reading as settled. Revisit it before the
> first release, or record that it was revisited and the answer held.
>
> Kept deliberately: the `macOS 27` decision is also cited across this repository as the worked
> example of a justification that outlived its reason. Deleting it would delete the lesson. The
> distinction is between citing the decision as a record and using it as a live premise — these two
> paragraphs do the second.

An earlier version called the free recorder "the distribution channel the paid product sells into."
**That was incoherent with the macOS 27 floor** (the floor in force when this was written). A free recorder requiring the newest macOS on Apple
Silicon cannot be a mass-market channel — ScreenKite runs on macOS 14/15 including Intel — and
company-managed Macs lag OS releases hardest, which is exactly buyer #1.

The floor is kept. **The free tier's role changes: a conversion surface, not a reach surface.** Narrow,
high-intent. Optimise it for convincing, not counting.

The actual channels have to be built deliberately:

1. **Dogfooding in public — strongest and nearly free.** Soredemo's output *is* its advertisement.
   Every Soredemo release shipped with a Soredemo-made demo is a working proof, published where the
   buyer reads. Starts the day the free recorder lands.
2. **Direct outreach.** DevRel at developer-tool companies is a few hundred publicly identifiable
   people. For the first fifty customers, hand-sold beats any funnel.
3. **Comparison content.** ScreenKite's own playbook. Soredemo's answer is different: not "which
   recorder" but "which of these gets the video *published*".
4. **Open-source maintainers.** Credibility and word of mouth, not revenue.

**Cost, stated plainly:** go-to-market is hand-sold and slow at the start. For a solo founder that is
arguably the right shape — fifty customers who talk to you teach more than fifty thousand downloads who
do not — but it is a real cost of the macOS 27 decision.

---

## Who buys

**1. DevRel at developer-tool companies.** Budget exists, release coverage is literally their KPI.
Smallest sales cycle, clearest pain. Start here.

**2. Seed / Series A SaaS with no marketing team.** Engineers are the ones posting. Buys to remove a
chore, which means it must be nearly zero-effort or it churns.

**3. Open-source maintainers with sponsorship.** Highest enthusiasm, lowest willingness to pay.

**Not the customer:** indie developers who want a nicer screen recorder.

---

## Against the competition

| | Soredemo | ScreenKite | a Rust recorder | a native editor | Screen Studio |
| --- | --- | --- | --- | --- | --- |
| Auto-zoom | ✅ AX-anchored + reasons | ✅ cursor | ✅ | ❌ | ✅ |
| Native macOS | ✅ | ✅ | ⚠️ Tauri | ✅ | ✅ |
| Full NLE | ❌ by choice | ⚠️ | ⚠️ | ✅ | ⚠️ |
| Text-based editing | ✅ | ✅ | ❌ | ✅ | ❌ |
| Agent / MCP | ✅ review | ✅ generative | ❌ | ✅ generative | ❌ |
| **Variants re-solved** | ✅ | ❌ | ❌ | ❌ | ❌ |
| **Evidence graph** | ✅ | ❌ | ❌ | ❌ | ❌ |
| **Launch artefacts** | ✅ | ❌ | ❌ | ❌ | ❌ |
| **GitHub release detection** | ✅ | ❌ | ❌ | ❌ | ❌ |
| **Publishing with approval** | ✅ | ❌ | ⚠️ links | ❌ | ❌ |

Top half is table stakes. Bottom half is the product.

**The real competitor is the demo that never got made.** It has ~90% market share and no product team.

**Why won't ScreenKite build this?** They could. But their wedge is export speed and they are free, so
they optimise for volume of individuals, not a team workflow with a budget. The loop needs GitHub
integration, per-platform publishing with approval, and a release-bound provenance model — a different
data model, not a feature.

**Defensibility, honestly.** The recorder is not defensible. The loop is moderately defensible through
integration surface and switching cost. The hard-to-copy part is the evidence graph — and it is what
makes "the agent reviews rather than invents" true rather than claimed.

---

## Packaging

| Tier | Contains |
| --- | --- |
| **Free** | Record, auto-zoom, basic edit, transcript + text-based editing, backgrounds, MP4/GIF export |
| **Pro** | Release Pack, variants, selective re-record, MCP/CLI |
| **Team** | GitHub watch, publishing, approval workflow, coverage metric across repos |

**Free gets everything about making one good video. Paid gets derivation and distribution.** The
marginal cost of giving transcription away is near zero — `SpeechAnalyzer` is an OS API with no model
to ship. Withholding it would ship a free tier without the surface this document calls its primary
editor, while asking it to compete against a free competitor that has one.
