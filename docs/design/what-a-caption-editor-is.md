# What a caption editor is

*Researched 2026-08-30. Two sources, kept apart because they answer different
questions: a shipping subtitle tool read from its own interface, and the published
subtitling standards that say what the numbers in that interface mean.*

Soredemo's caption panel has a control for every field of `CaptionStyle` and a list
of cues you can retype. That is a form over the data. A caption editor is not a form
— it is a **transport, a list and a waveform that stay in step**, and the reason it
is worth building is that correcting captions is done at the pace of playback, not at
the pace of a text field.

## The numbers, from the published standards

These are what the metrics in a caption editor are measured against. They are not
this project's opinions; they are what the industry converged on, and they are cited
so a future change can argue with the source rather than with a previous draft.

| | Latin script | Chinese / Japanese / Korean |
|---|---|---|
| Characters per line | **42** | **~16** |
| Lines per cue | **2** (three is not permitted) | 2 |
| Reading speed | **17 CPS** adult, 13 children (Netflix quotes 20 for English adult) | **9 CPS** |
| Minimum on screen | **5/6 second** (20 frames at 24 fps) | same |
| Maximum on screen | **7 seconds** | same |
| Gap between cues | at least **2 frames** | same |

The CJK figures are roughly half the Latin ones for the same reason a CJK line is
half the length: a full-width character carries about what two or three letters do,
so 9 CPS of Chinese is about the information rate of 20 CPS of English.

**The two reading speeds are one number in a different unit, and that is now how this
is implemented.** Measured in DISPLAY WIDTH — a full-width character being two columns
— 17 CPS of Latin is 17 and 9 CPS of CJK is 18: the same figure within six per cent.
They differ because they are quoted in different units, not because reading Chinese is
a different act. `CaptionMeasurement.widthPerSecond` is the single limit and the two
published figures are what it reproduces.

The idea came from reading a shipping open-source subtitle pipeline (`SmartSub`),
which measures line length in East-Asian display width rather than in characters.
Adopting it closed a hole this project had documented and accepted: `CaptionScript.of`
calls a line spaced if it contains one space anywhere, so a Chinese caption with a
single English word in it was held to the Latin limit. Width counts each character for
what it occupies whatever its neighbours are.

The line lengths stay two numbers — 42 of width for Latin and 32 for CJK — because the
guidelines really do differ there: a CJK line is held shorter than its width alone
would allow.

**Implemented 2026-08-31** in `CaptionScript`, which carries both columns, and in
`CaptionMeasurement`, which judges a cue against the column its text belongs to.
`CaptionBuilder.longestLine` is now `CaptionScript.spaced.longestLine` rather than a
42 of its own, and `CaptionBuilder.minimumDisplay` is
`CaptionMeasurement.shortestDisplay` — it had been 700 ms, chosen before this project
had a source, and two numbers would have meant the panel warning about lines the
builder had just produced.

The one figure still not enforced anywhere is **two lines per cue**: nothing counts
the lines a cue will occupy once drawn, so a long CJK caption can still wrap to three.

## What the interface of a shipping subtitle tool actually has

Read from six screenshots of What'Sub, a Traditional Chinese subtitling service,
including its own walkthrough video. Named here rather than in the source, per
CONTRIBUTING.

### The generation screen is a list of named stages, not a bar

Five stages, each with its own elapsed time, the finished ones ticked and the running
one highlighted: extract audio (8 s) → upload audio (4 s) → transcribe → break and
polish the lines → save. Above them, the **waveform doubles as the progress bar** —
played green, remaining grey — so progress is shown against the thing being worked on
rather than against an abstract 0–100.

Three sentences carry the rest of it. "You can go and look at another page — the
progress is in the bottom-left corner, and it saves into the project when it's done."
"The transcription is being typed one word at a time — the longer the film the longer
it takes, and this step is the slow one." And a Cancel button that is present the
whole time.

