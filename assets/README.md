# Soredemo Brand Kit v2

The mark is a **daruma**. It falls over and stands up again, 七転び八起き, which is
what それでも ("even so") means.

- One eye is painted, and it is the **record button**: a red ring on the viewer's
  right, the eye tradition paints first.
- The other eye waits as a **dashed ring**. It is painted in when the work is
  done (目入れ).
- No eyebrows, no beard, no lettering on the body.

## Assets

| Use | File |
| --- | --- |
| App icon | `svg/soredemo-app-icon.svg`, `png/soredemo-app-icon-1024.png` (square; let the OS mask it) |
| Logomark, light background | `svg/soredemo-logomark.svg` |
| Logomark, dark background | `svg/soredemo-logomark-dark.svg` |
| Logomark, vermilion (朱紅) | `svg/soredemo-logomark-shu.svg`, `png/logomark/soredemo-logomark-shu-*.png` |
| App icon, vermilion | `svg/soredemo-app-icon-shu.svg`, `png/soredemo-app-icon-shu-1024.png` |
| One colour | `svg/soredemo-logomark-black.svg`, `-white.svg` |
| macOS menu bar (template) | `svg/soredemo-menubar-template.svg`, `png/menubar/menubarTemplate.png` / `@2x` |
| Website header | `svg/soredemo-horizontal-lockup-black.svg` / `-white.svg` |
| Wordmark | `svg/soredemo-wordmark-*.svg`, `svg/soredemo-japanese-wordmark-*.svg` |
| Favicon | `favicon/favicon.svg` (follows the browser's dark mode), `favicon/favicon.ico`, `favicon/favicon-*.png` |
| PNGs of the logomark | `png/logomark/` at 32–2048 px |
| Palette | `svg/soredemo-color-palette.svg`, `tokens/` (brand and app values) |

## Sizes

- **32 px and below** use the small optical size: a larger face and eye, and no
  dashed eye, which is noise at that size. The menu bar template and favicons
  are drawn this way.
- **Menu bar**: a template image (alpha only). The face is cut out, so macOS
  tints it in light and dark menu bars. Recording fills the eye; paused shows
  two bars.

## Colour

- **Sumi** `#16171B`: body, text. A black daruma is the one kept for business.
- **Shu-nuri** `#E8452C`: the body of the vermilion daruma — the traditional colour, and the
  alternative to the black one. The body only: the record eye stays Shu, on the white face.
- **Washi** `#F4F3EF`: face, background.
- **Shu** `#FA3D4A`: the record eye only. It is the app's record red.
- **Kin** `#C8A24A`: only the moment the second eye is painted.
- **The app's UI** is built from the same four (`Palette.swift`): sumi and washi
  are the panels, **the accent is ink** — washi on the dark theme, sumi on the
  light — and caution is kin's hue. Red is never an interface colour: it is kept
  for recording, so that red on screen always means a recording.

## Don't

- Don't add a face, brows, text or effects to the daruma.
- Don't put the red anywhere but the record eye.
- Don't swap the eyes: the record eye is on the viewer's right.
- Keep clear space of about a quarter of the mark's height.
