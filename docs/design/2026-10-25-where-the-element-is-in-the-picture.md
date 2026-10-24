# Where the pressed element is in the picture

2026-10-25. The piece both the guide (`2026-10-25-a-guide-from-the-steps.md`) and the walkthrough
(`2026-10-23-interactive-walkthrough-export.md`, its `WalkthroughHotspot` row) need and neither
has: a box around the element a step pressed, **on the exported picture**.

## Why it is not the recorded frame

The element's frame is recorded in the recording's normalised space. The exported picture is that
recording cropped, placed on a card inside a background, zoomed by the camera and possibly tilted.
A box drawn at the recorded fractions of the picture would be wrong on every picture that is not
an uncropped, unzoomed, untilted full-bleed frame — that is, on nearly all of them.

## The decision: the cursor's own path

The drawn cursor already solves exactly this, every frame: `StageCompositor` builds the frame's
`RenderPlan` — the authored crop composed with the content crop, the base plan fitted to the
cropped size, the camera applied — and `StagePlanner.placement(for:in:)` maps a normalised point
through `RenderPlan.contentX/Y` and the card's tilt. **The box takes the same road**, so the box
and the cursor cannot disagree about where a thing is: if the cursor is drawn on the button, so is
the box.

- `StageCompositor.framePlan(at:outputWidth:outputHeight:sourceWidth:sourceHeight:)` — the crop,
  base plan and camera that `startRequest` computed inline, **moved into one function that
  `startRequest` now calls**, so the guide's plan and the rendered frame's plan are one code path,
  not two that were the same on the day they were written.
- `Render.WalkthroughHotspot.box(of:in:)` — pure: the frame's four corners through
  `StagePlanner.placement`, their bounding box, clipped to the picture, as top-left fractions of
  the output (what an HTML overlay positions by). `nil` for a frame that lands wholly outside the
  picture — a zoom that has left the element — rather than a box clamped to an edge it is not at.
- The guide's HTML draws each step's box over its picture; the Markdown cannot, and does not
  pretend to.

## How it is verified

- `WalkthroughHotspot` in `RenderTests`, on plans that are not identities: a card inset in a
  background (translation), a zoom of 2 centred off-centre (scale), and a tilted card — the box
  lands where `StagePlanner.placement` puts the corners; y is flipped to top-left once; a frame
  outside the picture is `nil`. Mutations: the flip removed; one corner ignored; the clip removed.
- `framePlan` in `CompositingTests`: the card fitted to the cropped size, on a crop that changes
  the aspect; and the existing compositor tests unchanged, so the extraction changed no frame.
- A guide is exported from a real recording and looked at.

## Where it ended

As decided. `StageCompositor.framePlan` is the crop, card and camera that `startRequest` computed
inline; `startRequest` now takes them from the same private function (`framePieces`, which also
hands back the base plan, the composed crop and the authored width the frame's overlays need), so
the extraction moved code and changed no frame — the 79 tests of `StageCompositorTests` pass
unchanged. `WalkthroughHotspot.box(of:in:)` in `Render`; the guide's HTML draws each step's box
over its picture, positioned by numbers the function formats, so no text reaches a style; the
Markdown has none. `GuideHighlight` carries the box into `Framing`, which does not depend on
`Render`. **The crop is handled exactly as the cursor's is** — `StagePlanner.placement` maps
through `contentX/Y` — so whatever the cursor does on a cropped recording, the box does.

Render: five tests on an inset card, an off-centre zoom of 2, a clip, an element the camera left,
and a turned card; three mutations, each red — the flip removed (three tests), a corner ignored
(**only the turned card sees it**: on a flat card the remaining three corners already hold both
extremes, which is why the tilt test exists), the clip removed. Compositing: `framePlan` fitted to
a crop that changes the aspect (half the width, four fifths of the height — a crop that kept 16:9
would fit the same card as none), red with the crop ignored. Core: the HTML box test, red with the
box left out. App tests 321 → 322: each box placed from its own step's element at its own
picture's time, red when placed at the press's time.

**Not seen:** a guide from a real recording with its boxes, on a zoomed and on a tilted card.
