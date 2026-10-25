# The editor's layout

2026-10-25. The owner asked for the editor's design and layout, and the features others have,
to be researched and designed. Features are already compared row by row in
`docs/research/landscape.md`; this is about **where things are**, read off the running editor
(a screenshot of 2026-10-25, 1512 × 865 points) and set against what others did this year.

## What the editor does today, measured from the screenshot

| | what is there | what it costs |
| --- | --- | --- |
| above the canvas | a bar: shape, pixel size, Crop, Guides | 44 points of height for four controls changed once per project |
| below the canvas | a transport bar: play, back, time, speed, "Unedited" | its own row |
| above the timeline | a tool bar: undo, redo, split, delete, two zoom buttons, speed, silence, stillness, reset; then timeline zoom | a third row, every control an unlabelled icon, most of them grey until something is selected |
| the inspector's first tab | **Output** — shape, size, "For", resolution, frame rate, format, quality, file size, Export Final Cut XML — and only then **Look** | the settings for the file sit above the settings for the picture; background, padding and corners, which are what a person changes, are below the fold |
| the inspector's tab rail | seven icons, no names | a person learns them by hovering |

Three horizontal bars stacked around the canvas and the timeline, and a first inspector tab that
answers "what file will this make" before "what does it look like".

## What others did in 2026

- **a Rust recorder 0.6** rebuilt its editor around a crop tool and an inspector, moved export onto its own
  screen that shows a size **and a time** estimated from the actual project, and gave the
  timeline ruler scrubbing and a minimap
  ([AlternativeTo](https://alternativeto.net/news/2026/9/cap-launches-v0-6-with-a-rebuilt-video-editor-3d-scenes-and-a-native-desktop-app/),
  [release notes](https://newreleases.io/project/github/a Rust recorder/release/cap-v0.6.0)).
- **Screen Studio** is reviewed again and again for asking a person to touch the timeline as
  little as possible: the automatic result first, every part of it adjustable afterwards
  ([NemoVideo](https://www.nemovideo.com/blog/ai-video-workflows/screen-studio-review),
  [MakerStack](https://makerstack.co/reviews/screen-studio-review/)).
- **Descript** lets a person choose which panels the editor shows
  ([help](https://help.descript.com/hc/en-us/articles/13286878359565)).
- The platform: macOS 27's `visibilityPriority` and `ToolbarOverflowMenu` let a toolbar keep what
  matters and fold the rest by name (`2026-10-25-the-next-round.md`).

## Proposal, in order

1. **Look first, Output to the export sheet.** The inspector's first tab becomes the picture —
   background, padding, corners, shadow, device. Shape, resolution, frame rate, format and
   quality move into the export sheet beside the Export button, where they are read at the moment
   they matter, with the size estimate already shown and **a time estimate from
   `2026-10-25-where-an-export-spends-its-time.md`**: the encoder's measured pixel rate, so a
   person sees that 1080p is about three times faster than full size before choosing. Final Cut
   XML is an export, and goes with them.
2. **One bar fewer.** The canvas bar's four controls move into the window's toolbar with
   `visibilityPriority` — Shape and Crop high, Guides low — and fold into the overflow menu by
   name on a narrow window. About 44 points go back to the canvas.
3. **The timeline's tools say what they are.** Labels under the icons where the width allows,
   icons alone below it; disabled tools say why on hover ("select a clip to split").
4. **An empty lane says why it is empty.** The Zooms lane in the screenshot is a blank strip; the
   log knows whether there were no clicks, or clicks that were not zoomed to and why — which is
   the product's thesis, and the one place it is currently silent.
5. **The ruler scrubs**, as a Rust recorder's now does: drag along the time ruler to move the playhead.

Each is its own change with its own test and its own look, in that order; 1 and 4 change what a
person can learn from the editor, 2, 3 and 5 change how much effort it takes.
