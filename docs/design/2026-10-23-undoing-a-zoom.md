# Undoing a zoom

2026-10-23. Found while splitting the timeline model
(`2026-10-23-the-timeline-model-and-its-two-clocks.md`): a person's changes to a zoom — moving it,
resizing it, switching it off — are not in the undo history. `EditHistory<EditTimeline>` holds
the clips and nothing else, and `zoomAdjustments` is a separate stored property written directly.

So ⌘Z after moving a zoom does not put the zoom back. It undoes whatever clip edit came before
it — a split, a trim, a deleted clip — which the person may not have looked at in minutes, and
the zoom stays where it was dragged. The toolbar's "Undo …" tooltip names that earlier edit, so
the wrong thing is at least announced; the menu's ⌘Z gives no such warning.

## Alternatives

1. **A second `EditHistory` for zooms.** Two stacks, and ⌘Z has to pick which one: the most
   recent across both needs a shared clock or a merged log, which is a third structure to keep in
   step with the first two. No.
2. **Register zoom changes with `UndoManager`.** The model deliberately does not use it
   (`EditHistory`'s header: values, not inverse operations), and mixing the two is the shape that
   header argues against.
3. **One history of one value holding both.** `EditHistory` is generic over any `Equatable`
   value; the value becomes `TimelineEdits { timeline, zooms }`. Every step is one of the two
   changing, ⌘Z steps back across both in the order they happened, and nothing new has to be
   kept in step. **Chosen.**

The memory cost `EditHistory` accepts per step grows by the adjustments array — a few entries,
each an instant and two deltas. Negligible, for the reason the header gives.

## Decisions inside it

- **A drag is one step**, as a trim is: the preview lives outside the history (`liveZooms`, the
  zoom twin of `liveEdit`) and is recorded on release. The step is named "Move Zoom" or "Resize
  Zoom" from what the drag did, and the name is localised in the model — the lane passes which
  kind of drag it was, not a string.
- **Switching a zoom off or on is a step.** So is "reset zooms".
- **Opening a project is not a step.** The saved adjustments replace the history's value with
  `reset`, as the saved timeline does: ⌘Z must not walk from one project into another.
- **Loading a recording keeps the zooms it has.** It did before; `load(duration:)` replaced the
  timeline and left `zoomAdjustments` alone, and the order the host calls things in depends on it.
- **"Revert All Edits" reverts the clips and keeps the zooms.** That is what it did, it is what
  its name says ("edits" is the clip track's word throughout the toolbar), and changing it is a
  separate decision.

## How it is verified

On a fixture whose zoom is NOT at the recording's start and whose drag is not zero:

- a zoom moved after a split: ⌘Z puts the zoom back and leaves the split; a second ⌘Z undoes
  the split.
- the undo name after a move is "Move Zoom"; after a resize "Resize Zoom".
- a preview with no release is not a step.
- switching a zoom off is undone by ⌘Z, and redone by ⇧⌘Z.
- restoring saved adjustments leaves nothing to undo.

Mutations: the drag committed without recording; the toggle written without recording; the
restore recorded instead of reset; the step's name swapped.

## Where it ended

As decided. `TimelineEdits` is declared `nonisolated`: the app's default isolation is the main
actor, and `EditHistory` requires an `Equatable` usable from any isolation — the build said so
before any test ran. The drag baseline `zoomDragBaseline` is gone: a preview now starts from the
history's committed value, which cannot change during a drag.

Five new app tests (284 → 289, `scripts/run-app-tests.sh`). Five mutations, each red:

| Mutation | Red |
| --- | --- |
| a released drag written without a step | the undo test and the naming test |
| move and resize names swapped | `theStepIsNamedForWhatTheDragDid` |
| the toggle written without a step | `switchingAZoomOffIsUndoneAndRedone` |
| restoring saved zooms recorded as a step | `restoringSavedZoomsLeavesNothingToUndo` |
| every preview frame recorded | `aDragNotYetReleasedIsNotAStep` |

**Not seen in the running app**: move a zoom, press ⌘Z, and see it go back while the clips stay.
