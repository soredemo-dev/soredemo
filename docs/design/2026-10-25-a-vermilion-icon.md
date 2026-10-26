# A vermilion icon

2026-10-25. The brand kit has a vermilion daruma beside the black one — the traditional colour
(`assets/README.md`, Shu-nuri `#E8452C`). The owner asked for it to be an icon a person can
choose in the app.

## What macOS allows

**There is no alternate-icon API for a Mac app** — iOS has `setAlternateIconName`, AppKit has
nothing like it (checked in the macOS 27 SDK's `NSApplication.h` and `NSDockTile.h`). Two ways
remain, and only one is safe:

- `NSApplication.applicationIconImage` — what the Dock shows **while the app runs**. Nothing on
  disk changes.
- Setting a custom icon on the app's own bundle (`NSWorkspace.setIcon(_:forFile:)`) writes a file
  into a signed bundle and breaks the signature; a notarised app may then not open. Not done.

So the choice is the Dock's, while Soredemo is open, and Settings says so in one sentence beside
the picker. Finder and Launchpad keep the black daruma.

## Decisions

- `AppIconChoice` — black or vermilion, stored like `Appearance`, unknown values black.
- Applied in `applicationDidFinishLaunching`, after launch has set the bundle's icon, and on change.
- The vermilion image is drawn by `scripts/make-daruma-marks.swift` like the fallback bitmaps —
  washi on the icon grid's shape, with its shadow — because the Dock shows this image as given.
  Only the body changes colour; the waiting eye stays ink, as in the brand kit's vermilion mark.

## How it is verified

`AppIconChoiceTests`: black is the default and an unknown value is black; vermilion names an image
the catalog holds (at least 512 points), black names none. Looked at: the Dock with each choice.

**Superseded 2026-10-26.** The vermilion daruma is now the icon the bundle carries and the ink one
is the alternative (`AppIconChoice.black`, image `AppIconInk`); both are drawn from the character's
figure by `scripts/make-character-assets.sh`, which replaced `make-daruma-marks.swift` —
`docs/design/2026-10-26-a-character-not-a-logo.md`.
