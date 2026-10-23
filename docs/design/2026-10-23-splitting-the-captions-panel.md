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
- **2** is a move plus one placement. A source rule catches a view nobody places, reddened by
  removing the names list. The panel is looked at once in the running app.

Every step: app tests, mutations, gates in order, commit with explicit paths.

## Where it ended

| Step | Moved | Commit |
| --- | --- | --- |
| 1 | `CaptionsModel` to its own file; sidecars and fonts take a URL; `ProjectStore.copyIntoPackage` | `f87e785` |
| 2 | `TranscriptionControls`, `CaptionTermControls`, `CaptionPresetControls`, `CaptionLookControls`; the names list placed | this commit |

`CaptionsPanel` went from 1049 lines to 195 (`wc -l`): the two-list switch, the sections in
order, and the scroll that follows the playhead.

**The rule became general rather than about this panel.** A check that the panel names
`CaptionTermControls` would catch this defect once. Two checks in `AppSourceAllowListTests`
catch the class: `everyPrivateViewInTheAppIsPlacedSomewhere` (65 private views; it was red on
`termControls` and nothing else) and `everyViewTypeInTheAppIsBuiltSomewhere` (73 view types).
The second's first run found `PanelLink` and `PanelLinkLabel`, unused since the menu-bar
footer became icons in `f8fbed0`; they are deleted, being a replacement nobody finished
cleaning up rather than a feature nobody placed.

**And the first version of the first check was wrong in a way worth keeping.** It matched
mentions with `\b`, and Swift's `Regex` finds word boundaries by Unicode's rules, under which
`glanceRow.transition` is one word. It reported `NotchSurfacePanel.glanceRow` — placed, on the
line `glanceRow.transition(.opacity)` — as unplaced. Both checks now count identifiers.

**Not covered:** the sentence list (`TranscriptPanel`) is handed the transcript as recognised,
not `correctedTranscript`, so a name added to the list corrects the captions and not the
sentences. Passing the corrected one is a one-word change that runs the correction on every
redraw of the stage window; measure `Transcript.correcting(terms:)` on a long recording before
making it.

**Still owed:** a look at the captions tab in the running app — the names list has never been
seen by anybody, and both lists show it.
