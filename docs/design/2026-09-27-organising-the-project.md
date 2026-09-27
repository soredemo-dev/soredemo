# Organising the project: layers, view models, and what was deleted

2026-09-27. The owner asked for the project to follow clean architecture and MVVM, stay
organised, and lose the code it does not need. This records what those words mean HERE, what was
already true, what changed, and what was deliberately not done.

## Clean architecture — already enforced, now written down as layers

The dependency rule (inner layers know nothing of outer ones) is not new in this project. It is
enforced by `Plugins/ArchitectureCheck`, which fails the build — the compiler does not, see
`ARCHITECTURE.md` rule 1. What was missing was the map from the familiar vocabulary to the modules:

| Layer | Modules | Imports | Enforced by |
| --- | --- | --- | --- |
| **Domain** — entities and the rules over them | `Geometry`, `Timeline`, `Graph`, `Project`, `Framing`, `Variants` | Foundation only | plugin rules 1, 2, 4 |
| **Domain services** — pure transforms of domain values | `Render` (the render plan), `Overlays` (captions, text, chapters, music…) | Foundation only | plugin |
| **Infrastructure** — the operating system's frameworks | `Capture` (ScreenCaptureKit, event taps, AX), `Compositing` (AVFoundation, Core Image, Speech) | platform frameworks | rule 5 bridges; `HeadlessCheck` |
| **Presentation** — views and view models | `Soredemo/` app target | SwiftUI, AppKit | `AppSourceTests` |
| **Composition root** | `Soredemo/App/SoredemoApp.swift` | everything | — |

Arrows point inward only: the app reads infrastructure and domain; infrastructure reads domain;
domain reads Foundation. **No protocol layer was added between presentation and infrastructure.**
Clean architecture's "ports" exist so an outer layer can be swapped; here each infrastructure
module has exactly one implementation and the domain never calls outward, so an interface per
exporter would be a second declaration of every signature with nothing on its other side. The
place that would need one — tests that must not touch AVFoundation — already has it: the domain
modules link without any framework, and that is what the plugin guarantees.

## MVVM — the gap was one view doing a view model's job

The app's twenty-one `@Observable` classes named `…Model` (`TimelineEditorModel`,
`CaptionsModel`, `ChaptersModel`…) are the view models; the name is kept rather than renamed to
`…ViewModel`, because a rename across twenty-one types and every document that cites them changes
no behaviour. The rule is: **a view lays out and binds; a view model holds state and makes
decisions; neither touches the other's job.**

The one place that broke it is `StageWindow` — 2088 lines, 46 `@State` properties, and the
project's save, open, and export assembly written as private functions of a `View`. Those cannot
be tested without a window. `EditorViewModel` takes them: state, `currentEditState()`,
`restore(_:)`, the export job's assembly. The view keeps layout and bindings.

**Done the same day, and the first test found a bug that lost work.** The save-then-open round trip
had never been tested, because it could only run inside a window. As soon as it could run,
`aSavedProjectOpensExactlyAsItWasSaved` failed on one field of twenty-two: **opening a project
with cuts and saving it again saved no cuts.** `TimelineEditorModel.hasEdits` means "changed since
this was opened" — right for the Edited label and for Revert — and saving read it as "differs from
the whole recording". A project opened with cuts had not changed since it was opened, so the save
wrote no timeline; the same confusion made every opened project report unsaved changes at once.
Saving now reads `editToSave`, which asks the question it needs. The fixture sets every field,
and `everyFieldOfTheFixtureIsSet` fails when `EditState` gains one the fixture does not.

The rewiring was mechanical: 22 properties and the three functions moved, and a lexer-driven
rewrite changed each use in `StageWindow` to `editor.…` outside comments and plain strings. A use
it got wrong could only become a compile error — a shadowed name becomes `let editor.x` — and the
one it did get wrong, two enum case names, was one.

## What was deleted, and how it was established that nothing needed it

Each was on `ARCHITECTURE.md`'s D6a-V register — "unexercised public API" — with a use count
pinned by `theUnexercisedPublicAPITableMatchesTheTree`. The count was re-taken on 2026-09-27 and
was still zero outside each symbol's own file:

| Deleted | Why it existed | Why it could go |
| --- | --- | --- |
| `Timeline.TimeRange` and its tests | an epoch-less interval | its stated first caller moved to `HostRange`; the only callers left were its own tests. The `Nanoseconds` tests in the same file are kept, renamed `NanosecondsTests.swift` |
| `Minting.now()` | a wall-clock reading | the recording path needs no wall clock |
| `Degradation.noMicrophoneTrack` | a denied microphone degrading mildly | measured false — the whole stream fails. It was kept "because removing a raw-value case is wire-breaking", and **that reason was false**: no `Degradation` is ever written to a file |
| `ProjectDocument.addMedia(_:fileExtension:)` | media under a minted name | capture names its file at `beginSegment` and uses `addMedia(_:named:)` |

Two table rows went with them; the table keeps the two symbols that DO have callers.

**Not deleted:** `MediaError.documentHasNoURL` is thrown and caught nowhere — D6a-E — which is a
live path with unknown behaviour, not dead code. Deleting it would hide the question.

**Not yet looked for:** code that is dead but was never registered. The tool that finds it across
a Swift project is Periphery, which is not installed on this machine; a broader sweep waits on it.

## An instrument fixed on the way

`scripts/scan-decode-validation.py` globbed `Sources/*` relative to where it was run, so from the
repository root it read nothing and printed `0 / 0` — a legal-looking count for "no files". It now
finds its sources from its own path and exits with an error when it reads none. Run from either
place it prints 8; the checker's list has 7; the one between them is `Nanoseconds` (see AGENTS.md).
