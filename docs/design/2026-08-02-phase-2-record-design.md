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

---

## D2-8 — The master is unprocessed evidence, and the compositor reads it from disk

`PRODUCT.md`: one recording is evidence, everything else is derived from it. So the master file is
raw screen capture. Background, card, shadow, corner radius, cursor spring, camera motion — all
derived, all applied later by the compositor reading the master **plus** the observation log.

**This principle is already in the ROADMAP as a single rule.** `capture-stream` says
`showsCursor = false`, and the reason the cursor is not burned into the master is exactly that the
master is unprocessed evidence. What is written here is that rule generalised, not a new idea.

Consequences:

- **The compositor reads from a file, not from the live stream.** Preview and export therefore
  consume the same input by construction, which makes D2-6's parity cheaper again.
- **`media/`'s write-once rule becomes structural rather than conventional.** D-P3 stated it as a
  discipline; with the compositor read-only over the master there is no code path that can modify
  it. D-P3 should cite this rather than rest on care.
- **There is no live composited preview while recording**, and that is a **choice**, recorded here
  so nobody later discovers it as an unexplained limit. Nothing in the ROADMAP asks for one, and
  Presenter Overlay comes free from `SCContentSharingPicker` if a talking head is wanted. If a live
  composited preview is ever proposed, this is the decision it has to overturn.

## D2-9 — The master is a sequence of files, and the API leaves no choice

The question "which recording API" is downstream of a bigger one: **is the evidence one file or
several?** Three things force a boundary, and the first is already settled by the SDK.

**1. Pause. There is no pause.** `pause` and `resume` appear **zero times** in the entire
ScreenCaptureKit headers. `audio-tracks` requires audio "retimed across pause", so pause is a
committed feature — and implementing it means stopping one file and starting the next. The master is
a sequence. Not a design preference; the API offers nothing else.

**2. Display reconfiguration mid-recording.** A QuickTime video track cannot change dimensions
part-way through. Plugging in an external display or changing resolution therefore forces one of:
scale (which pollutes the evidence), split the file, or corrupt it. Phase 1 built `geometryRevision`
for the *coordinate* side of exactly this event; the *file* side has no answer yet. To be measured.

**3. Audio separation.** Settled to the point of a decision, from the SDK:

`SCStream` delivers `SCStreamOutputTypeScreen`, `SCStreamOutputTypeAudio` and
`SCStreamOutputTypeMicrophone` as three separate streams, with `captureMicrophone` available from
macOS 15.0 — below our floor. Separation at the source is not in question.

The question is what `SCRecordingOutput` does with them. Its `mixesAudioWithMicrophone` property is
`API_AVAILABLE(macos(27.0))`. **A switch for "do not mix" added in 27 is strong evidence that 26
mixes**, which would destroy the separation `audio-tracks` requires — in the evidence layer, at
step one. That is inference, not measurement, and it is Spike B's job.

So the fork is not "which API is nicer":

| | Audio evidence |
| --- | --- |
| `SCRecordingOutput` | writes the file for you; on macOS 26 you cannot control mixing |
| `AVAssetWriter` | you receive the three streams and write separate tracks yourself |

### What this moves if it is not settled now

The answer changes D-P3's `media/` layout — `master-01H….mov` becomes a set, each member carrying
its position on the overall timeline — and it changes `timeline-core`'s source mapping and how
`observation-log` spans a file boundary. All three are cheap to shape now and expensive to reshape
in Phase 3.

## Spike B — now worth more than its original justification

Two sections ago, B was judged low value: frame PTS → callback latency does not corrupt evidence,
only throughput. **That judgement is out of date.** One `SCStream` run answers three questions that
each decide the shape of a currently-undesigned row:

1. `AVAsset.tracks(withMediaType: .audio).count` on an `SCRecordingOutput` file at our floor — 1 or 2.
2. What happens on display reconfiguration mid-recording. One external-display plug is the whole
   experiment.
3. The original PTS → callback distribution, taken along the way.

Requires Screen Recording. Per F2-2's method: fixed install path, own bundle identifier, signed —
and per the same reasoning as Spike A, **not** the product's identifier, so that
`capture-permissions`' first-run flow stays testable.

---

## F2-4 — Spike B: `SCRecordingOutput` mixes the microphone in, so the master is written by `AVAssetWriter`

