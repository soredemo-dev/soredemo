# A picture as an annotation

2026-09-27. The two Electron recorders place an image — a logo, a screenshot, a sticker — over the
recording. Here it is a sixth annotation shape rather than a new kind of track.

## Decision

**`AnnotationShape.image`, the box the drag drew.** Every annotation is already a drag from one
point to another; for a picture the two points are the box's corners, and the picture is fitted
into it — never stretched — and centred (`AnnotationOverlay.imageFrame`). It inherits everything an
annotation already has: anchored to the recording so it follows the zoom, the same entrance
animations, the same timing controls, one list in one panel.

Rejected: **a separate image track.** It would duplicate the annotation track's timing, selection,
retiming and panel for one new field.

**Copied into the package**, into `pictures/`, beside `backgrounds/` and not in it: a project is a
package that travels, and a picture read from somebody's Downloads would be missing from every
copy. The name is the file's own, checked by the same rule as image backgrounds
(`StageBackground.isSafeImageFilename`), because the compositor joins it onto a path.

**Drawn by Core Image, not as a path.** The five ink shapes are paths drawn into a bitmap;
a picture is the file itself, decoded once into the renderer's image cache and placed per frame by
a transform, so an arriving picture scales without redrawing anything. It sits where annotations
sit: above the camera, below titles and captions.

The panel hides ink, weight and halo for a picture (`AnnotationShape.drawsWithInk`): a control that
changes nothing teaches a person the panel is broken.

## Looked at

Added through the panel to a real project, the picture appeared in the preview at 1.3 s, fitted to
its box, under the caption. The file was copied into the package; `project.json` was not written,
and the test folder was removed afterwards.
