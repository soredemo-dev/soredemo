# Finding dead air in the picture

*Measured 2026-08-30. Code: `Core/Sources/Overlays/StillnessFinder.swift`,
`Core/Sources/Compositing/StillnessReader.swift`.*

A screen recording that holds the same frame for eight seconds is dead air. This app already found
the silence in the sound; it had nothing that found the stillness in the picture.

## Why a frame difference and not optical flow

Both were measured on the same footage.

| signal | 45 s of a genuinely idle recording | cost per pair |
| --- | --- | --- |
| `VNGenerateOpticalFlowRequest` | 0 / 269 false fires, max moving area 0.00% | **39 ms** |
| frame difference | 0 / 269 false fires, max moving area 0.00% | **2.7 ms** |

They agree exactly on this question, and one is fourteen times cheaper. Optical flow answers a
harder question — *which way* things moved — and that is what makes it worth its cost when the
question is "was that a scroll or a tap". Stillness does not need it.

Optical flow also costs **16 seconds on its first call**, loading a model. A frame difference has
no first call.

## Where the threshold sits, and why it is not a sensitive number

Measured across three recordings, sweeping the fraction-of-frame threshold:

| threshold | idle iPad (269 slices) | interactive iPad (214) | a Mac screen with a terminal animating (89) |
| --- | --- | --- | --- |
| 0.02% | 0 | 117 | 39 |
| 0.05% | 0 | 117 | 25 |
| 0.10% | 0 | 116 | 21 |
| 0.20% | 0 | 113 | 21 |
| 0.50% | 0 | 109 | 19 |

**The signal is bimodal.** Real activity is 1% to 50% of the frame; stillness is 0.000% — on 269
idle slices not one pixel changed by more than 8/255. So every threshold in that range gives
nearly the same answer, and the number has a wide valley to sit in rather than an edge to balance
on.

What decides it is the cursor. A 28 × 40 cursor moving across a 1512 × 982 frame changes about
**0.15%** of it. The threshold has to sit *below* that, or a recording whose only motion is
somebody moving the pointer is called still and cut — and the cut makes the pointer jump.

**0.05%** is the default: below the cursor, far above the floor.

## Two settings that are not the threshold

**Two seconds minimum**, which is longer than the sound equivalent's 0.7 s and deliberately so. A
second of silence is a pause; a second of a held picture is somebody reading, and it is the normal
state of a demo rather than a fault. Dead air starts where a viewer begins to wonder whether the
video has stopped.

**Three tenths of a second of padding**, which is more than sound gets. A cut that lands on the
exact frame where motion resumes clips the start of the motion, and the result reads as a dropped
frame rather than as an edit. Sound has no equivalent problem, because a waveform's onset is
audible before it is loud.

## An idle screen is rarely idle

A 25-second capture of a real Mac desktop, taken while deliberately doing nothing, fired on 19 of
89 slices. The screen was not idle: a terminal was animating a spinner and a counter.

The median was still 0.000% — more than half the slices were perfectly still — so the measurement
is right and the screen was wrong. It is worth knowing before choosing a default: **a real
recording of somebody's Mac usually has something moving in a corner**, and a threshold tuned on
synthetic stillness would find nothing on real footage.

## What the reader does and does not do

It walks the recording once with `AVAssetReader`, takes the **first** frame at or after each slice
boundary, reduces it to 480-pixel-wide grey, and counts pixels differing by more than 8/255.

- **The first frame of the slice, not an average.** Averaging would smear a short movement into
  stillness, which is the one direction this must not be wrong in.
- **Grey, not colour.** A change big enough to matter moves the luminance, and one plane is three
  times less work for the same answer.
- **A fraction, not a count**, which is what makes it safe to shrink a 4K frame to 480 across:
  the answer is the same at any width.
- **`AVAssetReader`, never `AVAssetImageGenerator`.** Asking the generator for exact frames out of
  a movie written by a capture session hung past ten minutes for an eighteen-frame clip, with no
  error.