Four runs. The first three answered nothing about audio, for the same reason each time, and the
reason was the experiment design rather than the API — see the note at the end.

**The valid run**, with the microphone verified live *by the instrument* before recording started:

```
mic is live (peak rms 0.0186) — proceeding
audio tracks: 1
   440 Hz  0.200659     system audio, a sine generated by the spike's own process
  1000 Hz  0.002480     the microphone tone — 207× the reference
  3000 Hz  0.000012     reference, nothing is played here
```

One track carrying both tones. 1 kHz is not a harmonic of 440, and system audio is captured
digitally from a pure sine we generated, so the only path 1 kHz has into that file is the
microphone. **`SCRecordingOutput` at our floor mixes the microphone into the system-audio track.**

`audio-tracks` requires system audio and microphone as independent tracks. `SCRecordingOutput`
cannot deliver that on macOS 26 — `mixesAudioWithMicrophone` is `API_AVAILABLE(macos(27.0))`, and
D2-9 flagged that the property's existence was consistent with *either* reading. It is now settled
in the direction that costs us the convenient API.

**Decision: the master is written by `AVAssetWriter`**, receiving `SCStreamOutputTypeScreen`,
`SCStreamOutputTypeAudio` and `SCStreamOutputTypeMicrophone` as three separate streams and writing
audio as two tracks. `SCRecordingOutput` is not usable for evidence at this floor.

### Other measurements from the same runs

```
PTS → callback     p50 1.6–3.2 ms   p90 8.5–9.4 ms   max 29 ms … 175 ms
frame status       complete 284–1148,  idle 578–1490
observed rate      9.1 – 36.6 fps against a requested 60
```

**`SCFrameStatusIdle` is not an edge case.** Idle callbacks ran from 42% to 84% of all callbacks
across four runs, tracking how much the screen was actually changing. A capture path that treats
every callback as a frame will be wrong most of the time on a static screen.

**`minimumFrameInterval` is a floor, measured.** The SDK says so; the observed rate ranged 9–37 fps
against a requested 60, varying with screen activity. Anything downstream that assumes a cadence —
including the parity test's composition times (D2-6) — has to take instants from the source rather
than assume them.

**The PTS → callback tail is not stable.** Three runs peaked at 29 ms and one at **175 ms**, with
p50 unchanged at ~2 ms. A single outlier six times worse than the previous worst, which is a reason
to treat this as a buffering parameter with a long tail rather than a bounded latency.

### Still open: display reconfiguration

Not tested. Four runs, `display reconfigurations observed: 0` in every one. The instrument now says
so in those words rather than letting an unchanged frame size read as "macOS handled it" — but the
question from D2-9 is unanswered, and a QuickTime track still cannot change dimensions mid-track.

### The experiment design was the bug, three times

Runs 1–3 each produced an unreadable audio result, and each time the cause was a precondition that
was asked of a human rather than measured:

| Run | What was missing | How it presented |
| --- | --- | --- |
| 1 | no mic tone; mic permission unknown | 1 kHz at 0.0076 — read as possible mixing |
| 2 | no mic tone | 1 kHz below threshold — read as "mic dropped" |
| 3 | nothing playing at all | **both tones reported present in a silent file** |

Run 3 is the sharp one. The presence test was `amplitude > reference × 4`, and with a reference of
`0.000000` anything above zero passes. A ratio against a zero reference is not a test. This is the
fourth instance in this project of `AGENTS.md`'s rule that a measurement has no safe default, and
the second where the author of the rule broke it.

The fix was not to ask more carefully. It was to instrument the preconditions:

- microphone authorisation is read via `AVCaptureDevice.authorizationStatus(for:)` and the run
  **aborts** rather than recording an experiment that cannot be read;
- the microphone is sampled for eight seconds first, and the run aborts unless it is actually
  carrying signal;
- the 440 Hz system tone is generated by the spike itself, removing one human step entirely;
- display reconfiguration is counted through `CGDisplayRegisterReconfigurationCallback`, so "the
  display did not change" and "nobody changed the display" are different lines of output;
- the presence test gained an absolute floor, and a track below an RMS threshold reports
  "essentially silent, no conclusion possible" instead of a verdict.

The generalisable form: **a precondition that is requested rather than measured is a precondition
that silently did not happen**, and its absence produces a result shaped exactly like a finding.

