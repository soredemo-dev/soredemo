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

---

## D2-4 — `mach_absolute_time`, and sleep is a state to detect rather than ignore

`one-clock` says *"a sample before the origin or moving backwards is an error"*. That catches one
discontinuity and misses the one that actually happens.

**`mach_absolute_time()` does not advance while the system sleeps. `mach_continuous_time()` does.**
Not theoretical — measured on this machine:

```
mach_absolute_time    406387.952 s   (112.89 h)
mach_continuous_time  621253.784 s   (172.57 h)
divergence            214865.832 s   ( 59.68 h)
```

Up for 172 hours, asleep for 60 of them. The two clocks disagree by 35% of this machine's uptime.

**We use `absolute`, and the choice is forced, not preferred.** `CMClockGetHostTimeClock()` is
`mach_absolute_time()` (F2-1), so frame presentation timestamps are on it, and `CGEventTimestamp` is
host time on the same base. Mixing in `continuous` anywhere would reintroduce exactly the skew F2-1
established does not exist.

### Why this is worse than the discontinuity the row already names

Sleep does not move the clock backwards. **It stops it.** Across a sleep, timestamps do not regress
and nothing precedes the origin — so `one-clock`'s stated check passes, every ordering assertion
passes, and the recording simply contains a gap where no time appears to have elapsed while a great
deal did. A stopped clock is harder to see than a reversed one because every guard is satisfied.

This is `AGENTS.md`'s "a measurement has no safe default" at the level of a whole timeline: the
failure produces a legal-looking result.

### The detector is the divergence itself

Read both clocks at the start and end of a recording. If `continuous` advanced more than `absolute`,
the system slept, and the difference is how long for:

```swift
let sleptNanos = (contEnd - contStart) - (absEnd - absStart)
```

Cheap, exact, and needs no API beyond the two already in use. Record it in the observation log as a
first-class state — not a warning printed once, but a value a later gate can reject on. A demo
recorded across a machine sleep is not a demo, and the derivation stage must be able to see that
rather than infer it from a suspicious gap.

Sampling frequency and what the recorder does on detection — abort, mark, or split — are open, and
belong with the `capture-stream` work rather than here.

---

## F2-2 — Spike A: the pairing hazard is entirely on the AX side

118 clicks, one machine (Apple Silicon, macOS 26.6), one session, mixed native AppKit / Electron /
web content, deliberately including clicks during menu, Dock and window animations.

**These are not calibrated thresholds.** One machine, one session, an uncontrolled app mix, and no
labelling of which target each sample hit. D4 still applies; this is the first distribution, not the
answer. The raw log is **not committed** — it carries window titles from real work — so what follows
is the analysis, reproducible by re-running the spike.

```
                      p50      p90      p95      max
tap latency          0.41     1.64     2.57     5.46 ms
hit-test interval    1.05    21.25    42.03   125.47 ms
whole AX walk        5.10    32.22    55.46   173.53 ms
AX calls               41      106      110      131
chain depth             3       12       20       20
chain-inconsistency  3.90    30.00    50.24   109.57 ms
   in 60 fps frames    0.2      1.8      3.0      6.6
```

### 1. Tap latency is not the hazard, and D2-2 said otherwise

D2-2 described the click-to-hit-test pairing as a risk shared between the two halves. It is not.
The tap arrives in **0.41 ms at p50 and 5.46 ms at the worst of 118 samples** — well inside a single
frame, every time. Essentially all of the pairing uncertainty is on the AX side, where the same
statistic runs to 125 ms.

The framing was wrong in a way that would have spread effort evenly across two problems of very
different size.

### 2. The hit-test spreads by 120×, and 12% of clicks exceed a frame

p50 1.05 ms, max 125.47 ms. **14 of 118 hit-tests (12%) took longer than one 60 fps frame**, so on
one click in eight the layout could already have moved before the answer came back. The slowest
were exactly where predicted: an `AXMenuItem` during a menu animation (51 ms), an `AXDockItem` while
the Dock was moving (49 ms), and `AXGroup`/`AXScrollArea` in web content (125 ms, 42 ms).

### 3. The chain that never simultaneously existed, measured

D2-2 argued that an unbounded walk records a chain whose levels were sampled at different moments.
Measured from the start of the hit-test to the last ancestor read:

**p90 is 1.8 frames. p95 is 3.0 frames. The worst is 6.6 frames.**

At p95 the UI has had three frames to move between the top and bottom of a chain that will be stored
as one observation. This is why every item carries its own interval (D2-2a) rather than the chain
carrying one timestamp — and it is why a later gate needs the interval, not a number.

### 4. Depth and time are independent axes, which is why both bounds are needed

D2-2 asked for a depth cap *and* a wall-clock budget. The data says these catch **different
things**, which is a better reason than the one originally given:

- The 10 samples that hit the depth cap of 20 mostly completed in **4–13 ms**. Their chain tops were
  `AXWebArea` — web and Electron hierarchies are cheap per level and simply deep.
- The 1 sample that exceeded the budget took **173 ms across 131 calls** and was not the deepest.

