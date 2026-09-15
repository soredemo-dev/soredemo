# Why the editor felt slow

A recording played back in the editor and the report was "frame rate looks low", then "still
lagging", then — with the reporter's own project finally to hand — "it still feels like dropped
frames". This is what was measured, in the order it was measured, including the four measurements
that were wrong and how each was caught.

Three things were found. Two were real defects in this app and are fixed: the whole editor
rebuilding ten times a second, and the caption list rebuilding with it. The third was not a
defect at all — the frame rate being reported is the RECORDING's, and the recorder's own log
proves the screen was still — and separating those took longer than fixing either.

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

## Live Text was running on every frame of the preview

`AVPlayerView` analyses video frames for text and subjects by default — the Live Text and
subject-lifting affordances. For a screen recording that means running OCR over a screen full of
text, continuously, while it plays, and hanging VisionKit's own overlay views inside the hosting
view where their layout runs during ours. The reported log carried the whole signature:
`checkRichAnalysisAvailability XPC failed` over and over, `[MADService] Client XPC connection
invalidated`, `AVVideoFrameVisualAnalyzer _resetAnalysis`, and a pair of
`VKCActionInfoView`/`VKFlippedGlassContainerView` constraint conflicts AppKit had to break.

`view.allowsVideoFrameAnalysis = false`. Measured on the reporter's own project, six seconds of
playback: VisionKit and media-analysis log lines **26 → 0**, main thread idle **26% → 35%**.

**It did not fix the dropped frames**, and saying so is the point: dropped went 3 → 4 and late
went 10 → 7 across the same window, which is noise. It is a real waste removed and one source of
reentrant layout gone, not the answer to the report.

## The frame rate was the recording's, not the editor's

The reporter's recording is 1920×1080 and **37.1 fps on average — and that average is the least
useful number about it**. The gap between consecutive frames has a median of 13.3 ms (75 fps),
a p90 of 35 ms, and **47 gaps longer than 100 ms, six of them a full second**, all between 14.5 s
and 23.6 s.

*(The first version of this measurement read gaps straight out of `AVAssetReaderTrackOutput` and
got negative values and a NaN. Samples arrive in DECODE order and H.264 with B-frames decodes out
of presentation order. Negative gaps were the tell; the times are sorted now.)*

The holes are faithful, and the recorder's own log proves it. `CaptureSession` writes a
`StillInterval` whenever ScreenCaptureKit reports `.idle` — "nothing was drawn" — for a stretch.
This recording carries seventeen of them, and six line up **one for one** with the six
one-second holes:

| still interval starts (media time) | video hole |
|---|---|
| 14.548 s, 85 idle callbacks in 991.7 ms | 14.54 s, 1006.7 ms |
| 15.548 s, 86 in 995.4 ms | 15.54 s, 1000.0 ms |
| 16.556 s, 89 in 992.5 ms | 16.54 s, 1006.7 ms |
| 21.569 s, 72 in 880.0 ms | 21.55 s, 896.7 ms |
| 22.556 s, 84 in 992.7 ms | 22.54 s, 1006.7 ms |
| 23.555 s, 74 in 885.2 ms | 23.55 s, 890.0 ms |

Eighty-five callbacks in a second, every one of them saying the screen did not change. The stream
was healthy; the picture was still. `.idle` arrives with no image buffer at all, so there is
nothing to write — the file is variable-rate by construction and a still screen produces no
frames.

The observation log agrees from the other side: pointer samples per second across that stretch
run 561, 456, 39, 36, 37, 246, 143, **0, 0, 0, 0**, 42, 496, 458. Nobody was touching anything.
And because `showsCursor` is false, a mouse moving over a static screen changes no pixels and
produces no frames either — which is why "is it because the mouse moved too fast" was a better
guess than it looked.

**What a person sees** is the picture holding for a second while the drawn cursor keeps gliding
over it, and that reads as dropped frames. It is not: it is the screen, recorded honestly. The
editor drops nothing on a steady source — twenty seconds of a 65 fps recording gives 0 dropped
and 0 late — and drops three or four on this one, at the burst that follows each hold.

The app already has the answer to those holds as a feature rather than a fix: the toolbar's
"Find the stretches where nothing moves" reads these same recorded intervals through
`RecordedStillness` — no decode pass — and offers to remove them.

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

## Four measurements that were wrong

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

**Gaps read in decode order.** `AVAssetReaderTrackOutput` hands back samples in DECODE order and
H.264 with B-frames decodes out of presentation order, so the first frame-timing measurement
produced negative gaps and a NaN maximum. That one announced itself — a negative gap between two
frames is impossible — which is the only reason it took a minute rather than an hour.

The shape the first three share is one this project has hit before: **a fact about the read
stated as a fact about the thing.** An empty capture, an idle player and an unwired counter all
say zero. The fourth is its cousin: a fact about the ORDER stated as a fact about the timing.
