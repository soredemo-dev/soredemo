# Test strategy

*Written 2026-09-04, from a census of what this repository actually runs rather than from
a template. Every number below was measured; where a level is empty it says so.*

This document says what each level of testing owns, what it must never own, and what
has to be true before a change ships. It is written to be argued with: a rule here is
wrong the moment the measurement under it changes.

---

**How to decide what to write is a separate document.** `DESIGNING-A-TEST.md` carries the
method — risk first, then partitions and boundaries, then the oracle question, then the
size — with this project's own defects as the worked examples. This document is the
inventory; that one is the technique.

## 0. The number, and what it does not say

*Measured 2026-09-28 by `scripts/coverage.sh`, which is also the gate: it fails below 70%.*

```
  Capture          5636 lines   42.4%
  Compositing      5447 lines   81.3%
  Graph             245 lines   89.4%
  Geometry          550 lines   90.7%
  CheckerLexer      226 lines   93.8%
  Variants           71 lines   95.8%
  Render           2043 lines   95.8%
  Project          1000 lines   96.0%
  Timeline          675 lines   96.3%
  Overlays         2265 lines   97.1%
  Framing           723 lines   98.2%
  TOTAL           18881 lines   75.69%
```

**Every figure this gate printed between 2026-09-15 and 2026-09-28 was read through the wrong
binary.** The toolchain stopped building the combined `SoredemoCorePackageTests.xctest` and
builds one bundle per test target; the combined one from 2026-09-15 stayed in the build
directory and the script, which took the first it found, kept reading today's counters through
its thirteen-day-old map. Files added since were absent, files deleted since were present, and
the export path every export test runs read as 18% covered. The numbers stayed between 70 and
73, so nothing looked wrong; it was found because the report said `MP4Exporter.export` never
ran while a function only `export` calls ran twice. The script now reads every test target the
manifest names, and fails when a source on disk is missing from the report or a file in the
report is not on disk — the check that would have caught it on the first day.

**`Capture`'s figure — under half — is the one to read carefully, and it is not what it looks like.** It
is the module whose behaviour needs a real display, a real `SCStream` and a real writer, so
most of its checking lives in the probe and runs as a separate binary — 473 checks that this
report cannot see. Merging the two profiles was attempted: instrument the library, keep the
probe's binary, merge the profraws. `llvm-cov` would not attribute the probe's run to
`Capture`'s sources, because the archive it links comes from a different invocation than the
one carrying the coverage mapping. A merge that silently contributes nothing is worse than no
merge, so it was taken back out and this paragraph exists instead.

**What the number excludes on purpose**: the app target. The probe COMPILES every app source
to check that it compiles, so leaving those files in the report would put 17,764 lines in the
denominator that nothing in this run executes. The app tier has its own tests and its own
figure — § 5.4.

**Coverage is a floor here, not a target.** A line can be covered by a test that asserts
nothing about it; `DESIGNING-A-TEST.md` § 1 is what decides where tests go, and this number
is what stops a module quietly falling out of the habit.

## 0.5 What macOS 27 changed, measured rather than assumed

*2026-09-15, the morning after the upgrade. Every number this project had was taken on
macOS 26; none of them had been re-taken, and a baseline nobody re-measures is a baseline
that quietly stops describing the machine.*

| baseline | macOS 26 | macOS 27 | |
|---|---|---|---|
| 1080p frame | 3.61 ms | **2.5 ms** | 31% faster |
| 4K frame | 8.69 ms | **7.2 ms** | 17% faster |
| recording peak memory | 94 MB | **101 MB** | +7%, slope still ~0 |
| `contextualStrings` biasing | no effect | **no effect** | byte-identical |

**The budgets came down.** 12 ms and 25 ms were three times the old medians; against the new
ones they had become 4.8x and 3.5x, and a budget a regression can hide inside is not a budget.
They are 8 ms and 22 ms now.

**The first two runs after the upgrade were wrong, and how they were wrong is the lesson.**
They said 4.87 and 4.73 ms — a regression — on a machine that had just finished a full build.
The next two said 2.61 and 2.47. The evidence that settled it was not repetition alone: the
fastest FRAME had got *faster* (2.54 → 2.29) while the median got slower, which is a
distribution widening under load and not a compositor slowing down. **A measurement taken
straight after a build is a measurement of the build.**

## 1. What exists today, counted

