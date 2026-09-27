# One frame as a picture

2026-09-27. Shotbase has screenshots and the ROADMAP has carried `poster-frame` since Phase 2: the
frame under the playhead, saved as a PNG — for a thumbnail, a README, a slide.

## Decision

**The same composition the video is drawn with, read for one frame.** `StillFrameExporter` builds
the `AVVideoComposition` through `CompositionBuilder`, as the MP4 and GIF paths do, and reads it
with an `AVAssetReader` whose time range starts at the playhead. So the picture has the cursor, the
zoom, the card, captions and annotations exactly as the export would — a screenshot of the preview
would have the preview's reduced size and none of that guarantee.

Rejected: **`AVAssetImageGenerator`.** The one-line answer, and measured in this repository to hang
for over ten minutes asking for exact frames of a capture-session movie (`StillnessReader`'s header).

Colour follows the GIF path: the composed frame is declared sRGB on the way in
(`CoreImageFrameRenderer.screenImage`) and written as sRGB, because a PNG with no profile is read
as sRGB everywhere.

## Where it is

*File → Export Frame…* and ⌥⌘E in the editor, at the export's own size (the resolution the Export
pane is set to), not the preview's. The playhead's time is output time — the time of the cut the
preview is playing — and the asset handed over is that same cut, so the two agree by construction.

A time past the end is refused (`noFrameAtThatTime`) and no file is left behind: an empty or
half-written PNG where a person asked for a picture is worse than an error.
