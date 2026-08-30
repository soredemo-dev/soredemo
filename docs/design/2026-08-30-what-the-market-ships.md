# What the market ships, and what this does not

*Researched 2026-08-30. Sources are each product's own changelog, feature page or
release notes; where a claim came from a review rather than the vendor it says so.*

The five reference implementations read from source are covered by
`2026-08-23-five-project-feature-sweep.md`. This document covers the five
**commercial** products a person choosing a screen recorder in August 2026
actually compares — which is a different question, because a shipped product's
feature list is a claim about what a person will expect to find.

Legend: ● shipped, ◐ partial, ○ absent, — not applicable.

## Recording

| | Screen Studio | Motionik | Borumi | Camtasia | ScreenKite | **Soredemo** |
|---|---|---|---|---|---|---|
| macOS native | ● | ● | ● | ● | ● | ● |
| Windows | ○ | ● | ● | ● | ○ | ○ |
| Web | ○ | ○ | ● | ○ | ○ | ○ |
| Region / area capture | ● | ● | ● | ● | ● | ● |
| Window capture | ● | ● | ● | ● | ● | ● |
| iPhone / iPad capture | ● | ● | ◐ | ○ | ◐ | ● |
| Webcam capture | ● | ● | ● | ● | ● | ● |
| System audio | ● | ● | ● | ● | ● | ● *(toggle shipped 2026-08-29)* |
| Microphone selection | ● | ● | ● | ● | ● | ● |
| Pause / resume | ● | ● | ● | ● | ● | ● |
| Multiple takes per scene | ○ | ○ | ● | ○ | ○ | ○ |
| Teleprompter | ● | ○ | ○ | ○ | ○ | ○ |
| Screenshot mode | ● | ○ | ○ | ● | ○ | ○ |

## Cursor

| | Screen Studio | Motionik | Borumi | Camtasia | ScreenKite | **Soredemo** |
|---|---|---|---|---|---|---|
| Smoothed path | ● | ● | ● | ● | ● | ● |
| Size / scale | ● | ● | ● | ● | ● | ● |
| Click ripple | ● | ● | ● | ● | ● | ● |
| Motion blur | ○ | ● | ○ | ● | ○ | ● |
| Hide when idle | ● | ○ | ○ | ○ | ○ | ○ |
| Shape follows the target under it | ● | ○ | ○ | ○ | ○ | ● |
| **Kinetic — points toward the next click** | ○ | ○ | ○ | ● | ○ | **○** |
| **Elevation — always above overlays** | ○ | ○ | ○ | ● | ○ | **○** |

## Framing and the stage

| | Screen Studio | Motionik | Borumi | Camtasia | ScreenKite | **Soredemo** |
|---|---|---|---|---|---|---|
| Auto zoom on clicks | ● | ● | ● | ◐ | ● | ● |
| Manual zoom keyframes | ● | ● | ● | ● | ● | ● |
| Wallpaper / gradient / solid | ● | ● | ● | ● | ● | ● |
| Padding, radius, shadow | ● | ● | ● | ● | ● | ● |
| Crop | ● | ● | ● | ● | ● | ● |
| Aspect presets per platform | ● | ● | ● | ● | ● | ● |
| Built-in scene layouts | ○ | ○ | ● | ● | ○ | ○ |
| Green screen / background removal | ○ | ○ | ○ | ● | ● | ◐ *(camera only)* |

## Sound

| | Screen Studio | Motionik | Borumi | Camtasia | ScreenKite | **Soredemo** |
|---|---|---|---|---|---|---|
| Noise removal | ◐ | ● | ◐ | ● | ● *(on-device)* | ● *(on-device)* |
| Loudness normalisation | ◐ | ● | ○ | ◐ | ◐ | ● |
| Silence removal | ● | ○ | ○ | ◐ | ● | ● |
| Music bed with ducking | ○ | ● | ● | ● | ○ | ● |
| Per-track placement | ◐ | ● | ● | ● | ● | ● |
| Scrub audio | ● | ○ | ○ | ● | ○ | ● |

## Text on the picture

| | Screen Studio | Motionik | Borumi | Camtasia | ScreenKite | **Soredemo** |
|---|---|---|---|---|---|---|
| Transcription | ● | ● | ● | ● | ● | ● |
| Captions burnt in | ● | ● | ● | ● | ● | ● |
| Edit the video by editing text | ○ | ○ | ○ | ● | ◐ | ● |
| Karaoke-style captions | ○ | ● | ○ | ● | ○ | ○ |
| Keystroke overlay | ● | ○ | ○ | ○ | ● | ● |
| Annotations / shapes | ○ | ● | ● | ● | ● | ● |
| **Freehand sketch** | ○ | ○ | ○ | ● | ● | **○** |
| Redaction / blur a region | ○ | ● | ○ | ● | ○ | ● |

