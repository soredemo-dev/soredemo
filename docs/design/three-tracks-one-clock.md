# Three tracks, one clock

*Measured 2026-08-30 on macOS 26. Code: `Core/Sources/Capture/TrackRebase.swift`,
`CaptureSession.handleAudioSample`.*

A recording carries video, the machine's own output, and the microphone in one
file. What a person hears depends on the offsets *between* them, and those offsets
were being thrown away.

## What was reported

A demo with music playing, narrated over the top. The music is captured twice —
once through the system tap, once through the microphone that is also picking up
the speakers — and the two copies did not line up. Described as "the music in the
mic and system doesn't sync which kinda bothers a lot".

## What was measured, twice, independently

**From the finished recording.** A single microphone is mono, so its signal is
identical in both channels and cancels exactly in the side channel: `(L−R)/2`
carries *only* the system audio. Cross-correlating that against `(L+R)/2`, which
carries the microphone plus the system's mono part, over a fifteen-second window
where music was playing:

```
strongest correlation at ±91.5 ms
```

**From the API directly.** A probe opening one `SCStream` with all three outputs,
printing the first presentation timestamp each one delivers:

```
host clock at startCapture()   1092810.1749
first video   pts              1092810.2436   timescale 1e9
first system-audio pts         1092810.2554   timescale 1e9
first microphone   pts         1092810.3569   timescale 44100

video → system audio    +11.8 ms
system audio → mic     +101.5 ms
```

Two numbers from two directions, agreeing to within the width of the window the
first was measured over.

## The cause, and the premise that was wrong

`TrackRebase` held one base **per track**, forcing each track's own first sample
to zero. Its reasoning:

> ScreenCaptureKit hands VIDEO timestamps from a synthetic clock starting near
> zero and AUDIO timestamps from the system media clock, which counts from boot.
> […] One per TRACK, never shared. Each clock gets its own base; a single shared
> base would reintroduce the very offset this removes.

The uptime part is real — unrebased timestamps count from boot, and a player
honouring them stutters, which is the defect that machinery was built for. The
part about two clocks is not: **all three tracks arrive on the same clock**, as
the probe above shows, and the microphone's different *timescale* is not a
different clock.

So a per-track base was not reconciling two clocks. It was taking three tracks
that already agreed and forcing each to a zero of its own — deleting 11.8 ms
between the picture and the machine's sound, and 101.5 ms between the machine's
sound and the microphone.

A tenth of a second between two copies of the same music is not a subtle
misalignment. It is a comb filter.

## The fix

One base for the recording, established by the first complete video frame — which
is already composition time zero, because the writer's session starts there.
Every track subtracts it.

The uptime offset is removed exactly as completely: it is one subtraction either
way. What survives is the distance each track actually had from the start of the
recording, which is the entire reason three tracks go in one file rather than
three.

Audio arriving before the first video frame is dropped and counted
(`skippedSessionNotStarted`), so the audio path is never the caller that
establishes the base, and every rebased audio timestamp is positive.

## What this does not fix

The microphone still contains the music. Cancelling it needs the system audio as
a reference signal, aligned — which this change is the precondition for, not a
substitute for. `VoiceProcessingIO`, the usual macOS answer, cannot help here: it
cancels what the *app itself* is playing, and the music is played by somebody
else's process.

Two honest options remain, and neither is in this change:

- **macOS Voice Isolation**, which the OS applies to the microphone before any app
  sees a sample. Already reachable from the recorder's microphone menu.
- **Offline cancellation** using the recorded system-audio track as the reference.
  Now possible, because the two tracks finally share a timeline.

## How a rebase inflated every audio track

*Moved out of `Core/Sources/Capture/CaptureSession.swift` 2026-08-30 — a defect walk-through belongs where the rest of the clock story is.*

`sampleBuffer` with its presentation timestamp replaced, every sample's own duration and
every other timing field untouched. `nil` when CoreMedia refuses, which the caller counts
rather than writing a buffer whose timing it did not set.

**The previous version inflated every audio track it touched, and this is why.**
It built ONE `CMSampleTimingInfo` with `duration: CMSampleBufferGetDuration(buffer)`
and passed `sampleTimingEntryCount: 1`. CoreMedia applies a single entry to EVERY
sample in the buffer, and in that form `duration` is the duration of ONE sample —
while `CMSampleBufferGetDuration` returns the duration of the whole buffer. A video
buffer holds one sample, so the two are equal and the video path was never affected.
An audio buffer holds hundreds, so each of them claimed the whole buffer's length.

A `.mov` audio track's duration is the SUM of its samples' declared durations, so the
track grew far past the recording; `AVAsset.duration` is the longest track, so the
editor showed a 16-second recording as 38 — and, in a case a user reported, 57.

Shifting the original timing array instead keeps every per-sample duration exactly as
the source declared it, which is the only thing a rebase should be changing: WHEN the
buffer is presented, not how long its samples are.
