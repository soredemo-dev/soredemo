# Phase 2B — Render and export

**Six ROADMAP rows:** `render-core`, `cursor-render`, `export-basic`, `app-shell`,
`preview-playback`, `render-parity`.

---

## 0 — The completion condition, and why it is written first

**Every row in this phase closes on what a person can do, never on what compiles.**

That is this project's own completion rule — *a row is not complete while the behaviour its name
claims is not observable in the product* — and Phase 2B is the first phase where it bites.
Every Phase 2 row could go green with nothing ever on screen: 408 tests, 304 probe checks,
five human verification runs, and not one rendered frame. `render-core`'s name claims rendering.
Observable means **somebody saw a frame**.

So the phase closes on one sentence:

> Record a few seconds → see that recording in the app's preview, framed on a background with a
> card, a shadow and rounded corners, with a drawn pointer moving through it → export → open the
> exported file in QuickTime and watch it.

Nothing in this document is done until that sentence is true. A row whose tests pass and whose
output nobody has looked at is **not** a completed row; it is Phase 2's shape repeated with a
different vocabulary, and the reason this section is section 0 is that the repetition would be
invisible from the inside.

**Corollary for the plan's task order.** `app-shell` and `preview-playback` are not the last rows.
Something must put a frame on screen early, or the phase accumulates unobserved work exactly the
way 2A did. The first task that renders anything renders it *into a window*.

---

## 1 — Scope: what `export-basic` produces

**One playable file. Full stop.**

- **One container**, MP4 (H.264). Not ProRes, not MOV variants, not GIF.
- **No** poster frame, **no** written steps, **no** post copy, **no** platform variants.

The ROADMAP's `export-basic` row mentions MP4/MOV/GIF; this phase takes the first and defers the
rest. The output *bundle* — MP4 plus GIF plus poster plus written steps plus a post — is Phase 5,
and it will pull in `variants` and the launch rows with it. Written here because a scope like that
grows quietly: each addition is individually small and none of them is the one that made the phase
late.

**Definition of done for the row:** a file that QuickTime opens and plays, with the rendered
framing and the drawn pointer in it.

---

## 2 — The four questions, settled

### 2.1 What is drawn where the observation track is blind

**Decision: the camera does not re-aim in a blind interval, and the interval is recorded with its
duration.**

The gap is real. D6a's tap-disabled row measures it, and under a persistent cause the record
reached **81% of the span marked blind** — but that figure is an *induced* worst case (1844
observations each stalled 50 ms, 92.2 s of deliberate lateness). The same instrument under normal
load measured **87 polls and zero blind windows**. So gaps are a degradation mode, not the usual
state, and the policy is about what happens when the degradation occurs.

Three clauses, and the second and third are not decoration:

1. **A motion already in flight completes; no new target is acquired.** The motion was derived from
   real evidence *before* the gap, so carrying out an already-derived decision is not invention.
   Freezing dead would produce a twitch that corresponds to no event — a visible artefact
   manufactured by the policy itself.
2. **The `cause` uses Task 11's existing vocabulary.** `GapSite` and the interval types already name
   why observation stopped. A second vocabulary for the same fact is how two instruments start
   disagreeing, which this project has already paid for once.
3. **`BlindInterval` must reach the review UI, and a threshold must speak.** Above some blind
   fraction the review marks the recording rather than silently delivering a video with almost no
   automatic framing. `ProjectSnapshot` is storage, not a reader — a record that only the file can
   see is indistinguishable from its own absence.

**The reason, recorded precisely, because the wrong reason is available and sounds better.** It is
not that this option is "more honest". It is that the *producer-value rule* exists: automatic
behaviour does not need to look good, it needs to be honest and fixable. Interpolation and
hold-last-known both produce footage that looks fine, and looking fine is exactly what deletes the
signal that says **someone needs to look at this**.

*Rejected — interpolation:* invents data that was never observed, against the derivation rule that
every derived value points back at its evidence. *Rejected — hold last known:* invents no
coordinate but invents the fact that the pointer did not move, and on screen that is
indistinguishable from a user who really did stop moving.

### 2.2 Who draws the cursor, and from what

**Decision: `showsCursor = false` stays, and the compositor draws our own pointer art. This is a
constraint, not a preference.**

Measured: there is no supported way for this app to obtain another application's cursor image.
`NSCursor.currentCursor` reports our own process's cursor. `NSCursor.currentSystemCursor` is
deprecated. ScreenCaptureKit exposes exactly two cursor controls — `showsCursor` (bake it into the
frame) and `showMouseClicks` (its own circle) — and nothing out of band.

Two clauses:

1. **The substitution is stated, not apologised for.** The pointer is a derived value whose origin
   is **drawn, not captured**, and the shape information is *lost* in the substitution: I-beam over
   text, the resize arrows, the open hand, the spinner — all render as our one pointer. That is a
   visible statement in the review UI, in the same place every other derived value shows its origin.
   It is not a note on the finished product.
