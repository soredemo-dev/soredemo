# The notch says what the panel says

2026-10-25. The panel was redesigned this morning (`2026-10-25-the-panel-and-a-daruma-that-answers.md`):
the target is chosen, then Record or Screenshot. The notch — the same recorder, opened by
pointing at the camera housing — still has the old shape: a Record/Screenshot switch in its left
wing, and three target buttons that each start at once. A person who uses both now meets two
recorders with two grammars.

## What the research says about the notch

Notch apps share one model: hovering the housing opens a black surface that grows out of it, and
without a notch the same surface is a pill or bar at the top of the screen
([How-To Geek](https://www.howtogeek.com/these-apps-turn-your-macbook-notch-into-a-dynamic-island/),
[FavTray](https://favtray.com/blog/dynamic-island-for-mac-notch-apps),
[Notchy](https://notchy.dev/best-mac-notch-apps/)). Apple itself does nothing interactive with the
notch, even in macOS 27. So the notch is borrowed space, and the rule that follows is restraint:
the open notch is the panel's grammar in the notch's material — black, white text, the record red
as the only colour — not a second design.

## Decisions

- **The switch goes.** The left wing becomes the daruma — the template mark in white — and the
  right wing keeps the shortcut.
- **The targets are chosen, and the choice is the panel's.** Screen, Window, Area and connected
  devices select, through the same `RecordingCoordinator` calls the panel uses, so choosing Window
  in one is choosing it in the other. The selection logic moves from `MenuBarTargets` onto the
  coordinator (`isChosen`, `choose`), one place for both surfaces.
- **The bottom row is the act**: microphone and camera on the left, as now; **Screenshot** and
  **Record** on the right — Record a white capsule with an ink mark, Screenshot an icon. One
  press starts, from the notch as from the panel.
- **Recording (live)** is unchanged: the pulsing dot and time, the level meter, pause, save the
  last seconds, stop.

## How it is verified

- `CaptureEntryTests` already holds the doors; a test that choosing through the coordinator's
  `choose` sets the preference and clears a chosen device.
- Looked at: the open notch, by moving the pointer to the housing, in the running app.

## Where it ended

As decided, with one correction made while looking. The coordinator holds the choice —
`choose(_:)`, `choose(device:)`, `isChosen` — and both surfaces call it; `capturePurpose` is
`private(set)`, set by `start(_:)` alone. The open notch: the mark in the left wing, the shortcut
in the right, three target cards (and devices) that select, and `NotchActions` — Screenshot and
Record — **in the microphone and camera row, not below it.** As a row of its own it was cut in
half by the surface's fixed depth: the same defect the speakers hint met on 2026-09-29, met
again and seen on the running notch before anything else. The hint is an icon now, its sentence
its label and help.

Tests: `CaptureChoiceTests` (choosing remembers the target and sets a device aside; red with the
device not cleared). `theNotchOffersEveryWayOfStartingThatTheMenuDoes` now compares the
`start(.…)` / `choose(.…)` / `choose(device:)` calls each surface makes — red with the notch's
device choice written as an assignment — and `neitherSurfaceSwitchesBetweenATakeAndAPicture`
replaces the test that required both to carry the switch — red with a `capturePurpose` read put
back into the panel. The panel's dead "Start Recording" key left all ten tables
(`noStringTableKeyIsUnreachableFromTheSource` found it).
