# Handing the cut over

*Code: `Core/Sources/Compositing/FinalCutXML.swift`. Moved out of that file's header
2026-08-30 — four section headings is a document written in the wrong place.*

**The cut, in a format a real editing application reads.**

The one thing on the gap list that turns this from a closed tool into one that hands off.
It is rare among recorders, and an
implementation worth reading, at a thousand lines, and reading it is where most of what
follows comes from.

FCPXML is Final Cut Pro's interchange format and **DaVinci Resolve reads the same files**,
which is why this is worth more than its name suggests: between them they are most of the
professional editing on this platform.

### What this carries, and what it deliberately does not

It carries **the cut**: the recording as an asset, and the clips in output order with their
in-points, their lengths and their speeds. That is the workflow this is for — cut here, where
the transcript is and where deleting a sentence removes a sentence, then finish in Resolve
against the original footage.

It carries **none of the look**. No zooms, no cursor smoothing, no background, no rounded
card, no camera overlay, no captions. Those are not omissions to be filled in later: an NLE
has no vocabulary for them, and a file that claimed to carry them would arrive looking like a
raw screen recording with no explanation. Somebody who wants the look exports a video; somebody
who wants to keep editing exports this. **Said out loud in the interface**, because "export to
Final Cut" reads like a promise to carry everything.

**The camera IS carried, on a connected lane**, and an earlier version of this comment said it
could not be because the offset was unknown. That was wrong: the recorder measures it —
`cameraStart - screenStart`, from the two recordings' own first-frame instants — and the
preview has been compositing with it all along. A connected clip is how an editing application
spells "a second angle of the same take", so the camera is cut exactly as the screen is and
arrives on its own lane where somebody can move it, resize it, or throw it away.

### Times are rationals, and they must land on frames

Every time in FCPXML is a rational number of seconds written `"N/Ds"`, and `"0s"` for zero.
**They have to be whole multiples of the frame duration.** A value between frames is where
importers disagree: some round, some refuse the document, and the ones that round do not agree
with each other. So every time here is computed as a FRAME COUNT first and the denominator is
always the sequence's frame rate — which also means every number in the file reads directly as
"which frame", instead of as a fraction somebody has to divide.

### Version 1.10, chosen rather than defaulted

FCPXML's version attribute is gated on a literal allow-list by both applications, so it is the
one number that decides whether a file opens at all. **1.10 is the broadest**: every DaVinci
Resolve from 18 up and every Final Cut from 10.6 up accepts it, where 1.11 and above need
Resolve 21. Nothing emitted below has existed for less time than 1.10, so a higher version
would buy exactly nothing and cost everybody on an older install.

### What is NOT verified here, said plainly

This file is checked for being well-formed XML and for round-tripping — parsed back, the clips
reconstruct the timeline they came from, frame for frame. **It has not been opened in Final Cut
or Resolve by anything in this repository**, because neither can be driven from a test: Resolve
is installed on the machine this was written on and ships no DTD and no scripting module, and
Final Cut is not installed at all. So the claim made here is "this is the document the
reference describes", not "this application accepted it". Dragging one file into Resolve
settles it in ten seconds and nothing in a test suite can.
