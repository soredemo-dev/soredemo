# Every caption edit is undoable

2026-10-24. Found reading `Soredemo/Inspector/Captions/CaptionsModel.swift` (448 lines) to split it.

## The defect

`CaptionsModel.change(_:to:typingAt:)` is the model's one way to replace the track undoably, and
its comment says why there is one: "registering at each call site would be eight chances to
forget the ninth, and the one forgotten is the one a person loses work to." Two writers of the
track do not go through it:

- **`applyEverywhere`** — the "Fix them too" offer, which replaces a run across every line that
  has it and adds the corrected word to the names list. It wrote `track` directly. A person who
  pressed it on a count they misjudged could not ⌘Z it; the last thing undo reached was the one
  line they had typed in. Its term was added through `if let correctedWord, addTerm(…) { }`, an
  empty `if` standing in for a discarded result.
- **`importSidecar`** — reading an `.srt` or `.vtt` back in, which by design REPLACES the track.
  It wrote `track` directly too, so importing over a corrected transcript discarded the
  corrections with no way back.

`rebuild` also replaces the track without a step, and that one is left: re-breaking lines for a
new size is derived from the kept transcript, and its comment already says the caller has to
mean it.

## The decision

Both go through `change`. **The fix-everywhere step also takes the names list back**: undoing the
replacement while leaving the corrected word in `spokenTerms` would put the correction back the
next time somebody pressed Transcribe — the change undone on screen and redone in the data.
`change` takes an optional list of terms to install with the track, and its undo restores the
list it replaced, by the same symmetric closure.

Two step names, in all ten string tables: "Fix Captions Everywhere" and "Import Subtitles".

## How it is verified

With `CaptionEditingKeysTests`' recorder, on a fixture where the run is in more than one line:

- fix-everywhere, then ⌘Z: every line is back AND the term is gone; ⌘⇧Z puts both back;
- an import over a corrected track, then ⌘Z: the corrected track is back;
- each registers exactly one step, under its name.

Mutations: `applyEverywhere` writing the track directly again; the undo not restoring the terms;
the import writing the track directly.

## Where it ended

As decided. App tests 305 → 307. Three mutations, each red on its own test: the fix writing the
track directly, its undo leaving the terms, the import writing the track directly.

**A fourth survived, and its clause is gone rather than tested.** The first version of the guard
also let a change to the terms ALONE count as a step. Removing that leaves every test green,
because nothing can reach it: `applyEverywhere` is only ever offered for a run that other lines
contain (`CaptionListState.noteCorrection` requires a count above zero), so the lines always
change when the terms do. A branch nothing reaches is a claim nothing checks; the guard is back
to comparing the track, and the comment says why the terms need not be compared.

The first gate run failed `noCommentBlockIsLongEnoughToBeADocument`: the reasoning for `terms`
had grown `change`'s comment to 19 lines against a budget of 16. It is here instead, and the
comment names this file. The comment also lost a paragraph its own body repeats.