---

## D2-10 — Display reconfiguration is an observed event, and its handling is already decided

Spike B never tested this, four runs running. It is not going to be tested, and the reason is that
**it cannot change any decision.**

Two facts are already established and neither is a claim about user behaviour:

1. A QuickTime video track cannot change dimensions part-way through.
2. Pause does not exist in ScreenCaptureKit (D2-9), so the master is already a **sequence** of files.

The second dissolves the first. If reconfiguration forces a file boundary, that boundary is the
**same mechanism pause already requires** — close the current segment, open the next, carry the new
`geometryRevision`. There is no design fork here to measure into.

Measuring the *frequency* would matter only if we were deciding whether to handle it at all. We are
not: the mechanism exists for another reason and reconfiguration rides it.

### What is genuinely open, and where it gets settled

Whether the stream stops cleanly and reports, or degrades silently. That is `capture-stream`'s error
handling, and it will surface while writing that row — with real code in hand to fix, which is
better than observing it in a spike and re-implementing weeks later.

### What this adds to the design now

**Register `CGDisplayRegisterReconfigurationCallback`.** Not as instrumentation for a spike — in the
product.

| | |
| --- | --- |
| registered | reconfiguration is an **observed event**: close the segment deliberately, open the next, record a named boundary |
| not registered | it is **inferred** from frames stopping or sizes not matching — after the file is already wrong |

This is the same rule as `SCFrameStatusIdle` and as truncation in D2-2: *"nothing changed"* and
*"we were not told"* must not be the same bytes on disk.

**And it gives `geometryRevision` its trigger.** Phase 1 built the type, made cross-revision
comparison a precondition failure, and never said what event mints a new revision. This is the
event. That gap was not visible from inside Phase 1 — the type looked complete because nothing
called it, which is the same completion-rule blind spot `NormalizationContext` sits in.

### Why the spike was not run, recorded so it is not proposed again

The alternative was to drive the change from code with `CGDisplaySetDisplayMode`. That would be the
first spike in this project to **alter the machine's state**: the worst case of the previous three
was a wrong number in a log, and the worst case of this one is a display left in an unexpected mode
if the process dies between changing and restoring. Small, but it is a real cost on one side of a
balance whose other side is a measurement that changes nothing.

---

## D2-11 — `BootEpoch`, because a host timestamp is meaningless without one

Found while deciding which timeline the observation log stores (D2-12 Q1), not by looking for it.

`mach_absolute_time()` **restarts at boot.** D2-4 chose it, and had to — `CMClockGetHostTimeClock()`
is that clock, so frame PTS and `CGEventTimestamp` are on it. But that makes a stored host timestamp
meaningless across a reboot, and worse than meaningless: two recordings made in different boots
carry **overlapping, incomparable** timestamps, and nothing raises an error. Phase 4's
`selective-rerecord` splices new footage into an existing project, which is exactly where two such
sets meet.

D2-4 named one discontinuity in this clock — it stops during sleep. This is the second, in the same
type, and it is worse because sleep leaves the ordering intact.

### The shape already exists, on the other axis

This is `GeometryRevision` moved to the time axis, and deliberately so:

| | `GeometryRevision` | `BootEpoch` |
| --- | --- | --- |
| Guards | are two coordinates in the same reference frame | are two timestamps in the same clock epoch |
| Without it | a zoom lands on the wrong control, no error | an observation lands at the wrong moment, no error |
| Cross-boundary comparison | precondition failure | **split — see below** |
| Registered in the document | `GeometryRegistry` | an epoch table |

**Correction (Task 1 review):** this table originally said cross-boundary comparison was "the same"
as `GeometryRevision`'s — a precondition failure — and the brief specified a type that does not do
that uniformly. The code is right and this row was wrong. `HostInstant.<` traps, matching
`NormalizedFrame.contains`'s stance on `geometryRevision`: ordering two instants assumes a shared
clock, and reaching the comparison with epochs that differ is mis-plumbed state, not a question
worth an answer. `HostRange.contains`, by contrast, returns `false` for an instant from another
epoch rather than trapping, because "does this instant fall in this range" is a question a caller
can legitimately ask across epochs and needs an answer to, not a caller error — Task 4's
`SegmentTable.contentTime(of:)` must return `nil` rather than crash for exactly this reason, and by
Phase 4 a project holds several recordings, each with its own epoch, so the question comes up by
construction. The split is deliberate: trap where a mismatch can only be a programming error, return
`false` where a caller legitimately asks across epochs. `HostRange.isComparable(with:)` exists so a
caller that needs to know *which* of those two cases produced a `false` from `contains` can ask
directly instead of inferring it.

