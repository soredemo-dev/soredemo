# What macOS 27 changed

*2026-09-15, the morning after the upgrade. Read from the SDK headers rather than from release
notes: `MacOSX27.0.sdk` is what the compiler will actually accept, and a blog post is somebody
else's reading of it.*

The method, so it can be repeated on macOS 28 in ten minutes:

```
SDK=$(xcrun --show-sdk-path --sdk macosx)
grep -rho "macos(27\.0)" "$SDK/System/Library/Frameworks/<Framework>.framework/Headers" | wc -l
```

| framework | additions | worth anything here |
|---|---|---|
| ScreenCaptureKit | 14 | **yes — two of them a lot** |
| AVFoundation | 69 | almost none: camera work |
| AVFAudio | 17 | realtime-safe audio blocks |
| CoreImage | 13 | RAW processing |
| VideoToolbox | 8 | **one, and it needs measuring** |
| Speech | 0 | nothing |

## Adopted

### Two stop codes that had an action attached

`SCStreamErrorInsufficientStorage` (-3822) and `SCStreamErrorNotSupported` (-3823) landed in
`StreamStopReason.itWillFailTheSameWayAgain(code:)` — the right verdict about restarting and
the wrong thing to tell somebody. **A person told "the recording stopped" looks for a bug in
this app; a person told the disk filled up goes and empties it.** Each has its own case now,
and both still refuse a restart, because retrying into a full disk is the same failure twice.

## Worth building, in order of what it would give somebody

### `SCClipBufferingOutput` — the last fifteen seconds, after the fact

A rolling buffer on a live `SCStream`, up to **15 seconds**, exported to a file on demand
without interrupting the buffering. `exportClipToURL:duration:completionHandler:`.

That is the "it just did the thing — save it" case, and it is the one recording somebody
cannot get by pressing record: the bug has already happened. Fifteen seconds is short for a
demo and exactly right for a repro.

It fits this app's rule without argument — the clip is written to a file the person chose, and
nothing leaves the machine.

### `kVTCompressionPreset_ConsistentQuality` — **a claim to measure, not to adopt**

macOS 27 adds `kVTCompressionPropertyKey_ConstantQualityFactor`, described as consistent visual
quality with or without a bitrate limit. `ExportQuality` currently sets
`AVVideoAverageBitRateKey` — a fixed average, chosen because AVFoundation's own default is
tuned for camera footage and measured at 10.5 Mbps for 1080p against the 18–20 that three
screen recorders settled on.

Screen content is the case constant quality is for: long static stretches, short busy ones, and
a fixed average spends the same bits on both. **But that is a hypothesis about this app's
output and this project does not adopt those.** The experiment is: export the same project both
ways, compare file size and a per-frame difference against the composited source, and keep
whichever wins on the pair. Until somebody runs it, the bitrate stays — it was measured.

## Read and rejected, with the reason

* **`SCRecordingEditor`** — a system-owned preview and share UI for a finished recording. It is
  what the built-in screen recorder shows. Adopting it would replace this app's editor, which
  is the app.
* **`AVAssetExportSession` resumable exports** — real, and not reachable from here: the video
  export is an `AVAssetWriter` pipeline. The only `AVAssetExportSession` in this project pulls
  audio out before transcription, which takes a second and does not need resuming.
* **AVFoundation's 69 additions** — Cinematic video, focus tracking, low-light noise reduction,
  ProVideo storage. All camera capture. Soredemo's camera is an `AVCaptureMovieFileOutput` of a
  webcam, and none of it applies.
* **Generated subtitles (WWDC26/256)** — live transcription and translation during PLAYBACK,
  in the player's own subtitle menu. It produces no editable track, no word times and nothing
  to export, so it cannot stand in for `SpeechTranscription`. Worth knowing about only if the
  preview player ever offers a subtitle menu of its own.
* **SwiftUI's lazy prefetching** — for `LazyVStack`. The caption list is a `List` with one row
  per cue, which is already lazy; that is why it was written that way. Converting would cost
  row selection and sidebar behaviour to buy a gain nothing has measured.

## What did NOT change, and was checked rather than assumed

`AnalysisContext.contextualStrings` still changes nothing about what `SpeechTranscriber`
returns — the same synthesised clip and the same four spellings come back byte-identical. See
`teaching-the-recogniser-a-word.md`. **"Apple fixed it" and "Apple did not" look exactly alike
in source code**, so the measurement is the only way to tell, and it is written down so the
next release costs ten minutes.

The performance baselines all moved and are recorded in `TESTING.md` § 0.5: the compositor got
faster, and the budgets came down to match.