## Cutting

| | Screen Studio | Motionik | Borumi | Camtasia | ScreenKite | **Soredemo** |
|---|---|---|---|---|---|---|
| Timeline with clips | ● | ● | ● | ● | ● | ● |
| Speed / time remap | ● | ● | ● | ● | ● | ● |
| **Transitions between clips** | ● | ● | ● | ● | ● | **○** |
| Remove dead air (picture) | ○ | ○ | ○ | ○ | ○ | ● |
| Remove silence (sound) | ● | ○ | ○ | ◐ | ● | ● |
| Export a range | ● | ● | ● | ● | ● | ● |

## Out

| | Screen Studio | Motionik | Borumi | Camtasia | ScreenKite | **Soredemo** |
|---|---|---|---|---|---|---|
| MP4 / H.264 | ● | ● | ● | ● | ● | ● |
| 4K 60 | ● | ● | ● | ● | ● | ● |
| GIF | ● | ● | ● | ● | ● | ○ |
| Transparent video | ○ | ○ | ○ | ● *(WebM)* | ○ | ● *(HEVC/ProRes)* |
| Hand off to a real NLE | ○ | ○ | ○ | ◐ | ○ | ● *(FCPXML)* |
| Export progress with an ETA | ● | ● | ● | ● | ● | ● |
| **Share link / cloud** | ● | ● | ● | ● | ◐ | **○ — by design** |

## What this reading changes

**Two gaps worth taking seriously.**

*(A third was listed here and was wrong: region capture was marked absent on the
strength of a week-old sweep that was never re-checked. It ships —
`RegionPickerOverlay`, the "Area" card, `RegionCapture` handled through every
branch of `CaptureSource`. Corrected 2026-08-30. A comparison table is a claim
about this codebase as much as about anyone else's, and this row was not
verified against it.)*

*Transitions* are on all five. A cut with no transition is a defensible default
and an editor that cannot make one at all is a missing feature, not a stance.

*A system-audio toggle.* ~~Soredemo records system audio unconditionally.~~
**Closed 2026-08-29.** The objection that had kept it out — an unfed
`AVAssetWriter` input starves a fed one — was still accurate and no longer
binding once `HeldAudioQueue` landed; see `hearing-the-scrub.md`. Left struck
through rather than deleted, because the reasoning that kept it out for a phase
is the useful part.

**Two ideas nobody else has that are worth keeping.** Removing dead air from the
*picture* appears on none of the five — every product that trims does it from the
sound. And handing the edit to Final Cut as FCPXML is the only escape hatch in
the list; everything else is a closed pipeline ending in an upload.

