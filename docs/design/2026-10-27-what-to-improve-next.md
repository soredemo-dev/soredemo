# What to improve next

2026-10-27. The owner asked for what the app needs next — features, layout, UI/UX, design. Read
against `docs/research/landscape.md` (two days old; a search today found no competitor release
since), `ROADMAP.md`'s open rows, the two proposals of 2026-10-25 (the editor's layout; the next
round), and **the running app**: its empty editor window, the menu bar panel, and the editor with a
project open (screenshots, 2026-10-26 and today). What is done since those proposals is not
repeated: the inspector leads with Look, export shows a time, the Steps lane, the notch, the
character.

Ranked by what it changes for a person, in four groups. Each item is its own change with its own
design note, test and look.

## A. Get it into people's hands

1. **Ship a release.** `free-recorder-release` is ◐ and `signing-notarization` ☐: everything is
   built and nobody outside this machine can run it. `scripts/build-release.sh` signs and verifies;
   notarisation needs the owner's Apple ID credentials stored once as a `notarytool` profile, and an
   update feed (Sparkle, or a "new version" check that only opens a page) is the remaining design.
   Nothing is uploaded by anything but a person (the publishing rule).
2. **A first run that ends in a recording.** Today the first window is an empty editor that says
   "Record from the menu bar". The permissions page exists; what is missing is the path after it:
   one screen — the daruma, "Record your first take", the three sources as buttons, the shortcut —
   so the first minute ends with a take open in the editor.

## B. Say more with what is on screen (UI/UX)

3. **Empty states that act.** The empty editor (a 1512-point window with one grey line in the
   middle) shows recent takes as cards and the Record and Screenshot buttons, and accepts a dropped
   movie. The menu bar panel shows the last three takes under its buttons.
4. **The Look tab in groups, with looks to start from.** Measured on the running editor: about
   twenty controls in one column — background, blur, device, padding, corners, shadow, border, two
   tilts, cursor size and motion, click effect and its size and opacity, idle hiding, tilt while
   moving, looping, keyboard shortcuts. Group them (Frame · Background · Cursor · Clicks) under
   disclosure headers, and put four or five named looks above them as thumbnails, each one setting
   the group's values — the result first, every value adjustable after, which is what reviewers
   praise others for.
5. **One bar fewer** (2026-10-25 layout proposal, item 2, not yet done): the canvas bar's shape,
   size, Crop and Guides move into the toolbar with `visibilityPriority`, giving the canvas its
   height back.
6. **Timeline tools that say what they are** (item 3, not yet done): labels under the icons where
   the width allows; a disabled tool says why on hover. Today ten grey icons sit above the
   timeline.
7. **The empty Zooms lane says why** (item 4, not yet done): "6 clicks, none zoomed — 4 were on the
   menu bar, 2 too close together", from the log. The product's thesis is silent exactly here.
8. **The menu bar panel, small things:** a live microphone level beside the microphone row (a
   person wants to see it hears them before the take); the shortcut on the Record button; names
   under the four footer icons, or tooltips at least.

## C. Features (from the landscape, re-ranked)

9. **Zoom you can read and shape on the timeline** — each block's ease-in, hold and ease-out
   visible and draggable. The product's centre, and where every competitor is converging.
10. **Zoom that knows what the person was doing** — typing, scrolling and dragging framed
    differently from a click, from the accessibility element rather than pixels.
11. **Masking that proposes itself** — a click on a secure field, and on-device text recognition,
    each proposed with its reason and accepted by a person.
12. **Keys drawn as keys**, from key codes and modifiers only (the privacy rule stands).
13. **Camera layouts per segment**, and split screen stacked for vertical exports.
14. **Export presets by platform** that set the controls the destination presets already do.

## D. Quality that is not seen until it is missing

15. **VoiceOver for the custom controls** (`custom-control-a11y` ☐): the timeline, the waveform and
    the transcript are custom and read as nothing.
16. **Motion with a reason**: the inspector's tab switch and the panel's selection still jump;
    each gets its transition and its Reduce Motion branch (2026-10-25 next round).

## The order proposed

A1 and A2 first — a release is what every other item is for, and the first run is the first thing
a new person meets. Then B3–B4 (what a person sees most), C9 (the product's centre), B5–B8 as
small changes between larger ones, then C10–C14 and D by the owner's choice.
