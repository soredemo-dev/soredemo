# Hearing the scrub

*Code: `Core/Sources/Overlays/ScrubGrain.swift`, `Soredemo/Editor/ScrubAudio.swift`.*

Dragging a playhead in silence is the difference between finding a word and
hunting for one. A picture at 3.2 seconds looks like the picture at 3.4; the
sentence does not.

A **grain** is a short slice of the recording played whole each time the playhead
moves. Held still, the same grain repeats and reads as a held note; dragged,
successive grains walk through the recording and read as speech at whatever speed
the hand is moving.

`ScrubGrain` holds the arithmetic and no engine and no file, so the two things
that actually go wrong can be checked in a test: a grain cut past the end of what
was read, and a grain that does not fade.

## The three durations

**Grain length, 50 ms — between two failures.** Shorter than about 20 ms and a
vowel has no pitch left; the result is a series of ticks rather than a voice.
Longer than about 100 ms and the grain outlives the hand: a drag that has already
moved on is still hearing where it was, which reads as lag rather than as
scrubbing.

**Fade, 3 ms — and without it the whole feature is a click track.** A grain begins
and ends at an arbitrary point in a waveform, so its first and last samples are
almost never zero, and a step from silence to mid-waveform is a click. Every grain
would have two. Three milliseconds is long enough to remove the step and short
enough that a 50 ms grain is still mostly itself: six per cent of it is fade.

**Read window, 2 seconds — because reading per grain would stall the drag.**
Decoding a compressed stream to reach one 50 ms slice costs far more than the
slice, and a drag asks for a new slice sixty times a second. One read serves forty
grains.

## Decisions inside the arithmetic

**The grain is centred on the playhead, not started at it.** A grain that starts
at the playhead plays the 50 ms *after* where somebody is pointing, so the sound
is consistently ahead of the line.

**A partial grain is refused, never padded.** Padding is silence, and a burst of
silence in the middle of a drag reads as a dropout.

**Dragging left plays the grain backwards.** Speech played backwards is
unintelligible and that is not the point: what it carries is the rhythm, and the
rhythm is what somebody is navigating by.

**The sample rate is passed through, never defaulted at the cut.** A fade written
in seconds is a different number of samples at every rate, and a grain cut from a
44.1 kHz file faded as though it were 48 kHz is faded 9% short — which is a
smaller click, not none.

**The fade is linear, not raised-cosine.** A cosine fade is the textbook answer
and is inaudibly different over three milliseconds; a straight line is two
multiplications and no table. A grain shorter than two fades is faded across its
whole length rather than having its ends overlap, which would amplify the middle.

**The read window is aligned to a grid, not centred on the request.** A window
centred on wherever the hand happens to be is a different window on every frame of
a drag, so nothing is ever a cache hit. On a grid, a drag through one window's
worth of recording reads once. The window is widened by a grain at each end so a
grain centred anywhere inside the grid cell still lies wholly within what was read
— the case `cut` refuses.
