# Soredemo Brand Kit v3 — the daruma, a character

The mark is a **daruma** — it falls over and stands up again, 七転び八起き, which is what
それでも ("even so") means — drawn since 2026-10-26 as a **character**: a round body, and pill
eyes that look, blink and change with what the app is doing. Every file here is drawn by
`scripts/make-character-assets.sh` from the app's own figure (`Core/Sources/Render/DarumaFigure.swift`),
so the website's daruma and the app's are one geometry. Do not edit them by hand; change the
figure and run the script.

- **The right eye is the record button.** While a take runs it is lit in the record red — the eye
  tradition paints first. When the work is done both eyes smile (目入れ).
- **Two faces**: the daruma's white face window with the eyes in it, or the eyes straight on the
  body. The window is the default; a person chooses in the app's Settings.
- **Vermilion by default**, the traditional daruma; ink, paper and gold are designed too, each for
  both faces.

## Assets

| Use | File |
| --- | --- |
| App icon (vermilion; the ink one is the alternative) | `svg/soredemo-app-icon.svg`, `png/soredemo-app-icon-1024.png`, `-ink` |
| The character | `svg/soredemo-character.svg`, `png/character/soredemo-character-*.png` (32–2048 px) |
| Every colour, both faces | `svg/colours/soredemo-character-{shu,ink,paper,gold}[-bare].svg` and PNGs |
| One colour | `svg/soredemo-character-black.svg`, `-white.svg` |
| Expressions | `svg/expressions/` — resting, looking, recording, paused, done, asleep, sad |
| macOS menu bar (template) | `svg/soredemo-menubar-template.svg`, `png/menubar/menubarTemplate.png` / `@2x` |
| Website header | `svg/soredemo-horizontal-lockup-black.svg` / `-white.svg` |
| Wordmark | `svg/soredemo-wordmark-*.svg`, `svg/soredemo-japanese-wordmark-*.svg` |
| Favicon | `favicon/favicon.svg`, `favicon/favicon.ico`, `favicon/favicon-*.png` |
| Preview | `preview/soredemo-brand-preview.png` |
| Palette | `svg/soredemo-color-palette.svg`, `tokens/` |

## Sizes

- **Menu bar**: a template image (alpha only), the body 88% of an 18-point canvas. With a face
  window the window is cut out and the eyes are ink in it; without one the eyes are cut out of
  the body. Recording lights the right eye red; counting down rings it.

## Colour

- **Sumi** `#16171B`: body, text. A black daruma is the one kept for business.
- **Shu-nuri** `#E8452C`: the body of the vermilion daruma — the traditional colour, and the
  alternative to the black one. The body only: the record eye stays Shu, on the white face.
- **Washi** `#F4F3EF`: face, background.
- **Shu** `#FA3D4A`: the record eye only. It is the app's record red.
- **Kin** `#C8A24A`: the gold daruma's body, the count written on the countdown's belly, and the
  glow when a take is done.
- **The app's UI** is built from the same four (`Palette.swift`): sumi and washi
  are the panels, **the accent is ink** — washi on the dark theme, sumi on the
  light — and caution is kin's hue. Red is never an interface colour: it is kept
  for recording, so that red on screen always means a recording.

## Don't

- Don't draw the daruma by hand: run the script, so the app and the kit stay one figure.
- Don't put the red anywhere but the record eye.
- Don't swap the eyes: the record eye is on the viewer's right.
- Don't set the eyes closer than an eye's width apart — they read as one.
- Keep clear space of about a quarter of the mark's height.