The closest existing precedent for the `false`-not-trap side is `ReverseIndex.dependents(of:)`, which
also returns empty rather than trapping when asked about something it cannot currently answer for —
but the analogy is imperfect and worth stating precisely: `ReverseIndex` is signalling the staleness
of a cache, a temporal condition that resolves once the index is rebuilt. `HostRange.contains` is
signalling that two identities never matched and never will; nothing rebuilds it into a match. Both
choose `false` over a trap because the caller's question is legitimate to ask, not because the two
absences mean the same thing.

So it belongs in `Timeline` — the second leaf module, symmetric with `Geometry`. Not a new invention;
a pattern this project already proved, applied to the axis it was not applied to.

### Identity and anchor are two different things and must not be one field

**`kern.boottime` is not an identity.** It is computed as *now minus uptime*, so it moves when the
system clock is corrected by NTP or by hand — two reads in the same boot can disagree. Used as a
boot identifier, one NTP correction makes a single boot look like two.

**`kern.bootsessionuuid` is.** Verified on this machine: present, and identical across three
consecutive reads — `6495B81D-14D1-4E05-8851-DD30BE41D757`. `kern.uuid` is the hardware, stable
across boots; `kern.bootuuid` is a third, different value. Use `bootsessionuuid`.

Two fields, two jobs:

- **epoch identity** — `kern.bootsessionuuid`. Its only job is the comparison guard: comparing
  timestamps across epochs is a precondition failure, exactly as with `GeometryRevision`.
- **anchor** — a `(host time, wall clock)` pair, for display and rough placement.

**The anchor's wall clock has no ordering authority, and this must be written down.** Wall clock
runs backwards under NTP correction. Segment order is recorded explicitly in the document. Without
the sentence, someone will sort by it.

A cross-check fell out of the same reading: `kern.boottime` says Jul 26 against today's Aug 2, about
7.2 days, which matches the `mach_continuous_time` figure of 172.57 h and not the
`mach_absolute_time` figure of 112.89 h. D2-4's sleep measurement, confirmed from an independent
direction.

### It changes `EvidenceRef`, and now is when that is cheap

`EvidenceRef.sourceInterval: TimeRange?` — **on which timeline?** By D2-12 Q1 the log stores host
time only, so the interval is host time, which has just been shown to be meaningless without an
epoch.

| Option | Consequence |
| --- | --- |
| `sourceInterval` carries the epoch | `EvidenceRef` changes — a Phase 1 type, built and tested in Task 12 |
| it inherits the epoch from the observation its `id` points at | `sourceInterval` becomes a **convenience copy** that can disagree with the observation's own epoch |

The second is the failure D-P4 rejected side tables for: two records of one fact, drifting apart in
silence. So the epoch goes in.

`EvidenceRef` has **zero non-test callers** — verified by grep across `Sources/`, `Soredemo/` and
`scripts/`. Changing it costs a type edit and its tests today. In Phase 4, with producers writing
citations, it costs a migration.

## D2-12 — The observation log

**Q1. The log stores host time only.** Content time — the gapless concatenation of segments that the
exported video runs on — is *derived* from host time plus the segment table. Storing it in the log
would put a derived value in the evidence layer, which is the rule D2-1 established for element
choice. Same rule, different subsystem.

This makes D2-11 load-bearing rather than incidental: host time is now the only timeline stored, and
it is the one with the epoch problem.

**Q3. One log file per segment.** The master is a sequence (D2-9), so the boundary becomes
structural rather than implicit, and a crash damages only the current segment's log — `JSONLReader`'s
truncated-tail rule then has exactly one file it can apply to.

An observation may straddle a boundary: the click at *t*, its AX chain still being read at *t+30 ms*,
the boundary at *t+15 ms*. **It belongs to the segment the click happened in** — the click is the
anchor and the chain is its attribute. And because each chain item carries its own timestamp
(D2-2a), a chain extending past the boundary is *detectable*, which is one more real input for
`framing-gates`' `observation stale`.

