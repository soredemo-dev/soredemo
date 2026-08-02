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

---

## F2-1 — One clock, three sampling moments, two representations

Measured on this machine (Apple Silicon, macOS 26.6, Xcode-beta 27.0), not read from
documentation. An earlier draft of this document said the pairing had to span *three clocks*; that
framing was wrong and would have sent the spike to measure a difference that does not exist.

```
mach_timebase_info                 numer = 125, denom = 3   →   1 tick = 41.667 ns
CMClockGetTime(hostTimeClock)      406033136183083   (timescale 1e9, i.e. nanoseconds)
mach_absolute_time() × 125/3       406033136166250
                                   ↑ 17 µs apart — the gap between the two reads, not an offset
CMClockMakeHostTimeFromSystemUnits round-trips to the exact input:  true
```

`CMClockGetHostTimeClock()` is `mach_absolute_time()`. `CMClockMakeHostTimeFromSystemUnits` and
`CMClockConvertHostTimeToSystemUnits` are exact conversions, not estimates — verified by round trip.

**So there is no clock skew to measure between a frame's PTS and a `CGEvent`. There is only
latency**, and every latency is measured on the one clock:

| Latency | From → to |
| --- | --- |
| tap | the event's timestamp → the moment the callback runs |
| AX | the hit-test call → its return |
| frame | PTS → the sample buffer arriving in the callback |

### `CGEventTimestamp` is in nanoseconds

This was the spike's first target, because it is the failure that does not announce itself. On
Intel `mach_timebase_info` is 1/1 and ticks *are* nanoseconds, so the question never arises. On
Apple Silicon the ratio is 125/3, and guessing wrong places every click at 1/24 of its true offset —
no error, no crash, just a video whose zooms never line up.

Measured with an AppKit window reading **its own** mouse events, which needs no TCC grant at all:

```
NSEvent.timestamp   406105.627764  seconds since boot
CGEvent.timestamp   406105627764000
mach_absolute_time  9746535213658   ×125/3 = 406105633902416
ratio cg / mach = 41.6667  = 125/3    →  CGEventTimestamp is NANOSECONDS
```

Three samples, ratio identical in all three. Convert to mach units with `× denom/numer` (`× 3/125`),
or better, stay in nanoseconds and use the CoreMedia conversions.

### First latency distribution, and what it is not

| Sample | CGEvent (ns) | host time at handler (ns) | event → handler |
| --- | --- | --- | --- |
| 0 | 406105627764000 | 406105633902416 | **6.14 ms** |
| 1 | 406105990179208 | 406105992536416 | **2.36 ms** |
| 2 | 406106344463416 | 406106345311791 | **0.85 ms** |

**This is the app's own events arriving through its `NSEvent` run loop. It is not a `CGEvent` tap.**
A tap is a different path with different scheduling, and this figure is a lower bound on that, not a
measurement of it. Spike A must measure the tap path directly.

### The probe committed the error it was built to detect

Its "event → handler" line read `m >= cg ? m - cg : 0` — written while assuming `cg` was in ticks.
Since `cg` (ns, 4.06e14) exceeds `m` (ticks, 9.7e12), the guard failed and it **printed `0 µs`**.

A unit assumption that was never measured, inside the probe written to measure unit assumptions,
failing by printing zero rather than by raising. `AGENTS.md` already carries this shape twice —
`wc -l` returning 1 for empty input, and a filter reporting silence for a row it does not match.
This is the third: **a guard whose false branch is a plausible value.**

---

## D2-2a — An AX observation carries an interval, not a timestamp

Amends D2-2. `AXUIElementCopyElementAtPosition` returns no timestamp of its own; all you know is
when you asked and when it answered. So each AX observation records `mach_absolute_time()`
**before and after** the call, and the pair is stored.

What you have is not "the moment of the AX snapshot". It is an interval, and **its width is the
uncertainty**. Recording a single timestamp would be inventing a precision that was never measured —
the same error as the units question above, one layer up.

This is what finally gives `framing-gates`' `observation stale` rejection code a real input: a gate
can reject on an interval too wide to place the snapshot against the click, instead of comparing a
number that only looks exact.

Per D2-2, each item in the chain carries its own pair, not one pair for the whole chain.

---

## Spike A — before any capture code

Split so the dangerous half needs fewer grants. **A needs Input Monitoring and Accessibility, not
Screen Recording.** B adds `SCStream` and needs Screen Recording. Do A first.

A answers: tap-path latency (the real one, not F2-1's lower bound), AX interval width, and how both
behave under load.

**Sample against animation, not a static screen.** The pairing fails while the UI is animating,
which is exactly when a person clicks a button. At least three targets — native AppKit, an Electron
app (Slack or VS Code), and one known to be slow. Their AX latency distributions differ by a lot,
and the depth cap in D2-2 must be calibrated against the **worst** of them, not the best.
