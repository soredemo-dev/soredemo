# The rolling clip buffer costs 40% of the frame rate

**Decided 2026-09-22.** "Save the last fifteen seconds" (`4a3fc24`, 2026-09-15) attaches
`SCClipBufferingOutput` to every recording. It is a second encode of every frame running beside
the master's, and at a large buffer there is not room for both. This records what it costs, how
that was measured, and why the fix is a ratio rather than a pixel budget.

## What was reported

A recording felt "一點都不 smooth". The file said 38.1 fps. An earlier one, of the same window at
the same size, said 65.

## What was measured

**First, that it is not dropped frames.** Every frame interval in both files, sorted:

| | 2026-09-10 | 2026-09-22 |
|---|---|---|
| buffer | 3492 × 1964 | 3492 × 1964 |
| interval | 9–10 ticks of 1/600 s | 15–16 ticks |
| fps | 65.0 | 38.1 |
| intervals > 50 ms | **0** | **0** |

Both are perfectly regular. A dropped frame is a hole; there are none. This is a low, steady
delivery rate, which has a different cause and a different fix.

**Then, the one variable.** `scripts`-adjacent probe, one window, one 3492 × 1964 buffer,
changing only whether an `SCClipBufferingOutput` is attached, the two conditions interleaved so
a thermal slope could not be mistaken for the buffer's cost:

| | round 1 | round 2 |
|---|---|---|
| no clip output | 112.1 fps | 112.2 fps |
| clip output attached | 66.9 fps | 67.7 fps |

**40%.** The dates bracket it: 2026-09-10 predates the feature, 2026-09-22 follows it.

The probe's source was a `CALayer` animation, redrawn by the render server rather than by the
process, so the window could always feed the stream faster than the stream could take it. A
CPU-driven animation would have made the content the variable instead.

## Why the comment that justified it was not wrong

The code said, and still says:

> Attached to every recording rather than switched on by a setting: the value of "save the last
> fifteen seconds" is that nobody had to decide in advance to want it.

That is a good argument about people and it is kept. What it lacked was the price. A feature
that is free at 1920 × 1080 and costs 40% at 3492 × 1964 cannot be decided once for both.

## Why the fix is not a pixel budget

The obvious repair is a Mpixel/s ceiling above which the buffer is not attached. Every number in
it would be this Mac's: a machine two years newer would refuse a buffer it could afford, and one
two years older would accept one it could not. It is the same mistake as the notch design's
`185`, and this project has already paid for that one.

**So the rule asks the only machine-independent question there is: is this recording getting the
frame rate it asked for?** That is already being counted, on every frame, for other reasons.

- The window opens **1 s** after the segment does. A stream's first frames arrive while it is
  still starting, and a rate measured across them measures the ramp.
- It closes **1.5 s** later.
- Below **85%** of the requested rate, the clip buffer is what goes. A ratio, so a 30 fps
  recording and a 120 fps one are judged identically; 0.85 because below it the shortfall is
  visible in playback rather than jitter.
- **Once per segment.** A rule that re-attached whenever the rate recovered would oscillate for
  the whole recording.
- The detach runs on a detached `Task`, never on the sample queue. Calling
  `removeClipBufferingOutput` there would block the one queue ScreenCaptureKit delivers frames
  on — a dropped frame caused by the fix for dropped frames.

`CaptureSession.clipBufferVerdict(framesInWindow:windowNanos:requestedFrameRate:)` is the whole
decision, pure, and `ClipBufferCostTests` pins it — including that the same ratio is judged the
same at 30, 60 and 120 fps, which is what "machine-independent" means here.

## What the person sees

The Save Clip control reports the sentence, not an absence: *"delivered 38.1 fps against 60 asked
for; the rolling clip buffer was dropped so the recording could keep its frame rate."* Reporting
"no clip buffer" would read as a broken feature rather than one this recording gave up on
purpose.

## What this does not answer

- **The 1 s and 1.5 s.** Chosen so the verdict lands early enough to matter and late enough to
  mean something; neither has been watched against a stopwatch. A recording pays the buffer's
  cost for those 2.5 s.
- **Whether a setting should exist** for somebody who knows they never want the feature. The
  adaptive rule makes one unnecessary for correctness, not for those 2.5 s.
- **Whether 85% is the right floor.** It is a judgement about what is visible, and nobody has sat
  in front of a 51 fps recording of a 60 fps request to check.