**Gaps are records, not absences.** A segment boundary is written with why (pause, display
reconfiguration, crash recovery) and what changed (the new `geometryRevision`). Third instance of
the rule after `SCFrameStatusIdle` and chain truncation: *nothing happened* and *we were not told*
must not be the same bytes.

**Q4. One table defines every version line, and it lives in one place.**

This project has already paid three times for a version number restated in several documents — the
same wrong `tools-version` in three files. Adding a fifth line without a single definition point is
inviting the fourth. Existing lines, from the code:

| Line | Scope |
| --- | --- |
| `CanonicalEncoding.version` | the digest encoding; changing it invalidates every stored approval |
| `ProjectSnapshot.currentSchemaVersion` | the document format |
| `Derivation.producerVersion` | per producer, so a derivation can be re-run when a producer improves |
| `ObservationLog.schemaVersion` | **new** — the on-disk log |
| toolchain (compiler 6.4, tools 6.3, deployment 26.0, SDK 27.0) | `ARCHITECTURE.md` D2's four, a different family |

They move independently, and the table is the only place that says so.

---

## D2-13 — Window capture: the window's frame is extrinsic, exactly like the display arrangement

`capture-source` allows capturing a window rather than a display, and a window moves and resizes.
`DisplayGeometry`'s digest is `(displayUUID, pixelWidth, pixelHeight, scale)` and has no field for
that. The answer is a pattern already decided in Phase 1, not a new one.

D-P2 already ruled on the same shape:

> **Global arrangement must stay out.** … `CGDisplayBounds` origins shift when the arrangement
> changes … so rearranging display B would silently invalidate footage from display A.

**A moving window is a moving display arrangement.** It changes constantly, it does not change the
captured surface, and digesting it would mint a new revision on every drag — the exact failure
D-P2 rejected.

| | Display capture | Window capture |
| --- | --- | --- |
| **Intrinsic** — in the digest, defines the revision | `displayUUID`, pixels, `scale` | source identity + **output buffer size** + `scale` |
| **Extrinsic** — never digested, applied at the capture boundary | the global origin, via `DisplayArrangement` | the window's current screen frame |

The pivot is that **the output buffer's size is fixed for the whole recording** — it has to be,
because a QuickTime track cannot change dimensions mid-track (D2-9). So the basis for normalisation
is the *captured image*, not the window's frame on screen. What varies is the mapping from screen
coordinates into that image, which is extrinsic and belongs beside `DisplayArrangement.route`.

**So dragging a window does not mint a revision**, and D2-10's single trigger — display
reconfiguration — still holds.

### Resizing is the real question, and it is measurable rather than arguable

When the window is *resized*, the output buffer stays the same size but the content maps into it
differently.

- If ScreenCaptureKit **scales to fill**, `(0.5, 0.5)` is still the window's centre and normalised
  coordinates stay comparable across the resize — no new revision needed.
- If it **letterboxes**, changing the window's aspect ratio moves the bars, so `(0.5, 0.5)` points
  at something different — and that does need a new revision.

Record a window, change its aspect ratio mid-recording, and see whether content shifts within the
frame. Folded into `capture-source`'s implementation rather than run as a separate spike, for the
reason D2-10 gives: the answer arrives while there is code in hand to act on it.

### Genuinely open: a window has no stable identity

Source identity cannot be dropped — two same-sized buffers capturing *different* windows is the
"two identical monitors side by side" case D-P2 kept display identity for.

But `SCWindow.windowID` is not stable across a restart of the target app, and bundle identifier plus
window title is not stable either. D-P2's second property — *"two sessions that shared a display
agree without coordination, which `selective-rerecord` (Phase 4) needs"* — is one that window
capture currently cannot provide.

The likely conclusion is that **a window-capture revision is session-scoped**, stated as an explicit
limitation rather than discovered. That has to be checked against `selective-rerecord`'s actual
requirement before it is written down, and that row is in Phase 4.

---

## D2-14 — Decode validation splits by failure semantics, and a rule stops the next one

Ten public types validate in their initialiser and take synthesised `Codable`, which never calls it
(`AGENTS.md`). The exposure is live: `ProjectPackageIO` decodes `ProjectSnapshot` today, reaching
`DisplayGeometry`, `NormalizedFrame`, `Evidence`, `Authorship` and `TimeRange`, and a `.soredemo`
package is a shareable document whose contents `agentic-threat-model` treats as attacker-influenced.

