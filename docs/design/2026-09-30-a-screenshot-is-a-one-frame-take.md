# A screenshot is a one-frame take

2026-09-30. Item 5 of the list approved after reading `a utility suite` (GPL-3.0; ideas only).
Its screenshot tool captures an area, a window or a screen, then annotates, crops, redacts and
puts a background behind it. Soredemo has every one of those — for video.

## The question

Build a screenshot editor, or make a screenshot something the editor that exists can open?

| Option | What it costs | What it gets |
| --- | --- | --- |
| a second editor for stills | a canvas, an inspector, annotation and redaction UI a second time, and a second renderer path that can drift from the first | a UI shaped for pictures from the start |
| **a screenshot becomes a short still movie, opened in the editor** | a capture branch and a writer | the stage, device frames, crop, redaction, every annotation (steps and highlights included), and *Export Frame* — through the renderer the video uses, so a picture and a video of the same thing cannot disagree |

**Decision: the second.** The editor already treats a file with no observation log honestly — no
cursor, no zooms, nothing made up (`openVideo(at:)`) — and *File → Export Frame…* already writes
the composed frame as an sRGB PNG at export size (`2026-09-27-one-frame-as-a-picture.md`).

## How

1. **Where it starts.** Every surface that offers Screen, Window and Area for a recording offers
   them for a screenshot — the notch and the menu bar panel together, because
   `theNotchOffersEveryWayOfStartingThatTheMenuDoes` already holds the two to one list.
2. **One branch, at the one place the three pickers meet**: `sourceSelected(_:)`. A purpose chosen
   before the picker opens says whether the chosen source becomes a take or a picture. No
   countdown and no camera for a picture.
3. **The same filter a recording would use**, so the Dock, the menu bar, the widgets and
   notifications stay out of a screenshot exactly when they would stay out of a video, and this
   app's own windows are never in it. Captured by
   `SCScreenshotManager.captureImage(contentFilter:configuration:)`, at the source's pixel size.
4. **Written as a still movie** a few seconds long, so an annotation added at the playhead has
   room to be seen, in a codec that keeps text sharp. Then opened with `openVideo(at:)`.

## What it is not yet

**The editor still shows a timeline for a picture.** A picture mode — the timeline hidden, *Export
Frame* as the primary action, *Copy* beside it — is the next step, and it is a UI change on a
path that already works rather than a new path. Pinning a screenshot to the screen is not in this
step either.

**Nothing leaves the machine.** A picture is saved or copied by the person, like every export.