Deep is not slow and slow is not deep. A depth cap alone misses a blocked responder; a budget alone
misses a 25-level web hierarchy that answers quickly.

### 5. No budget removes truncation, so recording it is structural

| Depth cap | truncated | | Budget | truncated |
| --- | --- | --- | --- | --- |
| 12 | 13% | | 5 ms | 51% |
| 16 | 9% | | 10 ms | 25% |
| 20 | 8% | | 20 ms | 15% |
| 25 | 0% | | 35 ms | 9% |
| 30 | 0% | | 50 ms | 7% |

Depth has a clean knee — 25 covers everything seen here. **Time does not.** The tail flattens and
never reaches zero: even at 50 ms, 7% of clicks are still cut off. So D2-2's "truncation is itself a
record" is not defensive habit, it is the only honest way to store this: some proportion of every
recording will be truncated, permanently, and the derivation stage has to be able to tell that from
"the chain ended here".

### 6. The units guard never fired

`tapLatencyNegative` is false in all 118 samples. The `CGEventTimestamp`-in-nanoseconds finding from
F2-1 holds under load, and the guard that would have caught a regression was present and silent for
the right reason — which is only knowable because it reports rather than defaults (`AGENTS.md`, a
measurement has no safe default).

### Still open

- Per-target distributions. The sample was not labelled by application, so "Electron is slower" is
  visible in the chain-top roles but not measured. Spike A should record the frontmost bundle
  identifier before this feeds a threshold.
- Whether one level of children (D2-3) is enough. Not answered here; needs the derivation stage to
  exist before it can be judged.
- Everything above is one machine. A slower or busier machine moves the whole distribution, and the
  budget is the parameter that will move most.

---

## F2-3 — Truncation degrades gracefully, because the walk runs the right way

The 7%-at-50 ms figure in F2-2 reads worse than it is, and the reason is in the same data.

`AXUIElementCopyElementAtPosition` returns the **deepest** element at the point, and the walk goes
up through `kAXParentAttribute`. So the chain is ordered:

```
hit element → parent → grandparent → … → window → application
most likely to be the target ─────────────────→ least likely
```

Truncation therefore drops the **outermost** ancestors — the ones least likely to be what the camera
should frame.

Verified in the code (`cur = start`, walk up, `break` on cap or budget) and independently in the
data:

| | Top of chain |
| --- | --- |
| 107 complete walks | `AXApplication`, all of them |
| 11 truncated walks | `AXGroup` ×7, `AXWebArea` ×2, `AXWindow` ×2 — mid-level containers |

So the 7% is not "7% of clicks lost". It is "7% of clicks are missing some outer ancestors", and an
outer ancestor is almost never the zoom target.

**Recorded so that nobody later reads 7% and raises the budget.** The tail does not converge, so
raising it buys progressively less of something that was not worth much to begin with.

### But it needs a rejection code that does not exist yet

`framing-gates` lists seven: *confidence absent, confidence low, observation stale, does not contain
the click, degenerate rectangle, partly offscreen, too large*. None of them can say:

> **The best candidate sits on the truncation boundary** — so I cannot know whether one more level
> out would have been better.

On disk that case is **identical** to "the chain was complete and the best candidate happened to be
outermost", unless the producer reads the truncation record. It can — truncation is stored (D2-2) —
but nothing currently requires it to, and an eighth code is what would force the question.

At 7–8% this is not an edge case. It is part of the normal path.

## D2-5 — The two bounds are different kinds of number and only one needs calibrating

F2-2 called both placeholders. That was one word too coarse.

**The depth cap has a clean knee and is nearly free.** 25 covers every sample seen; the walks that
hit a cap of 20 completed in 4–13 ms, because deep hierarchies are web content — cheap per level,
simply tall. Fix it now at **30**, and expect it to bind rarely.

**The wall-clock budget has no knee.** 20 ms → 15% truncated, 35 ms → 9%, 50 ms → 7%: a direct
exchange of coverage for latency with no natural stopping point. It is the one number in this design
that genuinely requires D4 calibration against recorded demos, and the one that will move most on a
slower or busier machine.

So: three thresholds were called placeholders; **one of them is.** Saying so now saves rediscovering
it twice.

---

## What this document does NOT cover

Stated because a status table in conversation marked `input-observation` as designed, and it is not.

**Pointer sampling rate is undecided, and cannot be decided here.** Everything above concerns the
*click* half of `input-observation` — the event tap that says when and where, paired with the AX
hit-test that says what. Spike A listened to `leftMouseDown` and `rightMouseDown` only; it never
subscribed to `mouseMoved`, so the pointer track has not been measured at all.

The rate is not free to choose. `cursor-render` asks for a spring-smoothed cursor drawn at composite
time, and **how dense the track must be to avoid aliasing under that smoothing is a property of the
smoothing, not of the tap.** An event tap will deliver every system-generated mouse move — 60–120 Hz,
more on a high-refresh display. Keeping all of them is a volume question; thinning them is a "thin to
what" question whose answer lives in a row that has no design yet.

So four of Phase 2's fourteen rows are designed and one of those four has a parameter waiting on one
of the other ten. The observation half is **not** independently plannable, which is the reason to
design the whole phase before planning any of it — a better reason than the one originally given.

