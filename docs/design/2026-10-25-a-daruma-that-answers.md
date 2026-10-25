# A daruma that answers

2026-10-25. Section C of `2026-10-25-the-panel-and-a-daruma-that-answers.md`, built: the mark
as part of how the app behaves, not only its logo. The rule from the research holds — a
character in a product is a state machine whose states are entered by something real, and its
motion carries information (a menu-bar cat: the cat's speed *is* the load).

## What was built, and what was not

| Where | What it does | Status |
| --- | --- | --- |
| panel header | the small mark's eye looks down at the card under the pointer — Screen left, Window middle, Area right | built |
| permissions page | one eye per permission: the record eye fills with Screen Recording, the waiting eye is painted with Accessibility | built |
| the countdown, mid-screen | the daruma replaces the digit in a disc: the count is written on its belly in kin, the record eye's ring drains with each second, and the last second fills the eye (owner's request, 2026-10-25) | built |
| editor, nothing open | the small resting mark above the one thing to do | built |
| the permissions page's body | vermilion when the person chose that icon (`AppIconChoice`) | built |
| sway with the microphone before a take | **not built, on purpose**: there is no level before a take, and opening the microphone to animate a mascot would light the system's microphone indicator for nothing — a privacy cost for decoration |
| tip over and right itself on ⎋ | deferred: the countdown panel closes on ⎋, so there is no surface left to tip on; it needs its own moment |

## Decisions

- **`DarumaPose` is a value; `DarumaView` only draws it.** Every reason the mark moves is a
  static function with a test (`looking(at:)`, `permissions(screenRecording:accessibility:)`).
- **Two styles, because the mark appears in two kinds of place.** *Colour* is the brand kit's
  large mark (record red, dashed waiting eye) for a page about the app — the permissions page.
  *Template* is the menu bar's small mark in the foreground's ink, for a place beside text, where
  a coloured mark would be the loudest thing present and red would claim a recording that is not
  happening — the panel header and the empty editor.
- **The glance is sized for where it is seen.** The prototype's three-unit glance is half a point
  in the 18-point header, and Window, straight ahead, moved nothing. The small mark's eye instead
  drops and travels a row — 40, 52, 64 in the 100-unit box — when any card is under the pointer:
  the cards sit below the header, so the mark looks *down* at them. The cards are 2.2 points
  apart. From rest the face allows less: the resting eye is the baked mark's, already right of
  centre, and with a margin Area can leave it by 4.5 units, 0.8 of a point.
- **The small mark is a filled path, not a Canvas.** Drawn in a Canvas with the foreground's
  shading, it showed in an offscreen render and drew **nothing** in the menu bar's popover — the
  owner's screenshot had the header's space and no mark. A path filled as a view takes the
  foreground style the way the template image it replaced did. The offscreen sheet could not have
  caught this; only the running panel can.
- **The countdown rocks on each count** (owner's request, 2026-10-25): tipped 7° on its round
  base, back past upright to 5°, settling by 2.5° to still, in about 0.8 s — a daruma nudged
  once a second. Pivoted at the bottom, where a real one rocks; still under Reduce Motion.
- **The countdown's timer is the eye's own ring.** The menu bar's arrangement — a second ring
  round the eye — read as a target at 196 points and crowded the face's edge; the eye's ring
  drawn faint, with the second's remainder over it in full red, says the same with one shape.
  Drawn light whatever the system, with a washi rim: the sumi body vanished over a dark screen
  without it (both seen on a contact sheet before shipping). Gold on sumi; washi on vermilion,
  where gold has too little contrast.
- **The ring fills as one path.** The foreground ink is translucent, so a disc drawn over its own
  ring darkened the overlap, and a union of the two cancelled into a white seam. The hole in the
  ring closes instead (even-odd fill).
- **The drawing is the brand kit's geometry**, in the 100-unit box, through
  `CGGeometryBridge.darumaOutline(in:)` — the app names no CG geometry type (rule 5), so the body's
  curves are built where the notch's outline already is.
- **Two places draw one mark** — the script baked `Logomark`, the view draws in code — so a test
  renders the view and compares where its record eye sits within its body to where the baked one
  does.
- **The view reads no preference.** The body's colour is an argument; the permissions page reads
  `AppIconChoice` and passes it. A drawing that read defaults would draw differently on the
  owner's Mac than in a test — which is how the eye-placement test first failed, on a Mac where
  the vermilion icon was chosen.
- **Reduce Motion**: the header and the permissions page animate the pose only when it is off;
  with it on the eye moves without travelling.
- **The hover is held in an object** (`PanelGlance`) the header alone reads, so the pointer moving
  between cards redraws the header, not the panel. Leaving a card clears the glance only if no
  other card took it since — the next card's entry can arrive before the last one's exit.
- Hidden from accessibility: it decorates the controls that carry the meaning, and saying
  "daruma" to a screen reader on every hover says nothing.

## How it is verified

`DarumaPoseTests`: the glance per card; each card moves the header's eye a point from every other
card and ¾ of a point from rest, with every point of the eye's edge inside the face (red on the
first row tried, 42/54/66, which touched the edge); a late exit does not clear the next card's
glance (red on a hover that clears on any exit); each permission paints its own eye and no other;
the drawn record eye within its body against the baked one; the small mark's path is ink and
paper where the baked one is (red with the face's cut-out dropped). `theCountRingsTheEyeAndTheLastSecondPaintsIt` (red on the stub). `DarumaOutlineTests`: the countdown arc
runs clockwise from twelve (red with the direction flipped); the body fills
an off-origin box at twice the scale (red with the offset dropped).

Looked at: a contact sheet of every pose in both styles, light and dark, at 96 and 18 points,
rendered by `ImageRenderer`. **Not yet looked at in the running panel with the pointer over each
card** — the menu bar was not reachable behind a full-screen app when this was built.
