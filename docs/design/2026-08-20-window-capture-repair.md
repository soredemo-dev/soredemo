# Window capture — four defects, one root, and a reversed decision

*Reported from a real recording, 2026-08-20: capturing a specific WINDOW produced the wrong
output size, the wrong crop, a misplaced cursor, and stuttering playback.*

## What was wrong

Three of the four share a root. `CaptureSource.window` builds
`SCContentFilter(desktopIndependentWindow:)` and sizes the output buffer to a DISPLAY —
a deliberate decision (D2-13): a QuickTime track cannot change dimensions mid-track and a
window moves and resizes, so the buffer is fixed at the largest available display and the
window floats inside it. `SCStreamFrameInfoContentRect` reports where, per frame.

**Nothing reads it.** `Diagnostics.lastContentRect` records the most recent value and that
is all; `capture-source`'s ROADMAP row says the per-frame rect is "`capture-stream`'s
concern, not this row's", and `capture-stream` is unstarted. So:

| Symptom | Cause |
| --- | --- |
| output size / quality wrong | the frame is display-resolution with the window occupying a fraction of it |
| crop position wrong | the window's offset inside the buffer is never applied |
| cursor misplaced | `InputObserver.normalizedPosition` normalises against the DISPLAY while the video's coordinate space is the window — two rectangles treated as one, `1a98402`'s family in the geometry domain instead of the clock domain |
| stuttering | independent: see § PTS |

## The reversal: display + sourceRect, not desktopIndependentWindow

**D2-13's window filter is replaced.** ScreenCaptureKit can crop at the SOURCE:
`SCContentFilter(display:)` plus `SCStreamConfiguration.sourceRect` set to the window's
rect in that display's space, with `width`/`height` sized to the WINDOW.

That makes the whole floating-window problem disappear rather than solving it: there is no
offset to apply per frame, because the frames arrive already cropped and already the right
size. `capture-stream`'s content-rect work becomes unnecessary rather than pending.

The Swift recorder (Apache 2.0) does exactly this, and its comment supplies a third
reason neither of ours had: `desktopIndependentWindow` makes macOS composite **the purple
recording indicator into the captured frames**.

**What is kept from D2-13.** Its actual finding — a track cannot change dimensions
mid-track, so a window that resizes must not resize the output — still holds and is still
why the source rect and output size are snapshotted when a segment opens rather than
followed per frame. A window resized mid-segment is scaled into the fixed output, which
`ContentScale != 1` reports and `resampledFrameCount` counts, exactly as before. The
reversal is only about WHICH rectangle the buffer is sized to: the window's, not a display's.

**What is lost, stated plainly.** A window filter excludes other windows by construction; a
display filter with a source rect does not — anything overlapping the window's rect is
captured with it. That is a real regression in isolation, accepted because the alternative
is a capture that is wrong in three visible ways, and it is the same trade the Swift recorder makes.
`excludingApplications` can narrow it later.

## The cursor: depend on the viewport, not on the display arrangement

`InputObserver.normalizedPosition(globalTopLeftX:globalTopLeftY:in: DisplayArrangement)`
takes the *display arrangement* — a concretion that is only the right rectangle when the
capture IS a display. The fix is the dependency-inversion one: it takes a **`CaptureViewport`**,
which both cases construct — `.display` from the arrangement's placement, `.window` from
the source rect — so the observer normalises against whatever is actually being recorded and
neither case is a special path.

This also removes a real coupling: `InputObserver` currently reaches for
`currentArrangement()` and therefore knows about displays at all. After the change it knows
about a rectangle.

## The stutter: two clocks, not a frame rate

ScreenCaptureKit hands **video** timestamps from a synthetic clock starting near zero and
**audio** timestamps from the system media clock (since boot). Written unrebased into one
file, the tracks disagree by the machine's uptime, and a player honouring timestamps shows
exactly the symptom reported. The Swift recorder rebases both to their own first PTS.

`SCFrameStatusIdle` at 42–84% of callbacks (measured, Phase 2 F2-4) is the OTHER candidate,
and it is worth stating why it is second: the Swift recorder shipped a constant-frame-rate writer
that repeated the last frame on idle, then **deprecated it in favour of variable frame
rate** — writing frames at their real capture timestamps and skipping duplicates by
IOSurface identity. Repeating frames is the intuitive fix and the one they abandoned.

So: rebase first, measure again, and only then decide about idle frames. Fixing the clock
is cheap and provable; changing the frame model is neither.

## Order

1. `CaptureViewport` + the source-rect capture — sizes and crop.
2. The cursor normalises against the viewport.
3. PTS rebasing, with the two tracks' bases asserted independent of uptime.
