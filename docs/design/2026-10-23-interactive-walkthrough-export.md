# Interactive walkthrough export

2026-10-23. The first of the features only an observation log makes possible
(`2026-10-22-what-macos-27-makes-possible.md`, item 1). A design to review before any code.

## What it is

One recording, exported as **a web page a viewer clicks through**: each step is a still of the
screen at the moment before a click, with the control that was clicked outlined; the viewer
clicks it (or presses →) and the page advances to the next step. It works offline, in any
browser, from a single file, with nothing sent anywhere.

The tools that make these today are hosted services billed per seat, and they build them by
having a person record clicks in a browser extension. Soredemo already has every click, the
element under it and its frame on screen — in every app, not only a browser. The walkthrough is
a derived export of evidence that is already on disk.

## The person's flow

1. **Export → Walkthrough.** A new destination beside MP4, GIF and FCPXML.
2. **A step list appears in the inspector**, proposed from the take's clicks:
   - a thumbnail of each step with its hotspot outlined;
   - a caption proposed from what was being said at that moment (the transcript sentence that
     contains or precedes the click), and otherwise *Click "Export"* from the element's title
     and role;
   - its origin beside it, as every derived value in this app has: *from the click at 0:42*.
3. The person **removes, merges, retitles and reorders** steps. An edited caption is theirs and
   is never replaced by a re-derivation (the producer-value rule).
4. **Export** writes one `.html` file. A *Without screen text* switch — the same choice as *Save a
   Copy for Sharing* — uses the role ("button") instead of the title in proposed captions.

## What the viewer sees

- The step image, scaled to the window, with the hotspot as a soft pulsing outline (a static
  outline under *Reduce Motion*).
- The caption under it, and *Step 3 of 9*.
- Click the hotspot, press → / Enter / Space to advance; ← to go back. A wrong click shows where
  the right one is, briefly — it never blocks.
- A final step: *Done*, and *Start again*.
- Light and dark from the viewer's system; keyboard-reachable everything; each image's `alt` is
  the caption; the hotspot is a real `<button>` with the caption as its label, so a screen reader
  user can complete the walkthrough.

## System design — where each part lives

The seam every feature here follows (`AGENTS.md` rule 1, MVVM in the app):

| Layer | Type | Job | Tested by |
| --- | --- | --- | --- |
| `Core/Overlays` (Foundation only) | `WalkthroughPlan` | steps from the framing plan's clicks, the edit timeline and the transcript: which clicks survive the cuts, merging a double-click into one step, the proposed caption, each step's origin | unit tests, no screen |
| `Core/Overlays` | `WalkthroughPlan.Step` overrides | a person's caption, removal, merge and order, stored in `EditState`, winning over derivation | producer-value test: an authored caption survives re-deriving |
| `Core/Render` | `WalkthroughHotspot` | the clicked element's frame mapped through **the same `RenderPlan` the still is drawn with** — crop, aspect variant, tilt, zoom — so the outline is where the button is in the image, not where it was on the display | the tilted-cursor test's method: paint a known square, find it in the rendered still |
| `Core/Overlays` | `WalkthroughDocument` | the HTML: escaped text, inlined images, the viewer script; pure string building | parsed with `XMLDocument`/a DOM check; every caption escaped |
| `Compositing` | stills | `StillFrameExporter` at each step's moment, through the composition the video uses | existing still tests plus one per step time |
| app | `WalkthroughModel` (`@Observable`) and `WalkthroughPanel` | the step list, edits, export progress | model tests as the other inspector models have |

## Edge cases, each with its answer

| Case | Answer |
| --- | --- |
| A click inside a cut | not a step; the list says *3 clicks were in cut sections* rather than dropping them silently |
| A double-click, or a click-drag | one step; a drag's hotspot is where it began, the caption says *Drag* |
| A click with no accessibility element (blind, refused, timed out) | the hotspot is a circle at the click point; the caption has no title to use and says so |
| The element's frame is from another display arrangement (a reconfiguration mid-take) | mapped through its own geometry revision, as the framing plan already does; a frame that cannot be mapped falls back to the click point and the step says why |
| A click on a secure text field | the step is kept, and its still is offered for redaction before export |
| Very many clicks (a long take) | all are proposed; consecutive clicks within one window and under two seconds apart are offered as one step |
| A zoomed shot at the click | the still is the frame the video shows at that moment, zoom included, and the hotspot goes through the same mapping |
| A caption with `<`, `&` or quotes; right-to-left text | escaped; `dir="auto"` on caption elements |
| A 4K still per step | encoded as JPEG at the export resolution the person chose; the file states its size before it is written |

## What this is not

Not a hosted page, not analytics, not a viewer account. **Nothing leaves the Mac**: the export is
a file the person sends, the same rule as every other export.

## Verification, before it is called done

1. Unit: steps from a fixture take — cuts, a double-click, a blind click — with origins.
2. Producer-value: an authored caption survives a re-derivation.
3. Pixel: a hotspot outline lands on a painted target through crop, a 9:16 variant and tilt.
4. Document: the HTML parses; every caption is escaped; every image has `alt`; every hotspot is a
   `<button>` with a label.
5. A person clicks through an exported walkthrough in Safari and in a second browser.