Soredemo's `TranscriptionProgress` has three cases and the panel prints one line of
text for whichever is current. No per-stage timing, no waveform, and nothing that says
the work survives navigating away.

### The editor is three panes that stay in step

**A waveform at the top.** A ruler in half-seconds; every cue drawn as a box spanning
its own time range with its text on a label at the top-left; a drag handle on each box
for moving a boundary; thin ticks inside a box at the word boundaries; a zoom control
(seen at 42% and 58%); and gaps with audio but no box, which is where a cue is
missing. Under it, the selected cue's `start`, `end` and duration to the millisecond,
and a **cut-point detection** button that snaps a boundary to where the speech
actually starts.

**The video in the middle**, with the caption burnt in as it will look, plus a **safe
frame** toggle and a **caption style** button beside it.

**The cue list on the right.** One row per cue: timestamp, text, and the character
count in a right-hand column. The row at the playhead is highlighted and the list
scrolls itself to keep it visible. There is a **search field** over the list. Editing
happens **in the row** — the list gets a border and a floating `Editing | Esc | Done`
badge, and the caret is in the text where you clicked. A row's character count turns
**red** when something about that cue is wrong.

**A status line under the list**, for the selected cue only:
`00:01.900 · 3.00 秒 · 11 字 · 3.7 字/秒`, and where the reading speed is out of
range it adds the verdict in words — `8.2 字/秒 偏快` (*too fast*). One screen also
shows `信心 我 55%`: the recogniser's confidence, with the specific word it was least
sure of named, so you know which character to look at rather than re-reading the line.

**A keyboard strip along the bottom**: `Space pause`, `↑ ↓ jump between cues`, and a
rotating tip — `B splits a cue in two at the cursor`. Beside it, `auto-saved · 270
cues`.

### The keymap, confirmed twice

A second reference — an open-source, local-first subtitle editor built explicitly as a
keyboard-driven proofreading tool — uses the SAME keymap, and says in its own spec that
it copied it. Two independent tools converging on one keymap is the strongest evidence
available that it is the right one, and it is also every text editor's:

| key | what it does |
|---|---|
| Return, caret inside the text | split into two cues there |
| Backspace, caret at 0, nothing selected | merge into the previous cue |
| Tab / Shift-Tab | next cue / previous cue |
| click a cue | seek to it |
| the row's own ✕ | delete the cue — Backspace's meaning is reserved for merge |

That editor also records a decision NOT to build an "Alt quick mode", on the grounds
that Return-splits and Backspace-merges already cover it. **Built here 2026-08-31**, in
`CaptionField`: the caret is the argument to two of those keys and SwiftUI's `TextField`
publishes neither its selection nor a way to see a key before the field consumes it, so
this is an `NSTextField` behind an `NSViewRepresentable`. That cost was named as a
blocker when the list was first written; two references agreeing is what made it worth
paying.

### What that is, stated as rules rather than as a screenshot

1. **Clicking a cue moves the playhead.** The list is a way of navigating the
   recording, not a table of its contents.
2. **The playhead moves the selection.** They are the same cursor seen twice.
3. **Every cue carries its own measurements**, and a cue that breaks a rule says so
   where the cue is, not in a summary somewhere else.
4. **Editing happens in place**, and Esc is how you leave.
5. **Boundaries are draggable and snap to speech**, because the recogniser's idea of
   where a sentence starts is usually a little early.
6. **Split and merge are single keys**, because that is what most caption editing is.
7. **The corrections survive leaving.** It auto-saves and says so.

## What Soredemo's caption panel has, honestly

