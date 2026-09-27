# What the two commercial recorders ship that this one does not

2026-08-26. Answers the standing ask — "check if there is any feature i dont have" —
against the Screen Studio and a Rust recorder feature pages as they read today, plus the five
reference projects in `Screen Record Opensource`.

**Read this as a map, not a backlog.** Several rows are deliberate refusals and say so.
The ranking at the end is by what a demo actually looks like, not by row count.

## Method, and one thing it caught

Every "absent" below was checked by reading the code, not by one grep. That mattered
twice: **GIF export is present** (`Compositing/GIFExporter.swift`, wired through
`ExportQueue`, `StageWindow`, settings and both `Localizable.strings`) and would have
been written down as missing off a grep of two files; and the 54 hits for `arrow` are
all the cursor's *arrow shape* and disclosure triangles, not annotation arrows — the
annotation gap is real, but the evidence for it is that those 54 are all something
else. `NSPasteboard`'s single hit is a doc comment in `ObservationLog` about what
redaction refuses to read.

## Present

Automatic zoom from clicks and AX focus · zooms draggable and resizable on the
timeline · smooth cursor with Screen Studio's four movement speeds · cursor size ·
idle hide · tilt · shake removal · click ripples · six drawn cursor shapes ·
motion blur · two-part shadow · background gradients and wallpapers · padding ·
rounded corners · horizontal / vertical / square / **match-recording** output ·
trim, cut, speed · webcam, microphone, system audio · on-device transcript and
subtitles · keystroke badges · crop · region recording with a remembered
rectangle · redaction masks · text overlays · loudness normalisation · music bed
with voice ducking · MP4 and **GIF** export · ProRes · 4K60 and beyond.

## Absent, ranked

| # | Gap | Ships it | Cost | Note |
|---|---|---|---|---|
| 1 | **Zoom decisions do not re-frame per variant** | Screen Studio | small | The measurement already exists and is tested — `AspectVariant.coverage(ofSourceAspect:)` — and nothing in production reads it. A 16:9 recording covers ~0.32 of a 9:16 frame, so a control legible in landscape is a third the size in portrait, and a portrait export inherits landscape's zooms unchanged. Already the `variants` row's stated outstanding clause. |
| 2 | **Manual zoom** | Screen Studio | small | `ZoomAdjustment` only ever *adjusts* a zoom derived from a click — its `origin:` is that derived zoom. Nothing creates one from nothing, and there is no affordance to. Drag, resize and suppress already work, so this is an insertion point, not a mechanism. |
| 3 | **Noise suppression** | both | **large** | `isVoiceProcessingEnabled` is on `AVAudioEngine`; the microphone here comes through ScreenCaptureKit deliberately. A second parallel capture and a second clock domain. Held for a decision rather than started. |
| 4 | Export presets by destination (web / social / editing) | Screen Studio | small | Resolution, codec and quality are each chosen separately today; there is no named preset. The one `ExportPreset` hit is `AVAssetExportPresetAppleM4A`, unrelated. |
| 5 | Copy result to clipboard | Screen Studio | small | No `NSPasteboard` use anywhere. |
| 6 | Camera does not move out of the cursor's way | Screen Studio | small | `CameraOverlay.scaleDuringZoom` shrinks it during a zoom; it never repositions to avoid covering the pointer. |
| 7 | Card border | a Rust recorder | small | `borderOpacity` exists on the **camera** overlay only. The card has a shadow and no border. |
| 8 | Per-app system audio | Screen Studio | medium | `SCContentFilter(excludingApplications:)` is used, but only to keep this app's own recording bar out of the picture — there is no user-facing choice of which apps to record audio from. |
| 9 | Hide desktop icons while recording | Screen Studio | small | Absent. |
| 10 | Annotation arrows and shapes | a Rust recorder | medium | Text and redaction masks ship; arrows and shapes do not. |
| 11 | Squircle corners | a Rust recorder | small | The card uses `CIRoundedRectangleGenerator` — a rounded rectangle, not a continuous-curvature squircle. |
| 12 | Saved / shareable style presets | both | medium | Every style choice is per-project. |
| 13 | Loop cursor position | Screen Studio | medium | Absent. |
| 14 | Screenshot mode | a Rust recorder | medium | Absent. |
| 15 | iPhone / iPad capture, device frames | Screen Studio | **large** | Absent, and a different capture stack. |
| 16 | Shareable links, cloud workspace | both | **out of scope** | Needs a server. Not a client gap. |
| 17 | AI titles, summaries, chapters | a Rust recorder | medium | Transcription ships; the generative layer on top does not. **Chapters shipped 2026-09-27, on-device** — `2026-09-27-chapters.md`. Titles and summaries still do not. |

## What to do first, and why

**1 and 2 are one afternoon between them and they are the two a person notices.**
Both are about zoom, which is the feature the whole app is organised around, and
both are half-built already: the number for 1 is computed and unit-tested with no
consumer, and the editing verbs for 2 exist with no way to make the thing they edit.

3 is the largest real gap in the product and the only one that needs an
architecture decision before any code — it is written up in the `loudness` row.

4, 5, 7, 9 and 11 are small and independent; they are polish, and they are the
kind that is cheap now and never gets cheaper.

16 is not a gap. 15 is a product decision, not a defect.
