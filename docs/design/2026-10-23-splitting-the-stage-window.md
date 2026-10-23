# Splitting the stage window

2026-10-23. The editor's window, `Soredemo/Editor/StageWindow.swift`, is 1797 lines — the largest
file in the app, now that `RecordingCoordinator` is split
(`2026-10-23-splitting-the-recording-coordinator.md`). Same aim: each type one job, the view a
view, and what can be tested tested without a window.

## What is in it, read rather than guessed

| Lines (about) | What | Kind |
| --- | --- | --- |
| 20–180 | stored inputs, 20 `@State`s, `InspectorTab` | state |
| 184–590 | layout: stage, timeline, inspector, toolbar, alerts, and 17 `.task(id:)` reactions | view |
| 590–660 | `configuredComposition` — the compositor's statics and the `AVVideoComposition` | pipeline (static, the probe calls it) |
| 660–760 | inspector rail and tab switch | view |
| 760–1000 | camera, output controls | **inspector sections** |
| 1003–1075 | Final Cut XML: read both files' size, length, audio; write | export |
| 1075–1330 | GIF, audio, music controls | **inspector sections** |
| 1330–1440 | adopting music; cleaning the microphone; the music's file and ramps | **preview pipeline** |
| 1449–1520 | save, save as, a copy for sharing | project actions |
| 1520–1535 | zoom amount control, label, re-deriving zooms | inspector section |
| 1537–1645 | `load()` — the asset, the cut, camera and music, the player | **preview pipeline** |
| 1646–1790 | export frame, export, `runExport` | export |
| 1791 | `formatted(_:)` | **dead** — no caller |

## The split

**1. The inspector's sections become their own views** in `Soredemo/Inspector/`:
`CameraOverlayControls`, `OutputControls`, `GIFControls`, `AudioControls` (with the music),
`ZoomAmountControls`. Each takes `EditorViewModel` (or the binding it needs) and an `onChange`.
This is the largest cut, and pure view code: nothing about what is drawn changes. The window's
`inspector` switch then reads as a table of contents. `formatted(_:)` is deleted.

**2. The preview pipeline becomes `EditorPreview`**, an `@Observable` model the window owns:
the player and the asset it plays, the build failure, the cleaned microphone and its note, the
measured loudness, the music track and its failure, `load()`, adopting music, and the music's
ramps. Today these are twelve `@State`s and five functions that only make sense together, and
none of them can be tested without a window. The window keeps the `.task(id:)` reactions —
which change triggers a rebuild is a fact about the view's inputs — and calls the model.

**3. Final Cut XML's file reading moves beside `FinalCutXML`**, as
`FinalCutXMLExport.source(for:frameRate:)` and a sentence for each refusal, so the window only
asks where to write. The two copies of "read a movie's size, length and audio" (screen and
camera) become one function.

**Not split**, on purpose: the layout and the toolbar. A toolbar's items call the window's
actions; moving them to another type moves the actions' callers away from the state they act
on, which is the coupling this is meant to remove. `configuredComposition` and `runExport` stay
static and where they are, because the probe calls them by `StageWindow.` and they hold no
window state.

## How each step is verified

- **1** is a move. App tests and the probe stay green; no new behaviour, so no new test, and the
  sections are looked at once in the running app (all six tabs, a recording with a camera).
- **2** gets tests: a load of a real short movie gives a player and no failure; a missing file
  gives a failure and no player; adopting music with an unsafe name is refused with the reason
  and leaves the bed as it was; a chosen piece is copied into the package and becomes the bed.
  Mutations: the failure not recorded, the unsafe-name guard removed.
- **3** gets tests: a movie of known size, length and frame rate reads as those; a movie with
  no audio track says so; every refusal has a sentence. Mutation: audio presence inverted.

Every step: app tests, mutations, gates in order, commit with explicit paths.