| level | assets | size | verdict |
|---|---|---|---|
| Unit — pure tier | 1,722 tests, 14 targets | 27,123 lines of `Core/Sources` | **strong** |
| Unit — app tier | none that execute | 13,761 lines of `Soredemo/` (33% of the codebase) | **absent** |
| Static analysis | `ArchitectureCheck` plugin, `AppSourceTests` (71 scans), `CheckerLexer` | whole repo, both build paths | **strong** |
| Integration | `cross-boundary-digest-probe.swift` — 7,500 lines, 473 checks, 23 sections | real display, real files | **strong, and mislabelled** |
| UI | none — the Xcode project has no test target at all | — | **absent** |
| Performance | `CameraMotionTests` + `FrameTimeBudgetTests` (frame time, and the 4K:1080p ratio) | compositor only | **started 2026-09-05** |
| Memory | probe § 28: a real recording's footprint, slope asserted | 1280×800 only, 20 s only | **started 2026-09-05** |
| Compatibility | one OS floor (macOS 26), no architecture matrix, no rendered-locale check | — | **absent** |
| CI | none. The four gates are run by a person | — | **absent** |

**The single most misleading thing about this repository's testing is that the
integration suite is called a script.** `scripts/cross-boundary-digest-probe.swift`
opens a real `SCStream`, drives the event tap with synthesised `CGEvent`s, SIGKILLs the
writer mid-recording to produce a genuine crash, appends from many threads at once,
decodes real `AXValue`s, composes a synthetic movie through `StageCompositor` and reads
it back, and compares two implementations' **finished files** rather than their
intermediate values. Any census that counts test targets concludes this project has no
integration tests. It has more of them than most.

---

## 2. The levels, and what each one owns

The rule that decides which level a test belongs to is **what it is allowed to be wrong
about**.

### L0 — Static (the plugin, `AppSourceTests`, `CheckerLexer`)

Owns claims about the SHAPE of the source: the import allow-list, no package
dependencies, no `CGRect` outside the bridge, every decodable validating in
`init(from:)`, no competitor named in the source, no comment block long enough to be a
document, every control label present in all ten string tables.

**Must never own behaviour.** A scan proves a name is absent, never that a function is
right. Every scan here states that limit in its own words, and it should keep doing so.

### L1 — Unit (pure tier)

Owns every decision that can be made from values alone: geometry, timelines, framing
gates, caption breaking, loudness, colour, the graph. No clock, no filesystem, no GPU,
no platform framework — which is also `ARCHITECTURE.md`'s D6 rule 3, so the tier and
the level are the same boundary.

**A unit test that needs a display is in the wrong level.** Move the decision into the
pure tier instead of moving the test up — that is what happened to
`CaptionTrack.index(steppingFrom:by:)`, whose interesting case (a playhead in a gap
between cues) could not be tested while it lived in a SwiftUI view.

### L2 — Component (the "headless" partition: `CaptureTests`, `CompositingTests`)

Owns one subsystem against the real frameworks: a real `AVAssetWriter` round trip, a
real Metal render, a real transcription. 596 of the 1,722 tests. `count-tests.sh
--split` keeps the count of this partition separate from L1's **because they answer
different questions and reporting one number would make a GPU-dependent pass look like
a deterministic one**.

### L3 — Integration (the probe)

Owns everything that crosses a boundary this process does not control: the window
server, the accessibility API, the event tap, the file system under a crash, another
implementation's file format. Runs against a real display and cannot run headless.

**This is where a failure means the product loses somebody's recording**, so it is
where the expensive, awkward, one-off scenarios belong — SIGKILL mid-write, a truncated
log tail, concurrent appends, secure input.

### L4 — UI

**Empty, and this is a decision rather than an omission.** XCUITest against a SwiftUI
menu-bar app with a non-activating panel and a system picker is expensive to write and
brittle to keep. The scenarios it would cover are already covered at L3 or by L0's
label scans.

What is NOT covered and would justify the cost is exactly three flows, listed in §6.

### L5 — Non-functional

Performance, memory, compatibility. Empty today. §5 is the whole of it.

---

## 3. Release gates

Run **sequentially** — several clean and rebuild `.build`, so two at once delete each
other's work and look like a hang.

| | gate | exit criterion | typical |
|---|---|---|---|
| 1 | `scripts/count-tests.sh --split` | every test passes AND the two populations partition the suite exactly | ~4 min |
| 2 | `scripts/check-strict-memory-safety.sh` | zero unmarked `unsafe`, clean compile | ~2 min |
| 3 | `scripts/run-cross-boundary-probe.sh` | 473 checks, zero skipped without a named reason | ~2.5 min |
| 4 | `xcodebuild -scheme Soredemo` | builds | ~2 min |
| 5 | `scripts/run-app-tests.sh` | every app-tier test passes | ~2 min |
| 6 | `scripts/check-editor-opens-full-screen.sh` | AppKit says the editor window is full screen | ~1 min |
| 7 | `scripts/coverage.sh` | line coverage at or above the floor | ~4 min |
| 8 | `scripts/check-the-bar-can-be-dragged.sh` | the recording bar moves when dragged | ~1 min |