| | What'Sub | Soredemo today |
|---|---|---|
| Cue list | ● right-hand pane, full height | ● an inspector column, widened to fit a whole line |
| Click a cue to seek | ● | ● *(2026-08-31)* |
| Follows the playhead | ● highlight + auto-scroll | ● *(2026-08-31)* |
| Search the cues | ● | ● *(2026-08-31)* |
| Per-cue duration / characters / CPS | ● with an out-of-range verdict | ● count on the row, the rest for the focused cue |
| Recogniser confidence per word | ● names the weakest word | ● *(2026-08-31)* |
| Edit in place | ● Esc / Done | ● every row is a live field |
| Adjust a cue's start or end | ● waveform handles + millisecond fields | ● *nudged in 100 ms steps (2026-08-31)* |
| Split a cue / merge two | ● one key each | ● Return at the caret / Backspace at the start |
| Snap a boundary to speech | ● | ● *both ends at once, 2026-08-31* |
| Waveform with cue blocks | ● zoomable | ● *on the timeline, not in the panel — see below* |
| Safe-frame overlay | ● | ● *(2026-08-31)* |
| Import corrected subtitles | ● | ● *(2026-08-31)* |
| Named stages while generating | ● five, each timed | ● *three steps, each timed, with Stop (2026-08-31)* |
| Caption style presets | ○ | ● four, added 2026-08-30 |
| Word-by-word highlight | ● | ● |
| Vocabulary for the recogniser | ● *(cloud model)* | ◐ spelling pass only — `teaching-the-recogniser-a-word.md` |

The row that mattered most was the one that used to be in bold: a caption whose timing
was wrong could not be fixed in this app at all. **Closed 2026-08-31.** Five of the six
below are now built, and the list has a search field and ⌥↑/⌥↓ between cues. What is
left is the waveform, snapping a boundary to speech, a safe-frame overlay, per-word
confidence, and the named stages while generating.

## The order these are worth building in

Not a roadmap, and nothing here is committed to. It is the order the list above falls
into once you ask which of them a person hits first.

1. **Seek on click, and follow the playhead.** Two small changes that turn the list
   from a table into a way of moving through the recording. Neither needs new state.
2. **Per-cue duration, characters and CPS, with the out-of-range verdict.** Pure
   arithmetic over what a `CaptionCue` already carries, and it is what makes the
   numbers above mean anything.
3. **Adjust a cue's start and end.** The hole. Needs `CaptionTrack` to accept a
   retimed cue and needs the boundaries not to cross their neighbours.
4. **Split at the caret and merge with the next.** The two operations the recogniser
   gets wrong most often, and they are what a person reaches for after (3).
5. ~~**Import `.srt`/`.vtt`.**~~ **Built 2026-08-31.** `SubtitleFile.read` takes
   either format, detected from the content rather than the extension, and reports
   every cue it could not use with the line it was on. The panel maps the file back
   through the edit, because the export wrote it in the export's clock.
6. ~~A waveform with cue blocks.~~ **Built 2026-09-10**, and not in the inspector — see below.

## The width was the thing the inspector could not give it

*2026-09-10, prompted by somebody using it.*

By 2026-08-31 the gap table above was nearly all filled in, and the panel was still hard to
edit captions in. The reason was not a missing feature. `InspectorWidth` had the measurement
written down since the day the list was widened: a 42-character line at the body font is 263pt,
and with the timecode, the reading-speed column and the fault label a row needs about **437pt**.
The inspector opens at **300**. The maximum was raised to 440 so the row *could* fit — but only
for somebody who knew to drag it, and the ideal was deliberately left alone, for a reason that
was right at the time: a panel that opens wide takes the width from the picture, for one tab.

So by default every caption row was truncated, and the red **too long** beside a line you cannot
see is an accusation rather than a help. That reason has been overtaken by its own codebase:
captions are no longer "one tab", they are the tab with the most work in them, and the only one
whose content has a measured minimum width.

**The answer is not a wider inspector.** It is that an hour of caption work is not inspector
work — it has its own transport, its own selection and its own keymap, and it wants the window.
`CaptionEditor` is the three panes this note concluded a caption editor *is*: the picture with
the caption burnt in, a waveform with a block per cue, and the list at full width. The inspector
stays exactly as it was, for the correction you make while looking at the shot.

