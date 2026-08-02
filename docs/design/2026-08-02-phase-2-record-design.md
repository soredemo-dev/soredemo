# Phase 2 — Record: design

*Covers `capture-source`, `capture-stream`, `capture-permissions`, `one-clock`, `audio-tracks`,
`input-observation`, `ax-observation`, `observation-log`, `render-core`, `cursor-render`,
`export-basic`, `app-shell`, `preview-playback`, `render-parity`.*

Decisions are cited as D2-1, D2-2, … Findings from measurement as F2-1, …
This document records *why*. `ROADMAP.md` records what is delivered.

---

## D2-0 — App Sandbox is off

Settled before the phase began; the reasoning is in
`docs/design/2026-08-01-phase-1-carried-forward.md` § Defaults this phase depended on and never
decided. Summary: the sandbox blocks the Accessibility API against other processes in a layer in
front of TCC, and `PRODUCT.md`'s thesis — one recording is evidence, every derived value is
traceable to it — has no content without semantic evidence.

Consequence for this phase: `ENABLE_APP_SANDBOX = NO`, hardened runtime stays on, and the work App
Store distribution was absorbing is now ours. That list is in the same file.

---

## D2-1 — The observation log records the whole AX chain and makes no choice about it

`ROADMAP.md`'s `ax-observation` row asks for the control under each click *"with role, frame, and a
preference for **well-bounded descendants**"*. The question is when that preference is applied: at
capture time, or later, in derivation.

**It is applied later. Capture records; it does not judge.**

### Why: the preference is a gate, and gates are calibrated

`framing-gates` already enumerates this family — *confidence absent, confidence low, observation
stale, does not contain the click, degenerate rectangle, partly offscreen, too large* — and
`ARCHITECTURE.md` D4 requires their thresholds to be **measured against real distributions, not
chosen by intuition**. "Which layer is the meaningful control" is the same kind of judgement, with
the same kind of thresholds — how large is too large, how tight is well-bounded — and no data exists
yet to calibrate them.

Deciding at capture time writes a producer's judgement into the evidence layer.

### The consequence that makes this structural rather than cautious

**`producerVersion` would stop meaning anything for that decision.** The graph's whole design is
that a producer can be improved, its version bumped, and everything re-derived from the evidence.
That works for framing, for beats, for variants. It would not work for element choice, because the
alternatives were discarded at capture time and cannot be recovered.

The result would be a `Derived` value whose evidence **structurally cannot support any other
answer**. That is not evidence. It is an inference wearing evidence's clothes — and it would sit in
the graph looking exactly like the real thing, which is worse than an obvious gap.

Re-recording a demo is expensive. Evidence has to stay re-interpretable.

### Why the volume argument does not apply

A five-minute demo with clicks 1–3 seconds apart is 100–200 clicks. An AppKit chain is typically
5–15 levels, deeper under Electron. Role, frame and a few attributes per level.

**A few MB of JSONL against several GB of video.** The cost is not storage.

## D2-2 — The real cost is at capture time, and it attacks this phase's own verification target

Each step up the chain is an `AXUIElementCopyAttributeValue` — a **synchronous IPC into the target
process**, made at the moment that process is busiest, because it is handling the click. Electron
apps, Java apps and hung apps block AX calls for hundreds of milliseconds, sometimes seconds.

An unbounded walk therefore does two bad things:

1. **It inflates the pairing latency** — the thing `input-observation` and `ax-observation` exist to
   get right. `CGEvent.tapCreate` says *when and where*; the AX hit-test says *what was there*. In
   "click the Save button" the verb comes from one and the object from the other, and the latency
   between them decides whether the hit-test returns the element that was under the cursor at click
   time. It goes wrong during UI animation, which is when people click buttons.
2. **It makes the chain internally inconsistent.** `ancestor[0]` sampled at *t*, `ancestor[8]` at
   *t+60ms*, with an animation running in between: a chain that **never simultaneously existed**.

The second is worse, because it is silent.

### So: bounded, per-item timestamps, and truncation recorded

Three things, and each is useless without the other two.

**Bounded.** A depth cap *and* a wall-clock budget. Stop at whichever is reached first.

**A timestamp per item, not one for the chain.** A later producer can then see that two levels are
60 ms apart and **reject on it**. `observation stale` is already a rejection code in
`framing-gates`; this is what finally gives it a real input.

**Truncation is itself a record.** "Depth cap reached" and "budget exceeded" are stored alongside
the data. Otherwise *"there were no more ancestors"* and *"I did not ask"* are byte-identical on
disk.

That last one is `JSONLReader`'s truncated-tail rule again, one layer up: silence turns a truncation
into a wrong answer. Phase 1 wrote `droppedBytes` for exactly this reason and the same discipline
applies here.

## D2-3 — Both directions are recorded, because the row's preference points downward

`AXUIElementCopyElementAtPosition` returns the **deepest** element at the point. Walking *up* is
`kAXParentAttribute` — a chain walk: cheap, bounded, linear.

But the row says *descendants*. If the hit-test returns a group and the meaningful control is a
well-bounded child **inside** it, finding that child is a **tree search**, not a walk — an order of
magnitude more expensive and considerably more judgement-laden. It must not happen at capture time,
by D2-1.

**And if it is not recorded, it cannot happen later either.** A derivation cannot search a tree that
was never captured.

So the record is:

| Direction | What is captured | Cost |
| --- | --- | --- |
| Up | bounded ancestor walk from the hit element | one `kAXParentAttribute` per level |
| Down | **one level of the hit element's direct children** | a single `kAXChildrenAttribute` call |

Both directions, neither judged. One extra call buys the downward option; without it, the preference
`ROADMAP.md` states in plain words is **unimplementable in derivation** — a document claiming a
behaviour the code cannot perform, which is the failure this project tabulated at the end of
Phase 1 and should not re-commit at the start of Phase 2.

### Open, to be measured in this phase

- The depth cap and the wall-clock budget are thresholds, so D4 applies: they are fitted to measured
  distributions, not chosen. Until there are recordings, they are placeholders and must be labelled
  as such wherever they appear.
- Whether one level of children is enough, or whether a well-bounded control is commonly two levels
  down inside a group. Measure before widening — each extra level is another synchronous IPC.