**The partition check in gate 1 is the load-bearing part.** Two filtered runs could
double-count a suite or drop one and both numbers would still look plausible; only the
sum says the split is a split.

**In zsh, `./script | tail` reports `tail`'s exit code.** `$pipestatus[1]` is the one to
read.

**Gate 1 hangs rather than fails, sometimes.** `count-tests.sh --split` has no
`--no-parallel` flag and must not grow one; when it hangs — CoreMedia's own workers idle at
0% CPU — run the four filtered runs by hand with `--no-parallel` and check the sum yourself.
Observed again 2026-09-16 at forty minutes on `CompositingTests`. See the next section.

**Gate 6 says which ending it hit.** `fullScreenStopped=` in its report is `arrived`,
`exhausted`, `windowNotVisible`, `asking` or `notAsked`, and `fullScreenAsks=` is how many
times it asked. Before those existed the failure listed four causes and named none, so a red
was classified by re-running until it went green — five launches on 2026-09-16. The frame is a
second reading: an exhausted budget still leaves a GROWN window, measured at 1512x865, so a
report carrying the un-configured 900x492 default is an editor window that was never set up at
all, which is a different defect.

### Known flake, and the rule about it

`swift test` in PARALLEL intermittently **hangs** on concurrent `AVAssetReader`s —
`copyNextSampleBuffer` blocking in `FigSemaphoreWaitRelative` with CoreMedia's own
workers idle. Confirmed a pre-existing platform defect against a stashed tree; two
hypotheses were falsified by measurement before that conclusion was reached.

`--no-parallel` passes reliably. **`count-tests.sh` has no flag to pass it through, and
the gate must not be widened to make it pass** — run the three filters by hand and check
the sum.

A separate intermittent **failure** (not a hang) was diagnosed as this and was not: a
test wrote `SystemCursorArtwork.byShape`, a static read on every frame's cursor path,
while two other tests rendered cursors. Fixed by giving the renderer a per-instance
override. **The rule that came out of it: a red gate is a HANG or a FAILURE, and which
one it is decides whose defect it is.** Never file the second as the first.

**A fifth kind, found 2026-09-15: a gate whose failure could not be read.** `xcodebuild`
reports an infrastructure failure as `Testing failed:` and nothing else, and the gate
scripts piped that through a `grep` that kept only lines matching `error:|failed` — so the
verdict was "APP TESTS FAILED" with no evidence under it. The same run succeeded when
issued by hand. Three separate readings were needed to establish that the gate was fine and
the intermittency was in the test host, and one of those readings was itself wrong: a
hand-typed `grep "Test Case"` against output that says `Test case` reported zero tests run.

Every gate script now writes its whole run to a file and names it on failure, which is the
same repair the probe had on 2026-09-15. **A gate that cannot show its evidence sends
somebody back to re-run it, and an intermittent failure that is re-run instead of read
becomes a rumour.**

**A fourth kind, found 2026-09-10: a red check pointing at the wrong file.** The probe asks the
window server to put its window at x = 700 and then derives a `CaptureSource` from a filter over
it. One run in several, the placement is not honoured — observed at x = 2094, past the right edge
of the only display — and `CaptureSource.init(pickerFilter:)` then correctly returns nil, because
it refuses a window no display hosts. The probe reported that refusal as "CaptureSource does not
derive a .window from a window-style filter", and the seven checks after the `guard`'s `return`
silently stopped running, so the total dropped from 473 to 466 with nothing saying why.

It took a stashed-tree comparison to establish the failure was not in the working tree at all.
**A red check pointing at the wrong file is worse than no check**, because somebody spends an
afternoon in that file. The placement is now asserted by name and the remainder skipped with the
reason printed. This is the same shape as the empty-file and absent-title defects: **a fact about
the setup stated as a fact about the thing under test.**

**And a third kind, found 2026-09-07: a gate reported green that was not.** Five tests were
red at `e10c57d` and reported as passing. Four were real house-rule violations that had been
introduced with the files that broke them; the fifth,
`theContinuousClockIsNeverBehindTheHostClock`, was a test whose stated reasoning was backwards
and which fails deterministically on a machine that has not slept since boot. None of them are
flakes and none of them were the Apple hang. The rule: **a gate's verdict is the line it
prints, read after the run, not the run one remembers starting.**

Three of the four also say something about the scans themselves. `noAppSourceReadsAnAmbientValueAtAll`
fired on `retime(at:start:end:)` because its needle `time(` was documented as "close to
unwritable by accident"; `noAppSourceReadsKeystrokeText` fired on a caption's character count
because `.characters` was relied on as a prefix for `.charactersIgnoringModifiers`. A scan that
cries at a caption nudge is a scan somebody eventually silences — so both needles were made to
mean the symbol they were written for (a boundary rule, and both AppKit spellings named), which
is the opposite of a permit. The two copies of the matching loop that had to be edited to do it
were themselves the reason one of them had drifted.

