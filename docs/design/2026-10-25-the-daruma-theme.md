# The daruma theme

2026-10-25. The mark became a daruma (`assets/README.md`), and the owner asked for the app's
violet to go with the old mark: the theme is the daruma's four colours — **sumi, washi, shu,
kin**: black, white, red and gold.

## What each colour does

| Colour | Brand value | In the app |
| --- | --- | --- |
| sumi | `#16171B` | the dark theme's panel, and the light theme's primary text |
| washi | `#F4F3EF` | the light theme's panel, and the dark theme's primary text |
| shu | `#FA3D4A` | the accent — a selected control, a fill under a white label, a word that acts |
| kin | `#C8A24A` | caution — a note that is not an error |

**Why red is the accent and not gold.** The accent is the app's one colour, and the mark's one
colour is its record eye. A recorder whose own colour is its record button is saying the same
thing twice, on purpose. Gold is the brand's rarest colour — the moment the second eye is painted
— and caution is the rarest note the app shows, so the two meet.

**The brand values are hues, not the exact fills.** `#FA3D4A` under a white label is 3.6:1, short
of the 4.5 a label needs; drawn as words on washi it is 3.3:1. So every token keeps the brand
colour's OKLCH **hue** (shu 23°, kin 86°) and takes the lightness and chroma its job needs, as
`2026-09-27-light-and-dark.md` did for the violet. Measured by script before writing:

| Token | Dark | Light |
| --- | --- | --- |
| accent, white label on it | `#C52B30`-ish, 5.6:1 | `#BE222A`-ish, 6.1:1 |
| accent against the panel | 3.2:1 | 5.5:1 |
| accent as text, worst surface | 6.6:1 | 5.3:1 |
| caution on the panel | 9.5:1 | 5.0:1 |

The grounds take sumi and washi themselves as the panel, with the base a step further back and the
raised surface a step forward, as before.

## What does not change

- **The lanes.** Eight hues at one lightness, chosen to tell tracks apart; the video lane's 268°
  is a lane, not the brand. Retuning them is a separate question with its own measurements.
- **`Signal.record`** is already `#FA3D4A`; the accent is a darker red, so a selected control and
  the record button are related and not identical.
- **The preview's black backdrop**, and the panes pinned dark.

## How it is verified

`PaletteTests` already measures every pairing above; the values change, the tests do not. Two new
tests pin the theme to the brand: the accent and caution are within a few degrees of shu's and
kin's hues, and the panels are sumi and washi. Mutations: the accent back to 268°; the light panel
back to `#F4F4F7`; the raw `#FA3D4A` as the accent, which the white-label test must refuse.

## Where it ended

As decided. `Palette.Brand` holds the four brand values and `RGB.oklchHue` measures a token's hue;
the dark panel is sumi and the light panel washi, and primary text is the other one.

`PaletteTests`, two new: the hue of sRGB red against CSS Color 4's 29.2339° (positive control), and
`theThemeIsTheDarumas`, which went red on all four of its claims in both themes while the palette
was still violet — eight failures — and green on the new values. Mutations, each red on its own
test: the light panel back to `#F4F4F7` (`theThemeIsTheDarumas`); the raw `#FA3D4A` as the dark
accent (`aLabelReadsOnTheAccentAndTheAccentOnThePanel`). Every existing contrast test passes
unchanged on the new values.

## Revised the same day: the accent is ink, not red

The reason given above — "the accent is the app's one colour, and the mark's one colour is its
record eye" — did not survive research. Across design systems red reads as error and
destruction, and the products nearest this one keep their red for recording alone (Loom's record
token, GNOME's capture button, YouTube's mark); the brand kit's own rule, "don't put the red
anywhere but the record eye", said so first. `Start Recording`'s comment had recorded the same
decision a month earlier — "on macOS red means destructive" — and the red accent silently undid
it. See `2026-10-25-the-panel-and-a-daruma-that-answers.md` for the sources.

So: **the accent is ink** — washi on the dark theme's sumi, sumi on the light theme's washi — with
`onAccent`, the paper it is not, for a label on it. Caution keeps kin. The record red is drawn by
`Signal.record` and by nothing in the palette.

`PaletteTests`: `theThemeIsTheDarumas` now asserts the accent is the other theme's ink;
`noControlIsDrawnInTheRecordRed` asserts every control token is near-grey (OKLCH chroma under
0.02), with a positive control for the chroma (sRGB red, 0.25768). Both went red on the red
palette — four failures across the two themes — and green on ink.