### Correction: the grouping criterion, and the reachability

Two things in the first draft of this section were wrong.

**The criterion is not which reader reads the type.** A type's `init(from:)` always throws. Whether
that becomes a fatal document error or a discarded record counted in `droppedBytes` is the
**reader's** policy — one type, one behaviour, two call-site policies. So what waits for Task 11 is
the log reader's catch policy, which does not exist yet, and not the types themselves. What makes a
type ready now is that **its invariant is settled**: `HostInstant`'s is not — whether an epoch
mismatch makes an instant invalid is a Phase 2 question still forming — and that, not its reader, is
why it waits.

**And the reachability was asserted rather than traced.** Traced structurally, exactly **two** of the
ten are reachable from `ProjectSnapshot`: `DisplayGeometry` via `GeometryRegistry`, and `HostRange`
via `SegmentTable` → `MasterSegment`. The other eight are not — `Derived` is not in
`ProjectSnapshot`, which `ROADMAP.md`'s `derivation-graph` row already stated. Several of those
eight, notably `PixelRect` and `PointRect`, are conversion types that may never be persisted at all.

They belong in a third group the first draft did not have: **no decode path**. Closing them now is
designing error handling with no caller.

### Why this splits at all, and it is not "wait for a caller"

An earlier draft deferred all ten to Task 11 on the grounds that designing error handling without a
caller is what left `project-format` at ◐. That reasoning does not apply — most of these already
have a caller. The real reason to split is that **the two groups fail differently**:

| | manifest (`project.json`) | observation log (`.jsonl`) |
| --- | --- | --- |
| one bad record | **fatal** — the document does not open | possibly **discardable**, counted in `droppedBytes` |
| rule already in place | none | the truncated-tail rule already says "drop it and report" |

A single error policy over both is wrong in one direction or the other: either one bad observation
destroys a document, or a corrupt manifest is quietly accepted in part.

So:

- **Now** — the types reachable through `ProjectSnapshot`. They have callers and their failure
  semantics are already settled: fatal, `throw`, never `precondition`. A `precondition` on decoded
  input is the wrong instrument regardless — it turns a corrupt file into a crash instead of an
  error.
- **Task 11** — `HostInstant`, `HostRange` and the observation-record types. Whether one malformed
  record is discardable or fatal is a question specific to an append-only log, and Task 11 is where
  the log is first read back.

`SegmentTable` is in the first group and was closed in Task 4's fix round.

### Architecture rule 8, which matters more than the ten

Fixing ten types is stock. The rule is flow, and **Phase 3 will produce a large batch of new derived
types, every one of which will have a validating initialiser.**

It is text-scannable, so it belongs in `Plugins/ArchitectureCheck` beside rule 2, which already
scans package sources:

> A type that has an initialiser which `throws` or contains a `precondition`, **and** conforms to
> `Codable` or `Decodable`, **and** has no explicit `init(from decoder:)`, is a violation.

Two details learned from getting the scan wrong once already: conformance may be declared on an
**extension** rather than the declaration line, and so may `init(from:)`. Scan the whole file for the
type, not one line of it — the first attempt missed `GeometryRegistry`, `ContentDigest` and
`Evidence` for exactly that reason, and only survived because all three were closed.

**The ten existing cases are the rule's negative-test fixtures.** No fixture has to be invented, and
each one closed is a fixture that must be removed from the expected-violation list — which makes the
list a live record of the remaining work rather than a comment.

---

## D2-15 — The master's colour space must be pinned, and the tag must match the data

A third independent reason for `AVAssetWriter`, and a problem neither comparable project has to
solve.

### What the two comparable projects do — read from the checkouts, verified

| | `colorSpaceName` at capture | tag written to the file |
| --- | --- | --- |
| `a Swift recorder` (208 Swift files) | **never set — zero occurrences** | user-selectable: `AVVideoColorPrimaries_ITU_R_709_2` / `_P3_D65` / `_ITU_R_2020`, set at write time in `ExportEngine+Helpers.swift` |
| `a Rust recorder` (596 Rust files) | never set | **hardcoded 709/709/709**, `crates/enc-avfoundation/src/mp4.rs:330-332` |

