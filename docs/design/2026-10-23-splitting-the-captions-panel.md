# Splitting the captions panel

2026-10-23. `Soredemo/Inspector/CaptionsPanel.swift` is 1049 lines, the largest app file now
that the coordinator and the stage window are split (`2026-10-23-splitting-the-recording-coordinator.md`,
`2026-10-23-splitting-the-stage-window.md`). Same aim: each type one job, and what can be tested
tested without a window.

## What is in it, read rather than guessed

| Lines | What | Kind |
| --- | --- | --- |
| 23–419 | `CaptionsModel`: track, style, transcription run, undo, terms | **model, in the view's file** |
| 333–384 | `importSidecar`: an open panel, then mapping each cue back through the edit, then a report | panel **and** logic in one function |
| 389–409 | `exportSidecar`: a save panel, then retiming and writing | panel **and** logic in one function |
| 422–592 | `CaptionsPanel`: inputs, the two-list switch, layout, scroll-to-cue | view |
| 593–655 | transcribe button, language, words per line | inspector section |
| 664–709 | `termControls` — the names list | inspector section, **never shown** |
| 711–753 | presets | inspector section |
| 755–888 | look: burn-in, size, colours, outline, shadow, highlight, sidecar buttons | inspector section |
| 902–966 | the font row, and copying a chosen font into the package | section **and** file I/O |
| 994–1048 | the transcription's steps | view |

## Found while reading

**The names list has never been on screen.** `termControls` was added in `522bf4f` with its
model (`addTerm`, `removeTerm`, `spokenTerms`, saved in the project) and translated into nine
languages, and no `Section` ever placed it: `git log -G termControls` finds one commit, and in
it the name occurs once, at its definition. A project saved with terms restores them and applies
them, and nobody can add one. That is the completion rule's case exactly: the behaviour exists
everywhere except where a person could see it. It goes in as its own section after Transcribe.

**Its doc comment and the presets' were swapped.** The paragraph above `termControls` begins
with the presets' description ("The named starting points…"), then runs into the names list's.

**A font failure was never translated.** `fontFailure` is built by interpolation into a plain
`String` and shown through `LocalizedStringKey(_:)`, which looks the interpolated sentence up
as a key and finds nothing. The music's identical failure uses `String(localized:)`.

**Music and fonts copy a chosen file into the package with the same eight lines**: make the
directory, remove a file of that name, copy. Two copies of one rule about the package.

## The split

**1. `CaptionsModel` moves to its own file**, and the sidecar's two functions are cut at the
panel. The open and save panels move to the view, as the stage window's actions do; the model
keeps `importSidecar(from:edit:)` and `exportSidecar(format:edit:to:)`, which take a URL and can
be tested. Choosing a font becomes `CaptionsModel.adoptFont(_:mediaURL:)` with its failure on
the model. Copying into the package becomes one function, `ProjectStore.copyIntoPackage`, used
by fonts and music; each keeps its own name check, because the two refuse different names.

**2. The sections become views** in `Soredemo/Inspector/`: `TranscriptionControls` (with the
steps), `CaptionTermControls`, `CaptionPresetControls`, `CaptionLookControls` (with the font
row). The panel's body then reads as a list of sections, and the names list is one of them.

**Not split**: the two-list switch and the scroll that follows the playhead. Both are about
this list's layout, and the focus they share is the panel's.

## How each step is verified

- **1** gets tests: a sidecar read through an edit that starts two seconds in lands two seconds
  later, and a cue past the edit's end is counted rather than placed (non-identity: the edit
  does not start at zero); export writes cues in the export's clock; a font with an unsafe name
  is refused with a translated reason and the style keeps its font; a chosen font is copied in
  and becomes the style's. Mutations: the mapping skipped, the unsafe-name guard removed, the
  copy not replacing a file of the same name.
- **2** is a move plus one placement. A source rule asserts the panel's body places the names
  list, reddened by removing it. The panel is looked at once in the running app.

Every step: app tests, mutations, gates in order, commit with explicit paths.
