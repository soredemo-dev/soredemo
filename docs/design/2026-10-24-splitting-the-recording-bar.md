# Splitting the recording bar

2026-10-24. `Soredemo/Recording/RecordingBar.swift` is 504 lines: the floating bar's panel, its
hosting view, the window dragger, the presenter, the bar's view, and three small views two other
surfaces borrow (`PulsingDot`, `LevelMeter`, and `RecordingBarView.elapsedText`). Read in full
before this was written.

## Found while reading

- **Two surfaces reach into the bar for its formatter.** The menu bar header and the notch's
  live wing call `RecordingBarView.elapsedText` — the same shape as the stop key's spelling,
  which lived on the menu bar panel until yesterday. It becomes `ElapsedTime.text(_:)`, beside
  `PulsingDot` and `LevelMeter` in a file the three surfaces share, with the tests it never had
  (under a minute, over an hour, a negative input).
- **The bar's body reads the clock and the microphone level.** `state` and `microphone` are
  computed properties of `RecordingBarView`, so every tick and every level reading re-ran the
  whole bar — grip, buttons and all. Each becomes its own view.
- **Comments about whether the bar takes the keyboard contradict each other and the code.**
  - The panel says it is key "so ⎋ and ⌘. reach it". Nothing on the bar listens for either: ⎋
    went with `5fffe28`, when the stop key became system-wide, and ⌘. was never there.
  - The Stop button's and the clip button's comments say the panel "never becomes key". It
    overrides `canBecomeKey` to `true`, and `CountdownPanel` measured that a
    `.nonactivatingPanel` which can become key does take the keyboard when made key.
  - What is true, and what each comment now says: the bar is ordered front and never MADE key
    (`RecordingBarPresenter.show`), so a shortcut on it fires only after somebody clicks it —
    while the keys a person is pressing belong to the app being recorded.
  - **Not measured, and recorded as the question it is:** whether a click on Pause or Stop
    makes the bar key and so takes the keyboard from the app being recorded until somebody
    clicks back. `canBecomeKey` is left as it is; changing it without that measurement would be
    a guess about focus, which is the thing the bar must not get wrong. It needs a person not
    using the machine, or a person watching.
- **A sentence with its antecedent removed.** "A capture toolbar wants the same five controls"
  — the five were the panel's flags, and the sentence that named where else they are set was
  taken out with a project's name. Rewritten to say what it means.

## The split

Into `Soredemo/Recording/RecordingBar/`:

| File | Holds |
| --- | --- |
| `RecordingBarPanel.swift` | the `NSPanel` and the hosting view that passes the shadow's halo through |
| `WindowDragger.swift` | moving the window by hand, which `isMovableByWindowBackground` cannot |
| `RecordingBarPresenter.swift` | show, hide, and the numbers `--show-recording-bar` prints |
| `RecordingBarView.swift` | the bar, expanded and collapsed, and its sections |

`RecordingSignals.swift` stays in `Recording/` — the dot, the meter and the elapsed time belong
to all three surfaces, not to the bar.

## How it is verified

- `ElapsedTime`: 59 s, one hour one minute one second, a negative input. Mutations: the hour branch
  removed, the clamp removed.
- The rest is a move; the placement rules catch a section that stops being built.
- App tests, the gates in order, explicit paths. The bar is looked at by a person.

## Where it ended

As decided: four files in `Recording/RecordingBar/` and `Recording/RecordingSignals.swift`; the
bar's view is 230-odd lines. The clock and the microphone are `BarState` and `BarMicrophone`,
each reading only what it shows. App tests 292 → 295. Three mutations of `ElapsedTime`, each
red on its own test: the hour field removed, the clamp at zero removed, seconds rounded rather
than truncated.

**Still open:** the focus question above. It needs one click on Pause during a take with
another app typing, and a look at which window then has the keyboard.
