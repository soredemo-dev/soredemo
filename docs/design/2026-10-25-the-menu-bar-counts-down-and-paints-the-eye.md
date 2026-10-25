# The menu bar counts down and paints the eye

2026-10-25. The website's daruma page (the brand's reference drawing of the mark) shows the menu
bar item in five states and says each is one `MenuBarRecorderLabel` already has. It had three:
idle, recording and paused. The owner asked for the other two to be real rather than the page's
sentence to be corrected.

## The two states

**Counting down.** Between choosing what to record and the recording starting, the painted eye is
faint — the record red at 35 % — and a red ring around it drains once per second, from the top,
clockwise. It is the countdown panel's ring, at menu bar size: a person who has looked away from
the middle of the screen still sees how long they have.

**Finished: the second eye is painted.** When a recording stops and a file exists, the dashed
eye that waits on every other drawing of the mark is filled in for 2.6 seconds — 目入れ, the
daruma's eye painted when the work is done — and the item returns to idle. The menu bar mark has
no dashed eye (too fine at 16 points), so the filled eye appears where it would be.

## Decisions

- **One pure function decides the state** — `MenuBarMark.state(countdown:isRecording:isPaused:
  isFinished:)` — so the order between them is a test rather than an `if` chain in a view.
  Recording and paused outrank everything; then the countdown; then finished; then idle. A
  countdown that starts while the eye is still painted is what shows: the next take has begun.
- **The countdown is read from `CountdownPresenter`**, which already wakes every tenth of a second
  to answer ⎋. It now publishes the running `CountdownState`, and that state counts the tenths
  gone in the current second, so the ring drains in ten steps a second and needs no clock of its
  own — the app target reads no ambient time.
- **"Finished" is a flag with a timer, owned by a small type** (`PaintedEye`), set by the
  coordinator at the one place a recording is known to have produced a file — where `mediaURL`
  is assigned. Painting again restarts the 2.6 seconds; an earlier timer cannot clear a later
  paint.
- **Drawing.** Finished has no colour, so it is a template image like idle and paused. Counting
  down has red in it, so it is drawn the way recording already is: the body filled with
  `labelColor`, the faint red eye over it, and the draining ring drawn per frame. Every state is
  on the same canvas, so the item keeps one width.
- **The ring is drawn in code, so the code knows where the eye is** — `MenuBarMarkGeometry`, the
  script's small-mark numbers and its 88 % ink share. Two places hold one geometry, so a test
  checks the drawn ring against the eye the script baked into `LogomarkCountdownEye`.

## How it is verified

- `MenuBarMarkTests`: every state from its inputs, including the precedence between them; the
  countdown's ring fraction from its tenths, on a non-zero second (not at the identity of a full
  ring). Mutations: finished outranking the countdown; the fraction ignoring the tenths.
- `PaintedEyeTests`: painted after `paint`, cleared after its duration, and a second paint not
  cleared by the first one's timer. Mutation: the generation check removed.
- The geometry agreement: the centre of `LogomarkCountdownEye`'s ink, measured from the asset,
  is where `MenuBarMarkGeometry` puts the eye. Mutation: the eye moved in the code.
- Looked at: the menu bar during a real countdown and just after a real recording stops.

## Where it ended

As decided. `MenuBarMark` in `Soredemo/Recording/MenuBar/MenuBarMark.swift`, with `PaintedEye`,
`MenuBarMarkGeometry` and `CountdownMark`; `CountdownPresenter` publishes its running state and
`CountdownState` counts its tenths; the coordinator paints the eye where a Mac take and a phone
take each produce their file. The script draws two more images — `LogomarkDoneTemplate` and
`LogomarkCountdownEye`. Opening a saved project paints nothing: no take finished.

`MenuBarMarkTests`, seven. Written against stubs that compiled and answered wrongly, six went red
and one passed — the cancelled count, which the stub's constant `.idle` happened to satisfy.
Mutations, each red on its own test: finished put above the countdown; the ring ignoring the
tenths (three tests); the cancel ignored (the one that had passed on the stub); the generation
check removed; the eye moved two units in the code (the geometry agreement).

**Looked at, and it found one thing.** A real take, photographed every quarter second: the ring
drains round the faint eye, the eye fills red when the capture runs, and after Stop the second
eye is painted for about two and a half seconds before idle. Between the count's end and the
capture running, one frame showed **idle** — `newSession.start()` is awaited there, and neither
the count nor the recording was true. The coordinator now says so (`isStartingCapture`), and the
mark holds the count's last frame — the faint eye, no ring. Test first: red while the flag was
ignored, green after. Looked at again at a tenth of a second a frame: the ring runs out, one
frame holds the faint eye with no ring, and the next is the red eye. No idle.
