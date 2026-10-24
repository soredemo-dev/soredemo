# The timeline model and its two clocks

2026-10-23. `Soredemo/Editor/Timeline/TimelineEditorModel.swift` is 757 lines and the largest
file left in `Editor/Timeline/` after the view was split (`2026-10-23-splitting-the-timeline.md`).
Read in full before anything below was written.

## Two defects, found by reading which clock each value is in

The model's header says it: everything is in SOURCE time — the recording, with the cuts drawn as
gaps — and OUTPUT time is what the player and the exporter count in. The two are equal until the
first cut. `playhead` is source time (its own comment; `followPlayer` converts output → source;
the preview's seek converts source → output in `StageWindow`).

**The export range takes the playhead as if it were output time.** `inPoint` and `outPoint` are
documented as OUTPUT time, and `9d859bc`, which added them, says why that is load-bearing:
*"somebody setting an in point is pointing at the video they are watching, which is the edited
one."* `EditTimeline.restricted(toOutput:)` is correct and tested. But `markIn()` is
`inPoint = playhead` — a source time stored as an output time. With 2–5 s cut from a recording
and the playhead at source 10 s (output 7 s), pressing I exports from output 10 s, which is
source 13 s: three seconds late, by exactly what was cut before it. The timeline's shade draws the
same number against the SOURCE window, so the dimmed edge sits under the playhead and looks right;
only the exported file is wrong.

The tests did not see it because their fixture put the playhead at source 4 s — inside the cut,
where no output time exists — and asserted output 4 s. The fixture had a cut (non-identity, as
AGENTS.md asks) and then measured at a point the cut does not map.

**The scrub plays the wrong audio after a cut.** `movePlayhead(to:)` hands `ScrubAudio` the
playhead converted as though it were output time (`edit.sourceTime(atOutput: time) ?? time`).
`ScrubAudio.scrub(to:)` takes the recording's own clock, which is what the playhead already is.
After a 3 s cut, dragging over source 10 s plays source 13 s. Present since `63f7a48`
(2026-08-30), which added the scrub.

### The decision

- `markIn` and `markOut` convert the playhead with `edit.outputTime(atSource:)`. **A playhead
  inside a cut marks nothing**: there is no frame of the video there to point at, and the
  alternatives — the nearest kept frame either side — each pick a side nobody chose.
- The scrub gets the playhead as it is.
- The shade draws what the export will write, in source time: the first and last source edge of
  `editForExport`, so it is drawn by the same timeline the exporter renders rather than by a
  second conversion that could disagree with it.

## Found while reading, not defects in what a person sees

- **`commitZoomDrag(_ name:)` never reads its name, and its comment says the drag is committed
  "as ONE step, for the same reason a trim does".** It is not a step: zoom adjustments are not in
  `EditHistory`, so ⌘Z after moving a zoom undoes whatever clip edit came before it. Making zoom
  edits undoable changes what the history holds and is a feature, not a tidy-up; recorded here and
  not done. The parameter goes and the comment says what happens.
- The model names a view: `EditorToolbar.speedLabel` for an undo title. The speed and fade choices
  and the label move to `ClipChoices`, which the toolbar, the clip strip and the model all read.
- Reading a recording package for its stillness — `ProjectPackageIO`, `ObservationWriter`'s log
  names, `RecordedStillnessReader` — is file work in a model. It moves to `PackageStillness`, and
  the model's imports lose `Capture`, `Project`, `AppKit` and `SwiftUI`.
- The export marks are a value with two rules (pressing again cancels; a crossing mark clears the
  other) and nothing to do with an `@Observable` class. They become `ExportMarks`.
- Two doc comments sit on the wrong declaration (the derived-zooms line above `zoomAnchor`; two
  paragraphs about `findStillness` stacked into one), and `snapped` is `@discardableResult` with
  no caller that discards it.

**Not split:** zooms, trims and snapping stay in the model. They share the snap state, the drag
baselines and `publish()`, and Swift gives a type's private state to its own file only; moving
them out would mean widening that state, which is a worse design than a long file.

## How it is verified

- The two clocks, on a fixture with 2–5 s cut and the playhead AFTER the cut (source 10 s =
  output 7 s), so the conversion is not at its identity:
  - I at source 10 s gives an export range starting at output 7 s; O there ends it at 7 s.
  - I with the playhead inside the cut marks nothing.
  - the shade's source span starts at source 10 s, not 13 s.
  - the scrub hears source 10 s. `TimelineEditorModel` takes what it scrubs through as an
    argument, so a test can listen; the app passes `ScrubAudio`.
- `ExportMarks` on its own: twice cancels, a crossing mark clears the other.
- Mutations: the conversion removed from `markIn`, from `markOut`, and put back on the scrub; the
  shade read from `exportRange` directly.
- App tests, the gates in order, explicit paths.

## Where it ended

`TimelineEditorModel` went from 757 lines to 703 (`wc -l`). That is a small change, and on
purpose: what is left is the editing state, and the two defects were the point. `ExportMarks`
(55), `PackageStillness` (49) and `ClipChoices` (22) are new beside it. The model imports no
`AppKit`, `SwiftUI`, `Capture` or `Project` any more.

Ten new app tests (274 → 284, `scripts/run-app-tests.sh`). Seven mutations, each red:

| Mutation | Red |
| --- | --- |
| `markIn` stores the playhead unconverted | the in point, the playhead inside a cut, the shade |
| `markOut` stores the playhead unconverted | the out point, the crossing marks, the restricted export, inside a cut |
| the scrub converts the playhead again | `theScrubPlaysTheRecordingUnderThePlayhead` |
| the shade draws `exportRange` as source time | `theShadeIsDrawnWhereTheExportStartsInTheRecording` |
| marking the same place again does not cancel | `ExportMarksTests` and the model's own |
| a crossing in point keeps the out point | `ExportMarksTests` |
| a crossing out point keeps the in point | `ExportMarksTests` and the model's own |

**Not seen in the running app.** Both defects were found by reading which clock each value is in,
and the fixes are measured by tests. A look is still owed: cut a span, mark I after it, export, and
check the file starts at the playhead; drag the playhead after a cut and listen.

**Zoom edits became undoable in the next commit** — `2026-10-23-undoing-a-zoom.md`.
