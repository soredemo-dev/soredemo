# The caption list decides in its state, not in its rows

2026-10-24. `Soredemo/Inspector/Captions/CaptionLines.swift` is 438 lines: the cue list's view and,
at the end, `CaptionListState`, the class its hosts hold so the list's memory survives the view
being rebuilt. Read in full before this was written.

## What is untested, and why it can be

Three decisions are made inside the view, where no test reaches them:

- **Which cues the search lets through**, each with its index into the UNFILTERED track — the
  property every edit depends on, because an edit addressed by a filtered position would retime
  the wrong line.
- **Whether a committed correction becomes an offer** to fix the same thing elsewhere: that the
  row being committed is the one whose text was remembered on focus, that exactly one run of
  text changed (`RunEdit`, tested in Core), that it appears in other lines
  (`cuesContaining`, tested in Core), and which whole word is remembered for next time. The two
  halves are tested; the joint, which is where a wrong index or a wrong word would live, is not.
- **The row's timecode**, `m:ss.t`.

`CaptionListState` already holds the inputs (`search`, `textOnFocus`) and the output (`offer`).
The decisions move to it — `visibleCues(of:)`, `remember(_:in:)` and `noteCorrection(at:in:)`
— so the view asks and draws. `timecode` becomes a static on the view and is tested where it is.
`CaptionListState` moves to its own file.

Also: two doc comments are stacked on `measurement(of:)`, the first describing the whole
reading, which is `reading(of:)`'s. The first moves to where it belongs.

## How it is verified

On a fixture whose matching cue is not the first, so a filtered index and a track index differ:

- the search is case-insensitive and ignores surrounding spaces, and returns the track index;
- a correction whose changed run appears in one other line offers it with the count 1 and the
  whole corrected word; one that appears nowhere else offers nothing; a commit on a row other
  than the one remembered offers nothing;
- the timecode under and over a minute.

Mutations: the filtered position returned instead of the track index; the remembered-row check
dropped; the run remembered instead of the whole word; the case-folding dropped.

## Where it ended

As decided. `CaptionLines` is 393 lines and `CaptionListState` its own file; `textOnFocus` is
`private(set)` now that only the state writes it. App tests 300 → 305.

Five mutations, each red in the end — **one only after its test was rewritten.** The check
that a commit belongs to the remembered row survived its mutation: the first fixture committed
text nothing like the remembered line, `RunEdit` refused that as a rewrite, and the test passed
with the row check deleted, for a reason that had nothing to do with rows. The fixture now
commits text one run away from the remembered line's, so comparing the two would offer, and the
mutation reddens it.

The second fixture's first version had its own mistake, caught by the run rather than by the
reading: "demo" corrected to "tour" was meant to fit no other line, and the third says "demo".
The code was right; the expected value was a hand count.
