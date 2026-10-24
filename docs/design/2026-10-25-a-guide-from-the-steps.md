# A guide from the steps

2026-10-25. Idea 2 of `2026-10-25-beyond-a-screen-recorder.md`, first half: the same take
exported as a step-by-step guide. Built on `2026-10-25-a-recording-knows-its-steps.md`.

## What it produces

**A folder a person can drop into their documentation**: `guide.md`, `guide.html` (self-contained,
no script, no network), and one picture per step, `step-01.png`, `step-02.png`, …

    # Exporting a movie from Keynote

    1. Click **Export** in Keynote.
       ![Step 1](step-01.png)
    2. Choose **Movie…**.
       ![Step 2](step-02.png)

- **The words are the interface's own.** "Export" is the element's AX title, so a guide line is
  exactly what the person will see on screen, never a guess from pixels and never empty — a step
  is a press the log named.
- **The verb follows the role**: a menu item is chosen, anything else is clicked. Two verbs, not a
  table of twenty: "Select" for a cell and "Turn on" for a checkbox would need the checkbox's state,
  which the log does not hold, and a wrong verb is worse than a plain one.
- **The application is named once per change of application**, not on every line.
- **The picture is the composed frame at 0.15 s before the press**, through the export's own
  composition (`StillFrameExporter`) at the export's size: the target is on screen and the menu it
  opens is not yet over it, and the camera — 0.4 s of pre-roll — is already on it.
- **The guide follows the edit.** A step whose press was cut out of the video is not in the guide;
  the numbering is the guide's own, 1 to n, over the steps that remain.

## The part that is a security question

A step's label is text from **another application** — a page's link text, a file name in a list,
anything an app chooses to title a control with. Written into Markdown it could carry `**`, `[ ](`
or a raw `<tag>`; written into HTML, a `<script>` or an `onerror=` that runs when the guide is
opened in a browser. So every label is escaped for the format it is written into, by pure
functions in the package with tests that put the hostile strings through them: `StepGuide.markdown`
and `StepGuide.html` are the only writers, and neither interpolates a label anywhere else.

## Where it lives

- `Framing.StepGuide` — pure: given the steps that survive the edit, their picture names and the
  sentences, the Markdown and the HTML, escaped. The sentences arrive already localised: the
  package has no strings table and should not have one.
- `Soredemo/Export/GuideExport` — the app half: which steps survive the cut, their output times,
  the localised sentences, the pictures through `StillFrameExporter`, the folder.
- An "Export Guide…" command beside "Export Frame…", enabled when the recording has steps.

**Not in this commit:** a box drawn around the pressed element on each picture. The composed frame
is zoomed and placed on a card, so the element's recorded frame has to go through the render plan
to land on the picture; that mapping exists inside the compositor and is its own design. The
picture without the box is already what the guide tools show when their highlight misses.

## How it is verified

- `StepGuide` in `FramingTests`: the Markdown and HTML for three steps across two applications —
  the application named on the first line and on the change, not on the line between; a menu
  item chosen and a button clicked; numbering from 1. **Hostile labels**: `**bold** [x](y)` comes
  out inert in Markdown, `<img src=x onerror=alert(1)>` and `</p><script>` come out as text in
  HTML, and an `&` survives as `&amp;`. Mutations: either escape removed; the application named on
  every line.
- `GuideExport` in the app tests: steps inside a cut are dropped and the rest renumbered; output
  times come through the edit, on a fixture with a cut before the steps so source and output differ.
- The folder is opened and read by a person.

## Where it ended

As decided, with two small changes. The status after a save names the folder and not the count —
a count would need a plural rule in ten languages for a number the folder already shows. And
`RecordedStep` gained a public initialiser, for the app's tests; production steps still come
only from `RecordedSteps.steps(from:recordingEnd:)`.

The sentence templates are localised in all ten languages with `{label}` and `{app}` placed where
each language puts them ("{app} で {label} をクリックします。"); `StepGuide` fills them, escaped.

Core: six `StepGuideTests`; four mutations, each red on its own test — the Markdown escape
removed, the HTML escape removed, the application named on every line, a newline kept inside a
label. App tests 317 → 321 on a recording with 2–5 s cut and an anchor 500 s after boot; three
mutations, each red — steps inside the cut kept, the picture taken at its source time, no lead-in.

**Not checked by a test, and said so:** `GuideExport.write` — the folder, the files' names and
that the pictures come first — runs only in the app, through `StillFrameExporter`, which has its
own tests. **Not seen in the running app:** a guide written from a real recording and opened in a
browser and a Markdown viewer.