---

## 4. Test data

| fixture | what it is | why it is committed |
|---|---|---|
| `HeadlessFixtures/segment-00-redacted.jsonl` | a real observation log, 411 records | the log's own format, and a crash-truncated tail |
| `RenderParityFixtures/*.mov` | 204 KB of synthetic movies | two-track audio, a long two-track case, a two-tone signal |
| `generate-fixture.swift` | how they were made | a fixture nobody can regenerate is a fixture nobody can change |

**Titles are redacted from committed logs** by `redact-observation-log.swift`, and this
has a consequence worth stating because it has already misled a reading of that file:
`title: null` there is redaction, not measurement. A statistic about how often clicks
are nameable **cannot** be taken from a committed fixture — see `scripts/ax-coverage.py`,
which is meant to be run against an unredacted log on the machine that made it.

**Rule:** a fixture is either generated by a committed script or accompanied by the
measurement that produced it. Binary blobs with no provenance are not evidence.

---

## 5. What is missing, with budgets

Each of these is written as a number so it can fail. A non-functional test with no
threshold is a benchmark, and a benchmark that nobody fails is decoration.

### 5.1 Memory — the highest-risk gap

A recorder that leaks over thirty minutes produces a failed recording, and
`RecordingHealth` exists because that risk is real. Nothing measures it.

**Measured 2026-09-05**, probe § 28: a real `SCStream` over the probe's own window
through the real `CaptureSession` and a real writer, 1280×800 at 60 fps, sampled every
250 ms for twenty seconds while the window is repainted so the stream is producing
frames rather than idling.

| run | peak | settled slope |
|---|---|---|
| 1 | 116 MB | +0.9 MB/min |
| 2 | 115 MB | +0.5 MB/min |
| 3 | 116 MB | −0.1 MB/min |

**The slope is asserted and the peak is only reported**, at `< 30 MB/min` — roughly a
gigabyte an hour, which is where a long recording starts being at risk on a machine
also running the thing being demonstrated. A recorder that sits still at any reasonable
figure is fine, so no ceiling is asserted: a twenty-second sample cannot support one.

The slope is fitted after a **five-second settling window**. The first seconds carry the
writer opening its file and the first pixel buffers being allocated — a cost paid once,
and a fit through them would report start-up as a leak.

**What this does NOT establish, said plainly:**

| | why not |
|---|---|
| Behaviour at 4K60 | measured at 1280×800; the buffer pool is the dominant term and it scales |
| Behaviour over 30 minutes | twenty seconds catches a fast leak. A slow one — 2 MB/min — is inside the noise here and would still cost 3.6 GB in half an hour |
| Export peak | not measured at all |
| `HeldAudioQueue` under a stalled writer | it holds ~8 s by design; nothing asserts it does not exceed that |

The 30-minute case is the one that matters most and the one a gate cannot hold: gate 3
runs in about two minutes and a five-minute memory section would quadruple it. It
belongs in a soak run that is not a gate — named here so it is a known gap rather than
an assumed pass.

### 5.2 Performance

**Re-measured 2026-09-15 on macOS 27** — see § 0.5 for why, and for the two runs that were
wrong first. `FrameTimeBudgetTests`: sixty renders after a five-render warm-up, a card over a
background with a cursor mid-ripple, because a frame with nothing on it measures the cheapest
case and the cheapest case is not the one that stutters.

| | median | p90 | p99 | budget |
|---|---|---|---|---|
| 1920×1080 | **2.5 ms** | | | median < 8 |
| 3840×2160 | **7.2 ms** | | | median < 22 |
| 4K ÷ 1080p (min ÷ min) | **2.3×** | | | < 4× |
| 3492×1964 | **7.13 ms** | 10.29 | 12.33 | not asserted — see below |

The ratio is **min ÷ min**, not median ÷ median, and the test's own header says why: the two
sizes are timed one after the other, so a burst of load lands on one and not the other. Re-taken
2026-09-16 at 2.31x on a machine that had just compiled — which is exactly the case the minimum
is chosen for, and why that run's medians (3.98 and 8.72) are not in the table.

The last row is one recording's own size rather than a standard one, taken while answering
"why is the editor lagging". It is reported and not asserted: a budget exists to catch a
regression in a shape the product actually renders, and two sizes already pin the curve the
ratio row is about. It is here because it is the number that showed the compositor was *not*
the problem.

