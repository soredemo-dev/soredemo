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

### `kVTCompressionPreset_ConsistentQuality` — measured, and it does not arrive

*Measured 2026-09-15. The conclusion is not about the feature; it is about the route to it.*

`kVTCompressionPropertyKey_ConstantQualityFactor` passed through
`AVVideoCompressionPropertiesKey` on an `AVAssetWriterInput` is **ignored**. Four values —
0.40, 0.50, 0.60, 0.75 — and a control with no quality key at all produced **byte-identical
output**: the same 105.50 MB and the same 0.564 mean difference from the source. A setting
whose value cannot change the result is a setting that is not being read.

What made that visible was the control. Without it the first run looked like a win:

| encode | size | difference from source |
|---|---|---|
| 20 Mbps average, synthetic screen content | 2.01 MB | 1.025 |
| "constant quality 0.75", same content | **1.77 MB** | **0.997** |

Twelve per cent smaller and closer to the source — and it was measuring **the absence of a
bitrate cap**, not the presence of constant quality. The synthetic clip compressed to about
0.8 Mbps, so the 20 Mbps ceiling never bound and the two runs differed only in that one had
a cap and one did not.

On a real recording the same pair inverts, which is the number that prompted the control:

| encode | size | difference from source |
|---|---|---|
| 20 Mbps average | 48.29 MB | 0.733 |
| no cap (labelled "constant quality") | 105.50 MB | 0.564 |

**So `ExportQuality` keeps its measured bitrate**, and the open question is narrower than it
was: not "is constant quality better" but "is there a route to it from an `AVAssetWriter`
pipeline at all". The next thing to try is `VTCompressionSession` directly, which is where
those keys are documented to live — a much larger change, and one that now has a number to
beat rather than a hope.

**Two lessons worth more than the feature.** A parameter sweep that returns identical results
is not a flat curve, it is a parameter nobody is reading. And a measurement on content chosen
to *illustrate* the claim — long still stretches, brief busy ones — was too easy to test it:
it never reached the constraint the claim is about.

### The original note, kept because the reasoning still stands

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

## Two things macOS 27 says out loud that macOS 26 did not

Both were pre-existing defects the new release made visible, which is the most useful kind of
upgrade finding: nothing broke, something started reporting.

### `NSHostingView is being laid out reentrantly … the layout pass will be skipped`

Reported by somebody as **"frame rate looks low"** in the editor, alongside six
`Cycle detected through attribute` lines.

`Tooltip` placed a `GeometryReader` in a `.background` and wrote `@State` from it on every
layout pass — on every control that has a tooltip, which is most of the toolbar. Writing state
during layout is how a layout cycle is made, and a skipped layout pass is a frame the editor
does not draw.

`onGeometryChange(for:action:)` delivers the value *after* the layout pass rather than inside
it, which is the whole difference. The geometry is also only acted on while the pointer is on
the control, because its only use is placing a bubble that is about to appear. Measured after:
zero cycles, zero skipped passes in a full launch-and-open.

**The compositor was measured first and cleared.** Twenty lock-guarded static reads cost
10.7 ns each — 0.2 µs per frame against an 8 ms budget — so the lock added the same week was
ruled out before anything was changed.

### `Binding(get:set:)`'s setter is now `@Sendable`

Which says the closure MAY cross actors. The first fix was `MainActor.assumeIsolated`, and this
repository had already written down why that is wrong: `GlobalHotkey` records that asserting an
unproven main-thread guarantee that way "is the exact shape that produced an EXC_BREAKPOINT
earlier in this project". A setter that reaches `WindowConfigurator.configure()` through
`onChange` would raise AppKit's own *"NSWindow geometry should only be modified on the main
thread"* — which is exactly what appeared in the console.

`Thread.isMainThread` is asked rather than assumed: synchronous when it is already the main
thread, a hop when it is not.

