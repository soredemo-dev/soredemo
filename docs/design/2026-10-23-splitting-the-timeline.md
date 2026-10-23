# Splitting the timeline

2026-10-23. `Soredemo/Editor/TimelineEditor.swift` is 1002 lines, the largest app file after the
coordinator, the stage window and the captions panel were split (the three
`2026-10-23-splitting-…` documents beside this one). Same aim: each type one job, and what can
be tested tested without a window.

## What is in it, read rather than guessed

| Lines | What |
| --- | --- |
| 17–147 | the lane stack, two overlays, the bare keys |
| 149–219 | the export range's shade and the playhead line, drawn over every lane |
| 221–248 | `lane`: one header cell and its content |
| 250–305 | the ruler and its tick arithmetic (tested) |
| 307–366, 490–613, 750–791 | the video strip: clips, filmstrip, selection, trim handles, snap line, pinch, drag |
| 368–459 | the audio lanes, their names and tints, and plain block lanes |
| 461–488 | chapter marks |
| 615–640 | the waveform layer |
| 642–748 | the zoom lane and its draggable blocks |
| 793–910 | the bare keys, nudging, the readout, the ⌘ shortcuts |
| 912–945 | converting between points on screen and time in the recording |
| 955–1002 | `WaveformBars`, shared with `CaptionWaveform` |

The model is already its own file (`TimelineEditorModel`, 2026-09-27). What is left is one view
that draws eight lanes and knows how each one is dragged.

## Found while reading

**Three doc comments are on the wrong declaration.** The paragraph about the three read-only
tracks sits above `filmstrip`; the playhead line's paragraph sits above the export range's
shade; and `snapThreshold` carries `nanoseconds(forPoints:)`'s first two lines above its own.
A comment about the zoom lane sits above the audio lanes' code.

**Three parameters are never read.** `fraction(_:of:)`, `sourcePosition(at:width:duration:)`
and `nanoseconds(forPoints:width:duration:)` each take a `duration` and use the window instead
— correctly, as their own comments say. The parameter suggests the opposite.

**A conversion with nothing to convert answers zero.** At a width of 0, `sourcePosition`
returns the recording's start and `nanoseconds(forPoints:)` returns no time at all — both legal
answers, which is the case AGENTS.md's "a measurement has no safe default" names.

## The split

Into `Soredemo/Editor/Timeline/`. `ARCHITECTURE.md`'s rule of threes asks for a subgroup once
three files in a group are about one narrower thing; the timeline will be nine.

| File | Holds |
| --- | --- |
| `TimelineEditor.swift` | the lane stack, the overlays' placement, the keys, the readout |
| `TimelineEditorModel.swift` | moved, unchanged |
| `TimelineScale.swift` | points ↔ time at one width and one window, failable at no width |
| `TimelineLane.swift` | the header-and-content row, and the one origin every overlay measures from |
| `TimelineRuler.swift` | the ruler and its tick arithmetic |
| `TimelineClipStrip.swift` | the video lane: clips, filmstrip, selection, trim handles, snap line, gestures |
| `TimelineZoomLane.swift` | the zoom lane and its blocks |
| `TimelineTrackLanes.swift` | audio lanes, plain block lanes, chapter marks |
| `TimelineOverlays.swift` | the playhead line and the export range's shade |
| `WaveformBars.swift` | moved, unchanged |

**Each lane reads only what it draws.** That is a correctness point as well as a tidiness one:
this file's history is a run of fixes for a body that read the playhead and so rebuilt every
lane ten times a second (`AtPlayhead`). Lanes that are their own views are observed separately,
so a read added to one cannot rebuild the others.

**Not split:** the bare keys and the ⌘ shortcuts stay with the stack. They act on the model as
a whole, and they have to be attached to a view that is always present.

## How it is verified

- `TimelineScale` gets tests against a window that is zoomed AND does not start at zero (both
  non-identity): a point maps to the right instant, a span of points to the right duration, an
  instant back to its point, and no width gives no scale. Mutations: the window's start
  ignored, points not divided by the width.
- The rest is a move. The tick and stamp tests follow their functions. The placement rules
  added with the captions split (`everyViewTypeInTheAppIsBuiltSomewhere`) catch a lane that
  stops being built. The timeline is looked at once in the running app.

Every step: app tests, mutations, gates in order, commit with explicit paths.

## Where it ended

`TimelineEditor` went from 1002 lines to 247 (`wc -l`); the largest lane is the clip strip at
251. `TimelineEditorModel` (757) moved unchanged and is now the largest file in the group.

**A real defect, found by moving a conversion into a type that had to say what it returns.**
`TimelineWindow.duration(forFraction:)` returns a magnitude. `b7d9bbb` routed the trim handles
through it, so from 2026-08-23 a handle dragged LEFT moved its edge RIGHT: dragging a clip's
start left to give it footage back cut more instead. The zoom lane, written the same day, put
the sign back by hand; the trim handles never did. `TimelineScale.offset(forPoints:)` is signed
and both lanes use it, and `aDragToTheLeftIsAnEarlierOffset` reddens when it is not. This was
found by reading, not by dragging: it has not been seen in the running app either before or
after the fix, and the look owed below is the first time it will be.

**Also corrected:** the zoom block's comment said a drag starting in the "right eighth"
resizes; the code has always used the right quarter (`> width * 0.75`).

Six mutations against `TimelineScale`, each red: the window's start ignored in either direction,
points not divided by the width, the offset unsigned, ⌘ ignored, a zero width accepted.

**Not covered:** the test proves `offset(forPoints:)` is signed, not that the trim handle calls
it. A trim handle reverted to `span(forPoints:)` would pass every test here; only a drag in the
app would show it.

**Still owed:** a look at the timeline in the running app — every lane, a trim dragged both
ways, a zoom block moved and resized, a pinch.