The budgets are about **three times** the measured medians, and that looseness is
deliberate: this runs on whatever machine a person has, beside a full Xcode, and a
budget tuned to one laptop fails on the next for a reason that has nothing to do with
the code. Three times is far more than scheduling noise and far less than an
algorithmic regression — which is the only thing a budget like this can honestly claim
to catch.

The proposals this table replaced were 16 ms and 33 ms, taken from the frame durations
at 60 and 30 fps. **A fourfold regression would have passed both.** A budget nothing can
fail is not a budget, which is the argument for measuring before setting one.

**The median is asserted and the tail only reported**, for § 5.1's reason: a single slow
sample on a machine also compiling something is scheduling, not the compositor.

**The RATIO is the assertion that survives a change of machine.** A compositor whose
cost went linear in pixels would still pass both absolute budgets on a fast Mac while
being wrong; 4K costs 2.4× 1080p today for four times the pixels, and above 4× it has
stopped amortising anything across the frame.

**Timeline redraw, measured 2026-09-16** — it was on this list as unmeasured, and the
measurement found a defect. During playback of a 3,492 x 1,964 recording the main thread
spent 43% of its samples inside `NSHostingView.layout()` and was idle 21% of the time;
paused, it was 99.6% idle with zero layout samples. All of it was ten invalidations a
second from `TransportBar`'s poll, reaching every view that read `playhead` in its own
body. `TimelineEditor`'s body ran **74 times in eight seconds of playback, and 0 after**
`AtPlayhead` moved those reads. Release behaves like debug here (40% against 43%), so the
build configuration is not the explanation.

The oracle for the user-facing half is CoreMedia's own account, not a proxy: over twenty
seconds, ~1,170 frames decoded, **0 dropped, 0 more than 16 ms late**, both before and
after. See `docs/design/why-the-editor-felt-slow.md`, whose second half is about the three
measurements that were wrong first — a shell builtin shadowing `log`, a before/after where
only one side was playing, and a counter that was never wired. Each returned a confident
zero.

Still unmeasured: export throughput.

`CameraMotionTests`' existing timing assertion is the model for all of these: it exists
because a real recording stuttered, it names the number, and it fails if the O(n²)
comes back.

### 5.2b Multi-display, which no gate could pose until 2026-09-16

**Two defects, twenty minutes after a second monitor was attached** — see
`docs/design/a-window-on-the-other-display.md`. A window recorded on a display whose origin is
not (0, 0) had its recording placed a whole display away, so every pointer sample fell outside
it and `normalise` returned `nil`: **no cursor drawn at all**, for the length of the take. The
second, a scale taken from the main display rather than the window's, turned out not to move
anything — the first account of it was wrong and the test written to prove it is what refuted it.

Held in two halves, because neither is enough alone:

| | what it drives | when it runs |
|---|---|---|
| probe § 29 | the real capture stack, one window per attached non-main display | only with a second display attached; skips **by name** in the verdict otherwise |
| `WindowOnAnyDisplayTests` | the rule alone — 11 panel sizes × 8 placements × 3 scales | everywhere, no hardware |

Both fixes were verified by reverting them: the scale fix turns 29.2 red, the origin fix turns
29.3 and 29.4 red. The pure file carries its own control — feeding a global rectangle where a
local one belongs must put every sample off the recording, or the other four tests mean nothing.

### 5.2c Two environment conditions that read as product bugs

Found 2026-09-16, both while running the gates on a machine that had been in use all day.

**A locked screen turns on secure input, and this app is right to go silent under it.**
`InputObserver.handle` checks `IsSecureEventInputEnabled()` before it reads anything off an
event — a password field must never reach an observation log — so with secure input on it emits
nothing at all. A locked screen sets it system-wide (`kCGSSessionSecureInputPID` in
`ioreg`, alongside `CGSSessionScreenIsLocked = Yes`). The effect is that
`aRefreshedShapeStillReachesTheSamples` and four probe checks fail, and they fail looking
exactly like a regression in the pointer path. The probe already had a precondition check saying
so in words; the package test did not, and now skips by name. **Gate 3 and gate 6 cannot pass
with the screen locked** — gate 6 needs a window it can put full screen.

**`UndoManager` cannot be created and released inside the app-hosted test target.** The caption
undo tests each passed alone and, run as a suite, took the host down with a `SIGSEGV` inside
`MenuBarRecorderPanel.body` — a view none of them touch — then, after one attempted fix, hung
with the bundle loaded and no test started. `UndoManager` installs a run-loop observer to close
its automatic groups and does not retain the targets it is registered with; one that outlives
its test leaves both behind in a process that keeps running. The fix was a seam — `UndoRecording`
— and it is a better design anyway: what is worth testing is WHEN this app registers a step, not
that Foundation's stack works.

