# A recording knows its steps

2026-10-25. The first item of `2026-10-25-beyond-a-screen-recorder.md`'s "what this asks of the
code": steps as a type, on the timeline. Every idea in that document — the guide, the
walkthrough, editing by step, narration, a demo run again — is built on it.

## What a step is

**One deliberate press on an element, from the moment it happens to the moment of the next.**
Derived, like everything else here, from the observation log's `axChain` records, so a step has an
origin (AGENTS.md, the producer-value rule) and re-deriving the steps cannot disagree with the
zooms about which clicks there were.

| Field | From | Why |
| --- | --- | --- |
| `origin` | the click's `HostInstant` | the step's identity, **the same key a zoom has** (`ZoomBlock.origin`), so a zoom and a step that came from one click can be found from each other and survive re-derivation the same way |
| `element` | the hit element's role and title; if the hit has no title, the nearest ancestor that does, up to the window | "Click **Export**" — the label the interface itself shows. A click on the text inside a button lands on an `AXStaticText` with no title; its button has one |
| `application` | the title of the chain's `AXApplication` root, when the walk reached it | "in **Finder**". An application's name is what `WindowTarget` already shows; never the window's title (`2026-10-25-a-window-title-is-content.md`) |
| `start`, `end` | the click, and the next step's click or the recording's end | the step's span, which is what editing by step cuts, retimes or retakes |

**Two presses on one element less than half a second apart are one step** — a double-click is
one thing a person did. A press with no element (the walk found nothing, or it was on this app's
own windows) is not a step: a guide line that says "click here" over an unexplained point is the
"blank step" the guide tools are criticised for, and a step this app cannot name is a step it
should not claim.

## Where it lives

- `Framing.RecordedSteps.steps(from:recordingEnd:)` — pure, from `[AXChainRecord]`, in the module
  that already reads chains for the gate.
- `FramingPlanReader.chains(fromObservationLogsAt:)` — the one reader of the log's lines, beside
  `plan`, so the steps and the plan come from the same lines.
- The editor holds the steps; **the timeline draws a Steps lane** under the chapters: a numbered
  mark per step with the element's label, clipped rather than wrapped, and a tap that puts the
  playhead on it — the chapter lane's behaviour, which a person already knows.

Not in this commit: the guide export, step-keyed edits, retakes. They are each their own design.

## How it is verified

In `FramingTests`, on chains that do not start at the recording's start:

- a step per press, numbered in order, with the hit's title, the application's name, and a span
  that ends at the next step;
- a press on untitled text inside a titled button is named by the button;
- two presses on one element within half a second are one step; 0.6 s apart are two;
- a press with no element, and one over this app's own window, are not steps;
- **no window title reaches a step** even when an old log carries one — the window is not a
  label source.

Mutations: the ancestor fallback removed; the double-press merge removed; the window allowed as a
label; the presses left unsorted. (An elementless press is refused by a `guard` on the hit before
any of this; `aPressWithNoElementOrOnThisAppIsNotAStep` is its test.)

## Where it ended

As decided. `RecordedStep` and `RecordedSteps.steps(from:recordingEnd:)` in `Framing`;
`FramingPlanReader.chains(fromObservationLogAt:)` beside `plan`; `RecordedStepsModel` in the app,
loaded by `EditorPreview` after the duration is known, from the same log and anchor as the zooms;
a Steps lane under the chapters, a numbered mark and the element's own label per step, drawn
verbatim — translating "Export" would rename somebody else's button. "Steps", the lane's name, is
in all ten string tables.

**Without a duration the last step ends where it began.** An earlier draft closed it at an instant
made up from a fresh `UUID()` — ambient randomness, which the app may not read, and a default
inside the range of the answer, which a measurement may not have. No clicks is no steps; with
clicks, the last click is the honest end.

Core: six tests; four mutations, each red on its own test (the ancestor fallback removed, the
double-press merge removed, the window allowed as a label, the presses left unsorted). App tests
314 → 317, against a log whose recording starts 1000 s after boot; three mutations, each red
(marks at the absolute instant, the duration ignored, a read failure swallowed).

**Not seen in the running app:** the Steps lane over a real recording, and what the labels say for
the applications people actually record.