Undesigned as of this document: `capture-source`, `capture-stream`, `audio-tracks`, `render-core`,
`cursor-render`, `export-basic`, `app-shell`, `preview-playback`, `render-parity`, and the
degradation behaviour half of `capture-permissions`.

---

## D2-6 — One compositor, and `render-parity` says so already

Preview and export run the **same** `AVVideoCompositing` compositor. Preview drives it through
`AVPlayer` + `AVMutableVideoComposition` into a `CADisplayLink`; export drives it through
`AVAssetWriter`. `render-parity` stops being a long-running source of pain and becomes a test that
the wiring has not come apart.

The question was put as *"what would force them to be two paths?"* rather than *"should they
share one?"*, because `render-parity` existing at all already answers the second — a row demanding
identical frames for the same input would not have been written if two paths were acceptable. Three
candidate reasons, none of which survives:

| Claim | Why it fails |
| --- | --- |
| preview must be real-time, export can be slow | argues for different **budgets**, not different paths. One compositor can drop resolution or quality tier for preview. What diverges is a parameter |
| `AVPlayer` gives seek and scrub for free | true, and it is the path `a native editor` took. It buys convenience with two paths that can never be shown to agree — the trade `render-parity` exists to refuse |
| export runs VideoToolbox hardware encode | encoding happens *after* compositing. An output-stage difference, not a compositing-stage one |

**The neighbouring project is the evidence, and precisely.** `a native editor` has
`Preview/VideoEngine.swift` on `AVPlayerLayer` and `Compositing/CustomVideoCompositor.swift` for
export — two paths — across 534 Swift files and 149 test files. It is not that the project does not
write parity tests: `VisualEmbedderParityTests` and `TextTokenizerGoldens` exist. It writes them for
search and not for render, which is a stronger statement than an absence would be.

### `render-parity` is under-specified in three ways, and each would report as a false failure

None of these is a reason to split the path. All three are reasons the row must say more than
*"identical frames for the same input"*, or an implementer will chase a bug that is not there.

**1. Where in the pipeline the comparison happens.** Preview goes through the display pipeline —
sRGB or Display P3, EDR, system colour management. Export writes a file with explicit primaries,
transfer and matrix, typically Rec.709 for H.264. The **same pixel buffer from the same compositor
can look different in those two places**, and if the compositor's working colour space is not
pinned, export carries a cast preview never showed. So parity compares the **compositor's output
buffer, before colour management** — testable — not final appearance, which is not.

**2. Which instants are compared.** `SCStream` is variable frame rate. Confirmed in the SDK:
`minimumFrameInterval` is documented as *"the desired minimum time between frame updates, allowing
you to throttle… at or up to 60fps"* — a floor, not a cadence — and `SCFrameStatusIdle` exists
precisely for *"new frame was not generated because the display did not change"*. Source PTS are
therefore irregular by nature. Preview is driven by `CADisplayLink` at a fixed 60 or 120 Hz and
export by composition time, so the two **sample at different instants, and that is not a defect**.
The parity test must name an explicit set of composition times and render both paths at those.

**3. What is inside the compositor and what is on top of it.** Preview-only chrome — selection
handles, safe-area guides, the crop box — must live in a layer **above** the compositor. Inside, it
gets baked into the export, silently, discoverable only by opening the file. This makes the first
point concrete: parity compares the compositor's output, not the screen's contents, and an
implementer who screenshots the preview to compare is testing the wrong thing.

**Consequence for `capture-stream`.** `SCFrameStatusIdle` means a sample buffer can arrive carrying
no new frame. "The display did not change" and "we received nothing" must stay distinguishable in
the observation log — the same rule as truncation in D2-2 and the truncated tail in `JSONLReader`.
Silence is not a value.

## D2-7 — The cursor is drawn inside the compositor, so the pointer track is kept whole

D2-6 answers the pointer sampling rate that the previous section left open, and it answers it twice
over.

**Where the spring runs is forced.** If the cursor were composited in the preview layer, the
two-path problem returns one level down: a preview cursor and an export cursor that can never be
shown to agree — or worse, a cursor that appears in preview and is missing from the file. So the
cursor is drawn **inside** the compositor, the spring integrates at composite time, and the sampling
rate answers to the composite frame rate rather than to the tap.

**And the track is recorded whole, not thinned.** Two reasons, and the second is the one that
matters:

*Cheap.* A pointer sample is roughly 24 bytes. 120 Hz for five minutes is about 36,000 samples,
around 1 MB, against several GB of video. As with the AX chain, storage is not the constraint.

*Thinning at capture time bakes a producer's judgement into the evidence.* "How dense is dense
enough to avoid aliasing under this spring" is a property of the spring, and `camera-motion`
explicitly requires motion that *settles without overshoot* — a calibration that will be tuned. A
thinned track cannot be re-tuned; the samples are gone.

This is the identical argument to D2-1, one row over: **record everything, judge in derivation,
because re-recording a demo is expensive.** That it arrives independently at the same answer for a
different subsystem is the argument's strength, not a coincidence.