Both tag at **write** time, not at capture. That is the lever, and `SCRecordingOutput` does not
expose it.

Worth copying as an approach, not as code: a Swift recorder's `RenderSettings.swift:429` returns
`AVVideoTransferFunction_ITU_R_709_2` for **every** colour space — the return sits outside the
switch — and the matrix is 709 for all but BT2020. That is Apple's standard way of tagging P3
video; there is no "P3 transfer function" to pair with P3 primaries in this context. Only the
primaries change.

### The SDK default reframes the question

`SCStreamConfiguration.colorSpaceName`: *"If not set the output buffer uses the same color space as
the display."*

So the default is **not sRGB — it is display-matched**. Neither project setting it means both
already capture in P3 on a P3 display, and a Rust recorder then tags that data 709. Data and label disagree by
default, on the default path.

For a project whose master is a piece of material, that is a quality bug. **For a project whose
master is evidence it is worse**, and in a different way: it makes the master's colour space
*machine-dependent*. The same demo recorded on two Macs carries two different colour meanings, and
nothing in the file says which. That is the shape `GeometryRevision` exists for, on the colour axis.

### The decision

**Pin the capture colour space and record it, rather than inheriting the display's.**

```
capture:  colorSpaceName = <pinned>            the pixel data's gamut is a known quantity
file tag: AVVideoColorPrimaries matching it    label and data agree
          + 709 transfer + 709 matrix          per Apple's convention above
```

`SCRecordingOutput` cannot write the second half. `AVAssetWriter` can. So the reasons to reject
`SCRecordingOutput` now number three, and they are independent:

1. audio cannot be separated — measured, F2-4
2. the colour tag cannot be controlled — this section
3. both comparable projects use `AVAssetWriter`, both for output-tag control

**Which colour space to pin is not settled here.** P3 preserves more of what was on screen and is
what a modern Mac display actually shows; sRGB is what most viewers of the exported video will have.
The evidence argument favours capturing wide and narrowing at export — the same "record everything,
judge in derivation" rule as D2-1 and D2-7 — but that needs measuring, not asserting.

### Not measured, and it should be before this is implemented

- **What `SCRecordingOutput` actually tags.** Spike B's output was deleted after its audio question
  was answered, and its colour tags were never read. The claim above that data and label disagree by
  default is inference from the SDK comment plus a Rust recorder's hardcoding, not observation here.
- **What this machine's display colour space is**, which determines what "the default" means on the
  one machine currently doing the measuring.
- **Whether a P3-tagged master survives the compositor and export unchanged.** D2-6 requires parity
  to compare the compositor's output buffer *before* colour management; a pinned wide-gamut master
  is exactly the input that would expose a working-space mismatch there.

One recording answers all three. Fold it into `capture-stream` rather than a separate spike, per the
reasoning in D2-10: the answer arrives while there is code in hand to act on it.


---

## D2-16 — The banned-symbol enumeration stays, and here is the measurement that settles it

Rule 3's list of banned symbols was found stale **three times in one session**, each time by someone
specifically asked to look for gaps:

| Missing | Present | Shape |
| --- | --- | --- |
| `mach_continuous_time` | `mach_absolute_time` | sibling, added the same day by the same author |
| `SecRandomCopyBytes` | `arc4random` | same category, different API |
| `NSUUID` | `NSDate` | sibling, and `NSDate` is already banned as *any reference* |

Task 5.5's sweep then found four more that are verified and still open: `NSUUID` on both sides,
`CCRandomGenerateBytes` app-side, `clock()` package-side, and `drand48()` package-side.

Three findings by three different people is not a mechanism. So the structural alternative was
tried: **scan undefined symbols by pattern instead of by name**, which cannot go stale.

### It does not work, and the numbers say why

```
undefined symbols across six library modules      575
pattern hits: random|clock|uuid|entropy|arc4|time   9
of those, actual ambient reads                      0
```

All nine are `Foundation.UUID`'s **type metadata and protocol conformances** — `BootEpoch` has a
`UUID` field, so `Timeline` legitimately references `UUID`'s metadata, its `Codable` witnesses, its
`==`, its byte accessor. `Date` produces nine more of the same kind.

A pattern scan cannot separate *referencing a type* from *calling an ambient constructor on it*.
Naming specific mangled symbols is precisely what does separate them — so the enumeration is not
laziness, it is the thing doing the work.