**Both lessons are the same one.** A test that fails for a reason outside the code under test
must say which reason, or the next person spends an afternoon on the wrong thing. That is what
the probe's named skips have always been for; two more places now do it.

### 5.3 Compatibility

| axis | today | proposal |
|---|---|---|
| macOS | 26 only | keep the floor; add a **stated** support statement and test the floor in CI when CI exists |
| Architecture | no matrix | Apple Silicon is the development target; **Intel is untested and should either be tested or dropped from the claim** |
| Displays | **§ 5.2b, 2026-09-16**: probe § 29 drives every attached non-main display, mixed scale factors included; `WindowOnAnyDisplayTests` covers 11 panel sizes × 8 placements × 3 scales without hardware | add: a display **disconnected mid-recording**, and a window **dragged between differently-scaled displays** mid-recording, which is named as still open |
| Locales | 10 string tables, key-parity scanned | **add a rendered check**: every UI string, laid out at the app's font, fits its control. German and Russian run ~30% longer than English |
| Caption line length by script | 42 / 32 display width | **add a rendered check** that `CaptionArt.fits` agrees with `CaptionBuilder.longestLine` at 720p, 1080p and 4K |

### 5.4 App tier

13,761 lines with no executable test. Two ways forward and they are not exclusive:

1. **Keep moving decisions down.** Every time a rule in a view turns out to be
   interesting, it belongs in the pure tier. This has happened five times in one week
   and each time the test came free.
2. **Add a test target for the models.** `CaptionsModel`, `TimelineEditorModel`,
   `AnnotationModel` are `@Observable` classes with no view dependencies; they are
   testable today and nothing tests them.

---

## 6. The L4 design, worked through rather than listed

The three flows below were named on 2026-09-05 because each is a way to lose a recording.
**Designed 2026-09-15** against `DESIGNING-A-TEST.md`, and the design changed the order:
risk is impact × likelihood, and the escapes of the intervening ten days were all in a
fourth flow nobody had listed.

### 6.0 The editor opens, and it is full screen — build this first

| | |
|---|---|
| **impact** | Annoying. Nothing is lost. |
| **likelihood** | **Observed twice in three days**, and both times a person reported it. |
| **partitions** | opened from a new recording; opened from a project; opened a second time into a window that already exists |
| **oracle** | **Exact.** The window's frame equals the screen's. Not "looks right" — a number against a number. |
| **size** | large: a real window on a real display |

Impact × likelihood puts this above the three below, and it is the cheapest of the four.

**Built 2026-09-15** as `scripts/check-editor-opens-full-screen.sh`, and it found the defect
on its first run. Two earlier shapes were built and measured before this one, and both are
recorded in the script because the reasons are the interesting part: XCUITest cannot see a
window that has moved to its own Space, and an XCTest inside the app's own test target cannot
launch a second instance of its own bundle with arguments. **A flow that cannot be observed
reliably needs a different observer, not a longer timeout.**

The oracle is `styleMask.contains(.fullScreen)`, written out by `--report-window-state`. The
app is not marking its own homework: it is not asked whether it MEANT to be full screen, it is
asked what the window system made of it.

*(An earlier note here said L4 was gated behind an Accessibility grant. That was true of the
XCUITest shape and of one machine on one morning; it is not a property of the platform, and
the shape that replaced it needs no grant at all.)*

**Superseded:** the first attempt was `SoredemoUITests`, and it did not run. macOS requires the
process driving the tests to hold **Accessibility** — `xcodebuild` fails with *"Timed out
while enabling automation mode"* until Terminal (or Xcode) is granted it in System
Settings → Privacy & Security → Accessibility. That is a one-time grant by a person, not a
per-run flake, and it is worth stating plainly because it is the same cost § 6.3 refuses to
pay for the permission flow: **L4 on this platform is gated behind a permission no test can
grant itself.** The difference is that this one is paid once and then every L4 test runs,
where the permission flow would need a system dialog driven on every run.

The fixture is synthesised in the test — one black frame written with AVFoundation, under a
kilobyte — rather than checked in or pointed at by an environment variable, so there is no
setup step to be told about beyond the grant.
The two defects it would have caught were an observer registered once per SwiftUI update
(so `toggleFullScreen` ran twice: enter, then exit) and an `alphaValue = 0` that stopped
the toggle working at all. Neither is reachable from any smaller test: both are about what
AppKit does with a real window.

**`--open-project <path>`** exists for this, beside `--present-picker`: `openProject()`
goes through an `NSOpenPanel`, so without it the whole editor tier is unreachable from a
test. A verification flag rather than a test-only hook — a person can use it too.

### 6.1 Start, pause, resume, stop