**One idea from Camtasia worth stealing.** *Kinetic cursor* — the cursor points
toward where it is about to click. It is a real reading aid rather than a
flourish, and the data it needs is already recorded: `AXObserver` writes the
click chain, so the next click's position is known at render time. `Cursor
elevation` — the cursor always drawn above annotations — is the same shape and
one line of z-order.

**The one row where being different is the product.** Share links and cloud
storage are on every product here. Soredemo has none and will have none: nothing
this app produces leaves the machine without a person sending it. That row is
not a gap.


---

# A second pass, from the interfaces rather than the feature pages

*2026-08-30, later the same day. The table above was built from what each product
SAYS it does. This section is built from 113 screenshots and demo videos of four of
them running — which is a different question, because a feature page names features
and an interface shows what using them is like.*

Sources: 42 screenshots of one recorder's whole settings tree and editor, 27 of
another's, and 30 demo videos of the two remaining, read as extracted frames. Nothing
here is from a marketing page.

## What the interfaces have that no feature page mentioned

**A default project-name template.** `{target_name} ({target_kind}) {date} {time}`
with a live preview under the field — "Safari (Window) 2026-08-30 09:41 AM". A second
product has the same idea with its own placeholder set. A third names recordings
`recording-1757706490027`, which is a Unix timestamp in milliseconds, and is the
control group for why the first two bothered. **Soredemo has no template.**

**A user-editable exclusion list.** One recorder shows the windows it hides from a
recording as removable chips — its own panel, its settings, its camera, its region
picker, its teleprompter — with Reset and Add. Soredemo's `CaptureExclusions` decides
the same thing and shows none of it. The chips also leaked a feature the feature page
never mentioned: that product has a **teleprompter**.

**Per-device format pickers.** A gear beside each camera opens its resolution and
frame-rate list — including 1552×1552 and 1080×1920, so a portrait or square camera
is a choice rather than a crop. A gear beside each microphone offers 96 / 88.2 / 48 /
44.1 kHz. Soredemo picks a microphone and takes whatever format it offers.

**An editable keymap.** One recorder lists eleven global shortcuts, all unbound by
default. The other ships a full NLE keymap — blade mode, ripple delete, ripple
editing, snapping, grouped editing, markers with notes that extend into ranges, in and
out points, keyframes with an inline per-property animation editor, and five saved
panel layouts. Soredemo has one hard-wired shortcut.

**Crash-recoverable recording, offered as a choice with its cost written on it**:
"Record in fragments that can be recovered after a crash or power loss. Slightly
larger files during capture." Soredemo's segmented writer and `RecordingHealth` are
most of that machinery already, and none of it is a sentence anybody can read.

**An out-of-process muxer**, in the same product's experimental pane: "Run the
fragmented-MP4 muxer in an isolated subprocess so muxer crashes can't take down your
recording."

**A notch overlay.** Screen capture records straight through the physical notch, so a
recording of a notched MacBook shows an unbroken menu bar. That product draws the
notch back over the picture, follows the crop and zoom automatically, and records the
real notch geometry at capture time so older recordings can be positioned by hand.

**Scrolling capture with fixed-header detection**, for a long page — a screenshot
feature, not a video one, and not something any feature page listed.

**An agent surface, in both.** One installs a CLI "for terminals, agents, scripts and
local automation". The other has a `CLI / MCP` tab in the editor itself and lists its
own agent commands in settings: `workspace info --json`, `sessions list`,
`project list`, `skills list`, `tool list`. Soredemo's `ROADMAP.md` still has this
unstarted — and `docs/FEATURES.md`'s framework table names **two package dependencies
for it**, the MCP Swift SDK and Swift Argument Parser, where D6 rule 4 is "no manifest
declares a package dependency" and a plugin scans every `Package*.swift` on both build
paths to enforce it. That contradiction is in this repository, not in theirs, and it
has to be settled before the row is started rather than discovered while starting it.

## What the demo videos show about the output

**Word-by-word caption highlight is universal.** Both video products' own marketing
captions light the spoken word and dim the rest. Soredemo has it
(`highlightsSpokenWord`, `unspokenOpacity`) and, since 2026-08-30, a preset that turns
it on in one click.

**Shadow is four controls, not two.** One product exposes Shadow, then Advanced ▸
directional shadow, distance, angle, blur — plus a separate *inset*: an inner edge
with its own colour, opacity and balance. Soredemo derives an ambient and a key shadow
from two knobs and fixes the key's direction downward, on the stated grounds that
"inventing a direction would be a value the style cannot round-trip". That reasoning
holds for a two-field style and stops holding the moment direction is a field.

**Zoom blocks carry their own provenance on the timeline.** A block reads
`🔍 2x · Auto` or `🔍 2x · Manual`. Soredemo distinguishes a gate-authored zoom from a
reviewer's override in `FramingReview` and does not say which is which on the
timeline. Showing it is the same argument this project makes everywhere else: a
derived value should be visibly derived.

**Clip operations are a context menu, not a mode**: Set speed ▸, Remove, Split, Set
trim, Merge with next, Merge with previous.

**Device frames are per model AND per colour** — four iPhone generations, each with
its own finishes. Soredemo's `DeviceFrame` has models; it has no colours. And window
chrome is a frame type of its own in one product — macOS traffic lights, a Windows
title bar, a browser with an address bar — which Soredemo has no equivalent of.

## Corrections to the table above

* **System audio** was `◐ (recorded, no toggle)` and is now `●`. The toggle shipped
  2026-08-29.
* **Teleprompter**: found in one product's exclusion-list chips rather than on any
  feature page — but that product is one of the open-source ones covered by
  `2026-08-23-five-project-feature-sweep.md`, not a column in the table above, so no
  row here changes. Recorded because the method is the point: a recorder's list of
  windows it hides from itself is a list of every window it has.
* Two rows this pass could NOT verify and has left alone rather than guessing:
  Borumi and Camtasia were not in the captured material at all, so every figure in
  their columns is still second-hand from a feature page.

## What this second pass changes

Nothing about the publishing rule, and nothing about the two ideas that are this
project's own. What it adds is a class of gap the first pass could not see: **the
first table is about capability, and almost everything above is about legibility.**
A template that shows the filename it will produce, an exclusion list you can read, a
setting that names its own cost, a zoom block that says whether a machine or a person
put it there — none of those is a feature. They are the same feature this project
already has, said out loud.

The caption editor is the exception, and it is not a legibility gap. It is in
`what-a-caption-editor-is.md`, with the standards the numbers come from, because a
cue whose timing is wrong cannot be corrected in this app at all.
