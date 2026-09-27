# Light and dark

2026-09-27. The owner asked for a light theme alongside the dark one. `Theme.swift` said "Dark,
and not adaptive", with a reason that is still true: chrome around a picture shifts how its
colours read, and a light surround makes a recording look darker and less saturated than it is.
This document keeps that reason and drops the conclusion drawn from it — the reason is about the
picture's surround, not about the whole window.

## Decisions

**An Appearance setting — System, Light, Dark — defaulting to System**, applied once through
`NSApplication.appearance`, so every window, sheet and menu agrees without each view being told.

**Three places stay dark in both, each for a reason that does not depend on taste:**

| Surface | Why |
| --- | --- |
| the preview's backdrop (`Surface.preview`, black) | the reason above: it is the surround of the thing being judged |
| floating panes over a person's screen — recording bar, countdown, region and window pickers | they sit over whatever is being recorded; measured over a white page, a light countdown was unreadable (`CountdownPanel`) |
| the notch surface | the notch is black hardware; a light surface growing out of it reads as a hole |

Everything else — editor window, inspector, timeline, settings, permissions — follows the
appearance.

**Measured, 2026-09-27: SwiftUI's `.environment(\.colorScheme, .dark)` wins over the app's
appearance when a dynamic `NSColor`-backed `Color` resolves** — a probe rendered one such colour
under all six combinations of app appearance {light, dark} × environment {unset, light, dark},
and the environment decided every time it was set. So the tokens become adaptive and the three
dark places keep their existing pins; nothing inside them needs to know about themes.

## The palette, and what measuring it found

Every pairing below was computed as a WCAG contrast ratio by script, not judged by eye. Needs:
4.5 for text, 3 for secondary text and for a control or block against what is behind it.

**The dark theme already failed four of them, and they are fixed in the same change:**

| Pairing | Was | Now |
| --- | --- | --- |
| secondary text on a raised surface | 4.22 (`#8C8C94`) | 5.04 (`#9A9AA3`) |
| tertiary text (60 % of muted) on base / panel / raised | 2.79 / 2.71 / 2.44 | ≥ 3.40 (`#7C7C85`, solid) |
| white label on the accent (`.borderedProminent`) | **2.39** (`#8FA2FF`) | 4.99 |

**Lanes: one family by PERCEIVED lightness, not by HSB brightness.** The rule was "the same
colour with the hue turned, so they stay equally bright". HSB brightness is not perceived
brightness — at HSB(·, 44 %, 100 %) green and yellow are far lighter than blue and violet — and on
a light ground it showed: five of eight lanes fell under 3:1. The lanes are now OKLCH with fixed
lightness and chroma per theme and only the hue turned, which is what the rule meant:

| | lightness | chroma | block vs its track, worst lane |
| --- | --- | --- | --- |
| dark | 0.82 | 0.085 | 5.13 |
| light | 0.46 | 0.09 | 3.28 |

Hues (OKLCH degrees): video 268, audio 155, zoom 300, text 75, caption 205, hide 350, mark 30,
chapter 125 — the old roles, re-measured on the OKLCH wheel. The closest pair is 30°. At light
0.46 the caption hue lies a hair outside sRGB and is clipped; its contrast was measured on the
clipped value.

A lane is also identified by its row and its header text, so colour is never the only cue — the
colour-vision check the palette tooling would run was not available here and was not run.

**The accent splits in two.** As a fill under a white label it needs to be dark in both themes
(`oklch(0.55, 0.15, 268)` dark, `oklch(0.50, 0.13, 268)` light); the video lane keeps the light,
airy blue in dark mode. Text on a lane-coloured block is near-black on the dark theme's light
lanes and near-white on the light theme's dark ones — measured ≥ 5.78 everywhere.

**One caution colour**, for notes that are not errors (a chapter moved past a cut, a redaction
that covers nothing). `.orange` was used and is 2.2:1 on a light panel.

## Alternatives rejected

- **Light chrome with a light preview surround.** The reason `Theme` gave is right, and a light
  editor that misrepresents the recording is worse than a dark one.
- **Keep HSB lanes and darken each by hand.** Eight hand-tuned numbers that agree only by
  accident; the OKLCH rule is one pair of numbers per theme.
- **`Color` assets in a catalogue.** The values are derived (OKLCH, hue per role); computing them
  keeps the rule in code where the numbers come from, rather than sixteen hex values in a file
  nothing checks.