| | |
|---|---|
| **impact** | Catastrophic — the recording is the product. |
| **likelihood** | Low. This path is covered at L3 for everything except the menu bar panel driving it. |
| **partitions** | stop with no pause; one pause; several pauses; pause and stop while paused |
| **oracle** | **Exact and already written**: `RecordingHealth` on the file, plus the segment count against the number of pauses. |
| **size** | large, and it needs Screen Recording granted — so it can never run where that cannot be granted |

### 6.2 Quit while recording

| | |
|---|---|
| **impact** | Catastrophic, and it is the one path where the app itself is what stops. |
| **likelihood** | Low, but the failure is silent: a file that looks present and will not open. |
| **oracle** | `RecordingHealth` after `terminate()`. |
| **size** | large — **but not a UI test.** Launch the binary, start a recording, terminate the process, examine the file. No automation of controls, so none of XCUITest's flakiness. |

### 6.3 Permission denied, then granted — **not bought, and here is why**

TCC dialogs belong to the system, not to this app. Driving them means `tccutil reset`
plus clicking a window no test framework owns, and the result would be a test that fails
for reasons unrelated to this code more often than for related ones — which is the
definition of a test that gets disabled.

What exists instead: `--dump-permissions` prints the state of every grant, so the flow can
be verified by a person in one command. **A flow that cannot be tested honestly is better
named than faked**, and `PermissionsWindow` is small, pure, and covered at L1.

Anything beyond these four is more expensive than the defect it catches.

---

### 6.4 The recording bar can be dragged — `scripts/check-the-bar-can-be-dragged.sh`

**Built 2026-09-16, because the bar had never been draggable and nothing here could have said
so.** It was reported as "can't drag the bar when recording" and it had two causes stacked on
each other, neither visible to any other check:

| | what was wrong | how it was established |
|---|---|---|
| 1 | `isMovableByWindowBackground` does not survive an `NSHostingView` | the same panel, driven with synthesised events, moved 88 points with a plain `NSView` in it and zero with SwiftUI in it |
| 2 | AppKit discards the mouse-down at an **inactive** application's window unless the view accepts first mouse — and this bar is never the active app | one press and drag moved it zero points and delivered zero gesture changes; a click followed by the identical drag moved it 140 and delivered fifteen |

Two repairs for (1) were measured and rejected before the one that works: an `NSView` behind
the SwiftUI content answering `mouseDownCanMoveWindow`, and the same view inside a `ZStack`.
Neither moved the window. What works is doing the move in a `DragGesture` on a layer behind the
controls — the buttons still fire, which is asserted in the same run.

**Three readings of this were invalid before one was not**, and they are worth keeping because
each looked like an answer:

1. A probe that pumped `RunLoop.main.run(until:)` instead of `NSApplication.sendEvent` reported
   "did not move" for the SwiftUI panel **and for a plain `NSView` positive control**. No event
   ever reached either window. A negative reading with no positive control beside it is not a
   reading.
2. The first drag against the real app grabbed a point computed from a frame in the wrong
   coordinate space and missed the bar entirely.
3. The second one parsed the app's printed frame — which never arrived, because `print` to a
   file is block-buffered and the app had not exited yet.

The oracle is the app's own window frame from AppKit, printed by `--show-recording-bar` along
with two counters that split the failure: how many hit tests landed on the bar, and how many
gesture changes were delivered. `0 / 0` is a pointer that never arrived; `2 / 0` is the
first-mouse rule; `n / 0` with n large is the arithmetic. The check prints all three readings
on a red and names which is which.

**It skips, loudly, where it cannot inject events** — established by moving the cursor and
reading it back, not by asking `AXIsProcessTrusted`, which answers a different question.

### 6.5 What SwiftUI complains about, counted — `scripts/count-swiftui-complaints.sh`

**Not a gate. A number, so the next attempt starts from evidence rather than from scratch.**
Three messages in this app's console are ours and none of them is located:

```
NSHostingView is being laid out reentrantly while rendering its SwiftUI content
[com.apple.attributegraph:error] Cycle detected through attribute: <id>
onChange(of: Int) action tried to update multiple times per frame
```

What was established 2026-09-18, and what was not:

| | |
|---|---|
| when the cycle happens | **once or twice per editor open**, and both occurrences sit immediately beside `AVAssetInspectorLoader loadValuesAsynchronously … tracks` and the decoder being built and torn down — the composition rebuild, not the window opening |
| which view | **unknown.** `AG_TRACE_CYCLES=1` and `SWIFTUI_DEBUG_CYCLES=1` were both tried and neither prints the attribute chain on macOS 27, so the id is not resolvable outside a debugger |
| the other two | **not reached by `--open-project`.** They were reported from a session that also opened the caption editor and played the video, so a zero from this script is "this path did not produce one", not "the app does not" |