2. **Whether the real cursor was hidden — measured, and the answer is no.** Spike E, macOS 26.5.2
   build 25F84, with the hide induced by the spike itself and the stimulus control passing:
   `NSCursor.currentSystem` returns the identical cursor hidden and visible, and both
   `CGCursorIsVisible` and `CGCursorIsDrawnInFramebuffer` are **unavailable** at this deployment
   target — a compile error, not a runtime answer.

   So the hidden state is not readable, and `cursor-render` ships with a **named** defect: a pointer
   is drawn at moments the real screen had none. macOS hides the pointer while you type, which a
   demo recording does constantly. A D6a row and a review-UI sentence, not something a viewer finds.

**A correction worth keeping.** The first reading of this said Apple's deprecation message settles
it — the message says *"Use ScreenCaptureKit… use the `showsCursor` property"*. It does not: it
answers *how do I make the cursor appear in a capture*, which is a different question from *how do I
obtain the cursor image*. It is also prose, and prose from exactly the field that was measured wrong
earlier the same day (a message naming `finish(withComposedVideoFrame:)` for a selector that ships
as `finish(withComposedPixelBuffer:)`).

*Rejected — `showsCursor = true`:* overturns D2-8 and forfeits spring smoothing, click ripples and
size compensation under zoom, which is most of what the cursor rendering is for.

### 2.3 One render path, two time budgets

**Decision: preview may drop frames; export may not. The dropped count is a recorded value.**

D8 makes preview and export share a compositor, which settles *whether the two agree*. It says
nothing about what happens when the path cannot keep up, and the two answers are opposite:

| | Behaviour when late | Why |
| --- | --- | --- |
| Preview | **drop**, and count the drops | a preview that blocks stops being a preview |
| Export | **never drop**; take the time | the exported file is the deliverable |

**The drop count is a value the recording carries, not a console line.** "What you review is what
ships" is false at a specific, nameable place — the frames the preview skipped — and a number that
names it is what keeps that from being a surprise. Same shape as every D6a row: the loss is
bounded, counted, and reported in the unit that was lost.

This is written now because it decides the compositor's interface: the renderer takes a
*deadline* on the preview path and none on the export path, and a renderer designed without that
distinction cannot be given one later without changing every caller.

### 2.4 A differential test across the seam

**Decision: build it now — the rig exists.**

Two `MasterWriting` implementations are live: `LegacyMasterWriter` (the shipping capture path) and
the successor stack that Phase 2B's new writing code targets. Two implementations of one behaviour
with nothing comparing them is the failure the definite-singular audit's row 3 names, and it is the
only thing that makes the seam trustworthy.

The test feeds identical input to both and compares **the facts of the finished files, read back
from the asset** — audio track count, video track count, and the colour tag triple — not each
writer's own account of what it did. `SoredemoSpikeD --verify` already does exactly this for two
properties; generalising it costs almost nothing because the apparatus is built.

Without it, the two implementations diverge quietly, and the evidence of divergence is a file
nobody compares.

---

## 3 — Structure

**The boundary is D1's, and it is what makes `render-parity` testable without a GPU.**

```
Sources/                       Foundation only
  <plan>                       (project, output time) → RenderPlan
                               background, card rect, corner radius, shadow,
                               pointer position at t, blind-interval policy
Soredemo/Render/               AVVideoCompositing over Core Image, Metal-backed
                               executes a RenderPlan; owns no policy
Soredemo/UI/                   the shell, the preview view, the export command
```

**The split is the point.** Every decision — where the card sits, what the pointer position is at
composition time *t*, whether *t* falls in a blind interval — is a pure function of the project and
the time, computed in the package and unit-testable with no window and no GPU. The app target draws
what it is told. `render-parity`'s golden images then test *the drawing*, and everything upstream of
the drawing is tested by ordinary tests.

**Which package target the plan lives in is an open question**, deliberately left to the plan:
`Sources/Framing` and `Sources/Variants` are both placeholders today, and a new target has plugin,
allow-list and determinism-exemption consequences that should be decided once, with those files
open, rather than guessed here.

**The transport is settled and is not re-opened here:** `AVVideoComposition` built from
`AVVideoComposition.Configuration`, driving one custom compositor for both preview and export.
See `ARCHITECTURE.md` D8.

**New media-writing code uses the successor stack** (`inputReceiver(for:)`,
`appendImmediately(_:)`), per the ruling in `MasterWriter.swift`: the existing capture path stays
legacy because switching it costs a human verification run, and new code has no migration cost
because it does not exist yet.

---

## 4 — What this phase does not do

- No zoom, no camera motion, no framing targets — Phase 3. The camera in 2B is fixed.
- No trim, cut, speed, transcript — Phase 4.
- No title scenes, music, poster, publishing — Phase 5.
- No GIF, no ProRes, no platform variants — Phase 5's output bundle.
- No custom Liquid Glass. Standard SwiftUI chrome, opaque content surfaces, per D7.

`BlindInterval` and the cursor-substitution statement both need somewhere in the UI to appear.
Phase 3's `review-ui` is where every generated value shows its origin and review state; 2B carries
the **values** and the **minimum surface** that makes them visible, not the full review interface.

---

## 5 — Open, and to be settled in the plan

1. Which package target holds the render plan (see § 3).
2. The blind-fraction threshold at which the review marks a recording — a number, and it should be
   chosen against a real recording rather than picked here.
3. Core Image filter graph vs hand-written Metal for the card, shadow and corner radius. Both are in
   D8's stated scope; the choice should be made against a measured frame time at 4K, not in advance.