`CaptionLines` is the list, extracted so there is one of it. Width belongs to whoever hosts it.

**What the waveform is for, since a list already has the numbers.** A cue that starts a beat
late is the most common thing wrong with machine timings and the one thing a list cannot show:
`0:19.6 → 0:27.3` says nothing, a box against the sound it covers says it at a glance. And a
stretch of audio with no box over it is a line the recogniser dropped — invisible in a list,
because a list has nothing to draw for a cue that is not there.

## Sources

* [Netflix Timed Text Style Guide: General Requirements](https://partnerhelp.netflixstudios.com/hc/en-us/articles/215758617-Timed-Text-Style-Guide-General-Requirements)
* [Netflix Timed Text Style Guide: Subtitle Timing Guidelines](https://partnerhelp.netflixstudios.com/hc/en-us/articles/360051554394-Timed-Text-Style-Guide-Subtitle-Timing-Guidelines)
* [Netflix Chinese (Traditional) Timed Text Style Guide](https://partnerhelp.netflixstudios.com/hc/en-us/articles/215994807-Chinese-Traditional-Timed-Text-Style-Guide)
* [Subtitle standards compared: Netflix, BBC, Amazon](https://subhero.io/blog/subtitle-standards-guide)
* [Subtitle limits by language: CPS and line length](https://sublingo.cc/guides/subtitle-specs-by-language)
* [Aegisub — Editing Subtitles](https://aegisub.org/docs/latest/editing_subtitles/)
* [Subtitle Edit — Main Window](https://subtitleedit.github.io/subtitleedit/features/main-window.html)


## Word gaps carry no silence, and that is why this cuts on audio instead

*Measured 2026-08-31, on the same 28-second narration.*

A third reference (`SmartSub`, open source) builds cues UP from word timings: it splits
wherever two tokens are more than 0.5 s apart, which is a real pause. That looked like
the structural improvement this project was missing — it builds cues DOWN from the
recogniser's segments — so it was measured before it was built.

**`SpeechTranscriber`'s word runs partition the segment.** Each word's `end` is the next
word's `start`, exactly:

```
|Welcome|       0 → 480000000
|to|    480000000 → 600000000
|this|  600000000 → 720000000
|walkthrough.|  720000000 → 1500000000
|Today| 1560000000 → 1800000000
```

The largest gap inside any of the nine segments was 0.000 s. At a segment boundary it
was 60 ms — the endpointer's own margin, not a pause. So a gap rule has nothing to read
here: it is not that it fails to help on this input, it is that the data does not
contain the thing it reads. `SmartSub` can use one because whisper.cpp emits raw token
times; Apple's transcriber hands back a partition.

What DOES carry it is the audio, and this project already measures it: `SilenceFinder`
finds the spans the Silence lane and the music ducking both read. `CaptionBuilder.cues`
now takes them and cuts a segment where the recording is quiet, **before** punctuation
or length get a say — a pause a person can hear is the break they would have made,
where punctuation is where they would have written one, which is not the same thing and
is often absent.

A span that overlaps a word rather than falling between two is ignored: the runs
partition the segment, so such a span is silence found in the middle of somebody
speaking, and cutting there splits a word from itself.

Two things also measured and worth keeping: the word runs **do** carry punctuation
(`walkthrough.`, `First,`), and joined with single spaces they reproduce the segment's
own text exactly — on all nine segments. That is what makes the cut safe to reconstruct
text from.


## What confidence is good for, measured before it was shown

*2026-08-31.* The gap table said "the API returns it; nothing reads it". That was an
unverified claim, so it was verified: `SpeechTranscriber` with
`.transcriptionConfidence` returns a value for **93 of 93** runs. It works.

Whether it is worth SHOWING is a different question, and the answer decided the design.

On a clean 28-second narration the distribution was: lowest 0.603, 5th percentile
0.782, 10th 0.867, median 0.997. The ten lowest were almost all sentence-initial or
sentence-final — `Trim`, `If`, `When`, `Once`, `A`, `screen.`, `makes.` — and **every
one of them was recognised correctly.** They are where the endpointer cut, not where it
was wrong. Flagging everything under 0.8 would mark 8% of words and be wrong about most
of them, which is exactly the "an alarm that is usually wrong is one people learn to
dismiss" failure this project names elsewhere.

Then the decisive test: the same probe on audio the recogniser genuinely mangles —
"Soredemo", which comes back as "Sorodimo" and "Sorodemo".

```
|Sorodimo| 0.462   ← wrong
|Open|     0.589      boundary
|Sorodemo| 0.610   ← wrong
|screen.|  0.675      boundary
```

Both mangled words rank in the lowest three. So confidence **does** find the wrong word
— it is just noisy, with boundary words interleaved.

That is a signal worth consulting and not worth alarming with, so:

* `CaptionCue.leastCertainWord` names the weakest word below **0.8**, which is where the
  measured tail starts — about the worst one word in ten.
* It is shown for the cue somebody has the caret in, and **nothing is coloured or marked
  by it anywhere**.
* `nil` rather than 1 when the recogniser did not say, because "did not say" and "was
  certain" are different answers and a default of 1 would make an older project claim a
  confidence nothing measured.


## The waveform row was wrong, and this is the second time

*Corrected 2026-08-31.* The table above marked "waveform with cue blocks" as absent on
the strength of the caption PANEL not having one. The editor's timeline has had all of
it the whole time: an audio waveform lane, a Captions lane of blocks, a Text lane, a
Zooms lane and a Silence lane, every one of them aligned to the same ruler, crossed by
one playhead, inside a `TimelineWindow` that zooms.

That is the second row in this project's own comparisons to be wrong about this
codebase rather than about somebody else's — region capture was the first, in the August market
survey (since replaced by `docs/research/landscape.md`). The failure is the same both times: a row
written by reading another product and then guessing at this one. **A comparison table
is a claim about this repository as much as about anyone else's, and the half about
this one is the half that can actually be checked.**

What was genuinely missing was one connection, and it is now there: **clicking a
caption block on the timeline moves the playhead to that cue.** The panel already
lights and scrolls to the cue the playhead is inside, so selecting follows from
seeking rather than being a second kind of selection to keep in step with the first.

The block's own index decides where the playhead lands, not the time under the
pointer: a lane of blocks is a list seen sideways, and clicking one means "that one" —
landing a few milliseconds inside a caption puts the playhead on the same cue but not
at its start, which is where somebody who clicked it wants to hear from.

Still different from the reference, and named rather than pretended away: the blocks
carry no text label, and their edges cannot be dragged. Dragging is what the nudge and
the snap in the panel do instead, on a lane fourteen points tall where a two-point
block would be a target nobody can hit — which is also why the tappable width has a
floor the drawn width does not.


## The panel was too narrow to show the line it edits, measured

*2026-08-31.* The last `◐` in the table was the caption list living in an inspector
column rather than a full-height pane. The column is already draggable — 260 to 380
points, plus a 40-point rail — so the question was whether its maximum was enough,
and that has an answer rather than an opinion.

`CaptionBuilder` breaks lines at 42 characters, and the line being edited is the one
thing that has to be readable whole. Measured at the 13pt body font:

| | width |
|---|---|
| a 42-character line | 263pt |
| the timecode | 35pt |
| the reading-speed column | 59pt |
| a fault label | 42pt |

That is about 437pt of content with the spacing and the list's insets. **At 380 the row
this panel exists to edit was truncated at every width it could be dragged to.** The
maximum is now 440; the ideal stays 300, because a panel that opened wide would take
that width from the picture for the sake of one tab.

And the row gave some back: the full reading is 59pt on every row, where a character
count is about 20 and is what a person scans a column for. The seconds and the rate
moved to the focused cue's own line, beside the least-certain word — which is where the
reference puts them too, and for the same reason.