**It reads the unified log, and the line count is printed first on purpose.** `NSLog` writes to
stderr only when there is a tty; redirected to a file it goes to the unified log alone. The first
attempt at this captured stderr, reported zero of everything, and was measuring nothing — the
same shape as the `log` builtin that made an earlier "zero cycles" meaningless. A run that
collects fewer than a hundred lines now fails rather than reporting three zeros.

## 7. Documents are tested too, and here is why

Three separate documents in this repository have been found stating something false
**about this repository**:

* the market comparison marked region capture absent — it ships;
* the caption gap table marked "waveform with cue blocks" absent — the timeline has had
  it the whole time;
* `ROADMAP.md` marked `range-export`, `edit-aware-outputs` and `text-based-editing` as
  pending — all three had shipped.

The failure is identical every time: a claim about this codebase written by reading
somebody else's product and guessing at this one. **A comparison table is a claim about
this repository as much as about anyone else's, and the half about this one is the half
that can be checked.**

**Rule:** any document row that asserts a capability of this app names the symbol or the
file that provides it, or it is marked unverified with a date.

---

## 8. Priority

In the order a defect found there would cost the most.

1. ~~**Memory budgets while recording.**~~ **Started 2026-09-05**, probe § 28 — §5.1 has the
   figures and, more importantly, the three things they still do not establish. The
   30-minute soak is the one that matters and it cannot live in a gate.
2. ~~**Frame-time budget for the compositor.**~~ **Done 2026-09-05** — §5.2. The caption
   rebuild followed; the timeline redraw was measured 2026-09-16 and found a defect
   (`docs/design/why-the-editor-felt-slow.md`). Export throughput is what is left.
3. ~~**App-tier model tests.**~~ **Started 2026-09-10.** There is a `SoredemoTests` target now,
   hosted by the app, run by `scripts/run-app-tests.sh` as a fifth gate — six tests over
   `CaptionsModel` and `TimelineEditorModel`. The infrastructure was the whole obstacle: the
   models were always testable, and there was nowhere to put a test. What remains is coverage,
   which is now an ordinary matter of writing them.
4. **Rendered locale check.** **Narrowed again 2026-09-18, by looking at a Chinese window and
   reading English in it.** `Remove background noise`, `Blurs the picture only…`, `esc to
   cancel`, `Click to record · ⎋ to cancel` and six more were plain `Text("…")` literals that
   had never been in ANY string table: SwiftUI treats a literal as a `LocalizedStringKey` and
   falls back to the key, so they rendered in English in all ten languages and nothing failed.
   `everyPlainUILiteralIsInTheStringTable` closes that class — it decodes `\u{…}` escapes before
   comparing, because the first run reported a sentence that HAD been added correctly (source
   spells the dash as an escape, the table spells it as the character), and a check that flags
   somebody's correct work is a check they turn off. What remains at this item is still the
   original claim: nothing has been looked at rendered, and German and Russian run ~30% longer
   than English. Ten languages, one of them the author's, nine unverified
   at the pixel. **Narrowed 2026-09-07:** the status line was not merely unverified, it was
   untranslatable — `statusText` is a `String`, which binds SwiftUI's *verbatim* overload, so
   twenty-seven sentences drew in English in all ten languages, including all seven that tell
   somebody their recording is damaged. Same defect as `ToolbarAction.help`, in a position
   nothing scanned. Now `String(localized:)`, with `everyStatusSentenceIsInEveryStringTable`
   holding it: it reduces every interpolation and every format specifier to one marker and
   compares, rather than predicting `%@` against `%lld` per site and being wrong about the one
   `Int` sentence in the app. What remains at this item is the original claim — nothing has
   been looked at rendered, and German and Russian run ~30% longer than English.
5. **CI.** Not first: four gates a person runs is a real process, and a CI that cannot
   open a display cannot run gate 3 — which is where this project's hardest tests are.
6. UI tests, and only the three flows in §6.
7. **A gate for how much the editor redraws while playing.** Added here rather than built,
   because the honest version is not cheap and the cheap version is a scan that would cry
   wolf. The invariant is real and now has a name — no view body may read `playhead` except
   `AtPlayhead`'s — but every legitimate use in the app *also* spells `playhead`: the model's
   own methods, the panels' `let playhead` parameters, every `Button` action closure. A grep
   that flags those is a grep somebody turns off, which this project has already learned once.
   The gate that would work is the one used to find the defect: launch the app against a
   fixture project, play, and count body evaluations against a ceiling, with a positive
   control so a zero cannot come from an unwired probe. That needs a committed fixture
   recording, which the repository does not have and which `SmokeTests` currently builds in
   Swift at test time — so the first piece of work is a fixture a shell gate can use, not the
   gate.
