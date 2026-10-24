# Splitting the menu bar panel

2026-10-24. `Soredemo/Recording/MenuBarRecorder.swift` is 806 lines: the menu bar label, the
panel behind it, and seven private types and sections. Read in full before this was written.
Same aim as the `2026-10-23-splitting-…` documents: each type one job, each section its own view
reading only what it draws.

## What is in it

| Lines | What |
| --- | --- |
| 24–72 | `MenuBarRecorderLabel`: the icon, and the two jobs it holds because it is always built (open the editor when a recording finishes; the permission page on first run) |
| 85–138 | the panel's stack and header |
| 140–216 | the purpose picker and the target cards, phones included |
| 218–420 | the microphone row and the camera row, with the device refresh hung on the microphone row |
| 422–519 | the frame-rate and countdown rows, their shared `settingRow`, and a CoreGraphics query for display refresh rates |
| 521–609 | the start button, the recording controls, the failure note, the hotkey warning, and `toggleShortcut` |
| 611–806 | the footer and its four private views |

## Found while reading

- **The shortcut's spelling lives on a view and four other files reach into it.** `RecordingBar`,
  `NotchSurfacePanel` (twice) and `SettingsWindow` read `MenuBarRecorderPanel.toggleShortcut`.
  The key it spells is registered in `GlobalHotkey` (`toggleRecordingKeyCode`,
  `toggleRecordingModifiers`); the string and the registration are two statements of one fact,
  in two files, with nothing comparing them. The spelling moves to `GlobalHotkey`, beside what it
  spells, with a test that pins all three together.
- **It is spelled `⌘⇧R`, and macOS writes `⇧⌘R`.** The system's order is ⌃⌥⇧⌘, and this file's
  own footer already writes `⇧⌘O`. Corrected to `⇧⌘R`.
- **The device refresh is hung on the microphone row.** The `.task` that refreshes microphones,
  cameras AND phones, and the two connect/disconnect observers, are modifiers of `microphoneRow`.
  Correct only while that row exists; it is built for a take and not for a screenshot, so a
  phone plugged in with Screenshot selected is not refreshed by it. They move to the panel.
- **Comments that disagree with the code or sit on the wrong declaration.**
  - `frameRateRow`'s paragraph ("only rates this display can produce") sits above
    `settingRowPickerWidth`, and says "this display" where `displayRefreshRates` says, at length,
    every display.
  - `SettingsPanelLink`'s long paragraph sits above `FooterIcon`, and names "the Permissions row
    beside this one", which the footer no longer has.
  - The camera row's comment says it is hidden when access was refused; it is not — the row
    stays and says so (`wasRefused`), which is what `CameraController.wasRefused`'s own comment
    asks for.
  - Two paragraphs above the camera's resolution label, the first about video effects, which
    have their own paragraph below.
- **A CoreGraphics query in a view.** `displayRefreshRates` asks the window server for every
  display's mode. It moves to `DisplayRefreshRates` in `Recording/`.

## The split

Into `Soredemo/Recording/MenuBar/` — the label, the panel and its sections are more than three
files about one narrower thing (`ARCHITECTURE.md`'s rule of threes).

| File | Holds |
| --- | --- |
| `MenuBarRecorderLabel.swift` | the label, unchanged |
| `MenuBarRecorderPanel.swift` | the stack, the header, the device refresh, the failure and hotkey notes |
| `MenuBarTargets.swift` | the purpose picker, the target cards, the phone rows, `TargetCard` |
| `MenuBarSourceRows.swift` | the microphone and camera rows |
| `MenuBarSettingRows.swift` | frame rate, countdown, the shared row shape |
| `MenuBarRecordingControls.swift` | the start button, the controls while recording, `PanelLevel` |
| `MenuBarFooter.swift` | the footer and its buttons |

`DisplayRefreshRates.swift` sits in `Recording/` beside the other platform reads.

## How it is verified

- The shortcut: a test that the key code is R, the modifiers are ⇧ and ⌘ and nothing else, and
  the spelling is `⇧⌘R`. Mutations: the spelling, the key code, a modifier dropped.
- The rest is a move. The placement rules (`everyViewTypeInTheAppIsBuiltSomewhere`,
  `everyPrivateViewInTheAppIsPlacedSomewhere`) catch a section that stops being built. The menu
  bar panel is not reachable by accessibility (measured 2026-08-25, `SettingsPanelLink`'s
  comment), so the look owed is a person opening it.
- App tests, the gates in order, explicit paths.

## Where it ended

The 806-line file is seven files in `Recording/MenuBar/`, the largest `MenuBarSourceRows` at
about two hundred, and `DisplayRefreshRates` beside them. Done as decided, plus three things the
split itself showed:

- **The header became its own view.** It reads `coordinator.elapsed`, and as a computed property
  of the panel that read was the panel's, so the whole panel's body re-ran for every change of
  the clock while recording.
- **`PanelLevel` is handed the guards, not the level**, for the same reason: the controls'
  body read every new microphone reading.
- **The microphone and camera rows wore one label built twice.** They now share
  `SourceRowLabel`, for the reason `MenuBarSettingRow` exists.

**A source rule had stopped checking anything.** `theMenuBarFooterPutsAtMostTwoLinksInARow`
counted lines naming `PanelLink(`, deleted on 2026-10-23; of the footer's four items it saw
one, `SettingsPanelLink`, and passed. Its rule — two per row — was overtaken when the footer
became icons. It is replaced by `theMenuBarFooterDrawsNoWordsThatCanTruncate`, which checks what
the icons need: no visible text in `FooterIcon`. The five other rules that named
`MenuBarRecorder.swift` now name the file that holds their subject, or every file in
`Recording/MenuBar/` where the subject is the panel as a whole (the one settings-row shape, the
ways of starting a recording).

Mutations, each red: the spelling back to `⌘⇧R`, shift dropped from the registration (both
`theRecordingKeyIsSpelledAsItIsRegistered`); a `Text` drawn in `FooterIcon`; a second `.menu`
picker in another file of the panel; the camera-effects row ungated. App tests 289 → 290.

**Found and not done:** `ARCHITECTURE.md` says `Inspector/` "is at seven panels and flat; it
does not need" a subgroup. It now holds eight `Caption*` files — past the rule of threes the same
paragraph states. A move of its own, next.

**Not seen in the running app.** The menu bar panel is not reachable by accessibility, so the
look owed is a person opening it: both modes, with and without a camera, while recording.