**And a false positive is worse than a stale entry in a check that fails the build.** A rule that
cries wolf gets disabled; a rule with a gap gets extended. Recorded so this is not re-proposed:
it was tried, measured, and rejected on the measurement.

### What actually helps, given that

- **A sibling check when a symbol is added.** Every one of the three staleness findings was a
  sibling of something already banned. That is a review question — *what is the obvious neighbour of
  what you just added* — not a mechanism, and it would have caught all three.
- **A recorded candidate list, including what was ruled out and why.** Task 5.5's sweep confirmed
  `getentropy` is not exposed to Swift on this toolchain by compiling a probe. Writing that down
  saves the next sweep the experiment, and the value of a sweep is mostly in its negatives.
- The file already over-approximates where it can: `_OBJC_CLASS_$_NSDate` is banned as *any
  reference*, because for an ObjC class any reference is suspicious. That is the pattern approach
  applied exactly where it does not produce false positives.

---

## D2-13a — Window capture: option D, and the open question was never one

D2-13 left the scale-to-fill versus letterbox behaviour open and scheduled a recording to settle it.
**The header settles it, and a recording was never needed.** This is `AGENTS.md`'s read-the-primary-
source rule costing five minutes instead of an afternoon, for the second time in this phase.

```
scalesToFit           macos(12.3)  "When true, the output scales up and down.
                                    When false, the output only scales down."
preservesAspectRatio  macos(14.0)  "By default the aspect ratio is preserved."
sourceRect            macos(12.3)  subset of the frame INPUT, in points
destinationRect       macos(12.3)  subset of the output IOSurface, in pixels
```

Letterbox versus scale-to-fill is a flag with a documented default, not emergent behaviour.

### The decision: a display-sized buffer, `scalesToFit = false`

Four options were weighed. Two collapse:

**"Do not support resizing mid-recording" is not a design, because it cannot be implemented.** You
cannot stop a person dragging another application's window. So it becomes one of: abort the
recording (hostile), warn and continue (and then what), or leave it unhandled — and the third is
what would actually ship. That is undefined behaviour, which is the shape this project spends its
time eliminating: the recording is silently wrong and nothing says so.

**And it is the same architecture as option D anyway.** Both are `scalesToFit = false` with
`preservesAspectRatio = true`; they differ only in how large the buffer is. Sized to the window's
current dimensions, growing the window exceeds the buffer and "only scales down" means it is
resampled. Sized to the display, that happens only if a window exceeds the whole display.

So **D strictly dominates**: same complexity, same single segment, and the master is unresampled in
strictly more cases. Its cost is buffer size, and the padding is flat black, which H.264 spends
almost nothing on — and a display-sized `IOSurface` is what display capture allocates regardless.

### The time-varying mapping is not a new mechanism

Padding means normalised coordinates are against the **buffer**, not the window, and the mapping
from one to the other changes whenever the window is resized. That is D-P2's intrinsic/extrinsic
split applied to windows, not a new problem:

| | Window capture under D |
| --- | --- |
| **intrinsic** — digested, defines the revision | buffer size, scale, source identity — **fixed for the whole segment** |
| **extrinsic** — never digested | the window's rect within the buffer — varies |

One revision per segment. No `windowResized` case on `SegmentBoundary`. Nothing new.

### And the extrinsic part arrives per frame, from the API

The mapping does not have to be computed, sampled at click time, or reconstructed later. Every
sample buffer carries it:

| Attachment | What it gives |
| --- | --- |
| `SCStreamFrameInfoContentRect` | content's size and location **in surface coordinates**, per frame |
| `SCStreamFrameInfoScreenRect` | the same content's on-screen location |
| `SCStreamFrameInfoContentScale` | the scaling factor **from original content size to its size in surface** |

`ContentRect` is exactly the field a click observation would otherwise have to carry, delivered
already and for every frame rather than only at clicks.

**And `ContentScale` turns "the master is unresampled" into a measurable claim.** A frame whose
content scale is not 1 *was* resampled. That is checkable per frame, so the property this whole
decision exists to protect stops being a design intention and becomes something the recorder can
assert — and record when it fails, rather than letting it happen quietly. Which of the two it does
belongs with `capture-stream`.
