# Why the editor felt slow

A recording of 3,492 × 1,964 at about 65 fps played back in the editor and the report was
"frame rate looks low", then "still lagging". This is what was measured, in the order it was
measured, including the three measurements that were wrong and how each was caught.

## The answer

`StageWindow`, `TimelineEditor` and `EditorToolbar` all read `TimelineEditorModel.playhead`
**in their own view bodies**. `@Observable` registers the dependency on whichever body performed
the read, so every tick `TransportBar` publishes — ten a second, the whole time a recording is
playing — invalidated the preview, the inspector, the toolbar and every lane of the timeline,
whole, and each of those had to be laid out again.

Nine reads in three files:

| Where | The read |
|---|---|
| `StageWindow` × 6 | `playhead: timeline.playhead` handed to the caption editor and to the text, hide, mark, captions and selection panels |
| `EditorToolbar` | `isEnabled: model.canSplitAtPlayhead` |
| `TimelineEditor.readout` | `Text(Self.stamp(model.playhead))` |
| `TimelineEditor.playheadLine` | `fraction(model.playhead, of: duration)` |
| `TimelineEditor.shortcutLayer` | `.disabled(!model.canSplitAtPlayhead)` |

`AtPlayhead` is the fix: a one-property view whose body does the read, so the dependency lands
on it and not on whoever draws it. The text, hide, mark and selection panels still take a plain
`Nanoseconds` — they are pure in their inputs on purpose, and they are small. The two caption
surfaces needed more than a boundary; see below.

Measured, same procedure both sides, with a positive control:

| | body evaluations of `TimelineEditor` |
|---|---|
| five arrow-key nudges (the control) | before 10, after 6 — **the probe fires**, so a zero below is a measurement |
| eight seconds of playback | **before 74, after 0** |

## What it was not, and how that was settled

**Not the compositor.** The suspicion was that the preview renders at export resolution —
`.matchRecording`, so 3,492 × 1,964 — for a picture shown at about 1,400 points. True, and
irrelevant: through `AVAssetReaderVideoCompositionOutput` that composition produces **117.6
frames per second**, nearly twice what 60 fps playback asks for. Halving the render size gives
227.7 fps, so the cost is linear in pixels and the ceiling was never the constraint. A single
frame at that size costs median 7.13 ms, p90 10.29, p99 12.33.

**Not dropped frames.** CoreMedia keeps its own account and prints it. Over twenty seconds of
playback, both before and after the fix: about 1,170 frames decoded, **0 dropped, 0 more than
16 ms late, 0 skipped**, against a 16.667 ms refresh interval. Whatever the report is about, the
video pipeline delivered every frame. Worth keeping in view: decode alone is **mean 33 ms, max
70 ms** per frame at this size, so the decoder is running several frames in parallel to stay
ahead and has little room left.

**Not the debug build.** Release spends 40% of the main thread inside `NSHostingView.layout()`
during playback; debug spends 43%. A four-hundredths difference is not the explanation.

**It is the tick, and only the tick.** Paused, the main thread is **99.6% idle with zero layout
samples**. Playing, it is 21% idle. Everything in between is ten invalidations a second walking
the editor's view graph.

## The caption list, which is where the report actually came from

The fix above removes the timeline's rebuild. It does not touch the inspector, and the inspector
is where a person correcting captions is looking. So the measurement was repeated with a fixture
carrying **270 cues at a realistic 2.2 seconds each**, with the Captions tab open:

| main thread, six seconds of playback | asleep (`mach_msg2_trap`) |
|---|---|
| paused | 4,802 of 4,821 — **99.6%** |
| playing, Captions tab closed | 348 of 1,497 — 23% |
| playing, Captions tab open, before | **2 of 1,501 — 0.1%** |
| playing, Captions tab open, after | 136 of 1,566 — 8.7% |

With the tab open the main thread had no idle left at all. `CaptionsPanel` took
`playhead: Nanoseconds` and `CaptionLines` derived the current cue from it, which made a value
that changes ten times a second an input to all 270 rows. Counted directly, ten seconds of
playback:

| | `CaptionsPanel.body` | `CaptionLines.rows` |
|---|---|---|
| before | **82** | **82** |
| after | **0** | **8** |

(Five arrow-key nudges produce five of each on both sides — the control that says a zero is a
measurement.) Eight is the number of cue boundaries the playhead crossed. The list now rebuilds
when the highlight moves, which is what it is for.

What moved: `CaptionsModel.currentCueIndex` holds the answer, `CaptionCueTracker` — a zero-sized
view that draws nothing — is the only thing that watches the playhead at the playhead's own rate,
and both list hosts take an index plus a `playheadNow: () -> Nanoseconds` closure for the one
action that needs the live value.

## What is left

About 40% of one main thread during playback, after both fixes — 39% with 270 cues on screen and
43% with none, which is to say the caption list is no longer the difference. Of one layout pass, roughly 105 samples are
`AG::Graph::UpdateStack::update` and only 20 reach any view's body: the cost is the size of the
graph being visited, not the work inside it. That cost scales with what the timeline holds,
which is why the same recording in a longer project with a caption track is where the report
came from — and why the fix above, which removes exactly the per-tick rebuild that scales with
that content, is aimed at it.

**Not reproduced here**: the six `Cycle detected through attribute:` lines and the
`NSHostingView is being laid out reentrantly` warning from the original report. One cycle at
load, zero reentrant, across every run since the log query was repaired.

## Three measurements that were wrong

**`log` is a zsh builtin.** `log show … | grep -c "Cycle detected"` in zsh runs the shell's own
`log`, prints nothing, and greps an empty stream. It returns `0` and looks like an answer. Every
"zero cycles" reported before this was that. `/usr/bin/log` is the fix, and the guard is to read
the line count too: 0 matches in a 12,000-line capture is a result, 0 matches in a 0-line
capture is a broken probe.

**A before/after where only one side was doing the thing.** The first comparison showed
compositor work rising twentyfold after the fix. Rebuilding the *old* binary and running it
again produced the same high number: the first "before" run had simply not started playing yet.
Every run since asserts `setting timeControlStatus=1` appears in the log before it reports
anything.

**A diagnostic that was never wired.** `Self._printChanges()` with `open --stdout` captured
output twice and then silently stopped; `NSLog` never reached the unified log at all. Both
reported "zero body evaluations", which was the answer being hoped for. The positive control —
five arrow-key nudges, which must produce evaluations — is what separated a quiet body from a
dead probe, and it is the reason the 74 → 0 figure above can be believed.

The shape all three share is one this project has hit before: **a fact about the read stated as
a fact about the thing.** An empty capture, an idle player and an unwired counter all say zero.
