# The preview composited at export resolution

**Decided 2026-09-22.** The editor stuttered and the console carried
`<<<< CustomVideoCompositor >>>> signalled err=-12784`. The preview was compositing every frame
at the size the export would be written at.

## What it was doing

`StageWindow.configuredComposition` built the preview's `AVVideoComposition` with
`resolution: .matchRecording`, which resolves through `ExportResolution.size(forAspect:recordingShortSide:)`
to `max(recordingShortSide, 2)` — **the recording's own size**.

For the recording that prompted this, 3492 × 1964:

| | |
|---|---|
| pixels per preview frame | 6.86 M |
| frame duration asked for | 1/60 s |
| **compositing load** | **411 Mpixel/s** |
| the pane it fills | about 900 pt wide, so ~1.8 Mpixel at 2× |

Every one of those frames ran the whole stage — background, shadow, rounded card, cursor art,
captions, annotations, redactions, camera — through Core Image, and then the result was scaled
down for display. Close to four times the pixels, computed and thrown away.

**`AVVideoCompositing` has a hard per-frame deadline.** A frame that misses it is not drawn late;
it is dropped, and AVFoundation signals `-12784`. That is the stutter and the console line at the
same time.

## What the sibling projects do

Read for ideas, not for code, from `~/Documents/opensource/Screen Record Opensource`:

| | preview |
|---|---|
| The Rust recorder | wgpu, rendered directly (77 files touch Metal/wgpu) |
| The Swift recorder | `MetalPreviewView` → `CAMetalLayer`, displaying a texture it rendered itself |
| The two Electron recorders | no custom compositor at all |
| The native editor | one file names `AVVideoCompositing` |

**Four of five never ask AVFoundation to composite a preview.** The point is not that Metal is
faster. It is who holds the deadline: a self-driven renderer that is late shows a picture that
updates late, while a custom compositor that is late has its frame dropped by the player.

## What was taken, and what was not

**Not taken: rendering the preview ourselves.** `AVVideoCompositing` is what makes the preview
and the export the same code, and this project has a probe section asserting they agree
frame-for-frame. Replacing it would trade a measured guarantee for a performance fix.

**Taken: render what is shown, not what will be written.** `StageWindow.previewSize(...)` caps
the preview's short side at `previewShortSideCap` (1080). The export path never comes through
here — `MP4Exporter` calls `CompositionBuilder` directly — so what is written is unchanged.

It is a **cap, never an increase**: a 720p recording still previews at 720, because upscaling
would spend pixels on detail the recording does not have.

## The cost

A preview softer than a very large display could show. Somebody on a 6K display with the
inspector closed can out-resolve 1080 in the pane, and would see a slightly soft preview of a
sharp export.

## What this does not answer

- **Whether 1080 is the right cap.** It is a standard rung above what an editor pane on a
  current Mac displays, not a measurement of any particular pane. The honest version reads the
  view's own pixel size and rebuilds the composition when it changes, which costs a rebuild on
  every window resize; that trade has not been made.
- **Whether this was the whole stutter.** The `-12784` count during playback has never been
  measured, because the instrument for it does not exist yet: `count-swiftui-complaints.sh`
  drives the app with `--open-project` and a synthesised Space that does not land, and two runs
  reported zeros for a playback that never started. The app needs a flag that plays and says so.
