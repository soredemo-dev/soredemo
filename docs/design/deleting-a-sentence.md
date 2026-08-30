# Deleting a sentence

*Moved out of `Core/Sources/Overlays/Transcript.swift` 2026-08-30 — a set of measured decisions is a document.*

**The span of the recording a "delete this sentence" removes: the sentence, and only
the sentence.**

`nil` for an index outside `segments`, or for a segment whose own times are degenerate —
a recogniser can report a zero-length run, and cutting nothing while telling somebody
their sentence was deleted is worse than refusing.

**The pause after it is deliberately left, and a first draft took it.** Speech is
separated by pauses, so cutting only the words leaves one on each side of the join and
a doubled pause reads as a fault rather than as an edit — which is the argument for
extending the cut to where the next sentence begins. It is the wrong argument here for
two reasons. A gap between sentences can be ten seconds of deliberate pause as easily as
a breath, and a rule that swallows it removes content nobody asked to remove. And this
app already has one owner for where the silences are and what to do about them —
`SilenceFinder`, the Silence lane, and `Remove Silent Span(s)` — so deciding it a second
time here would be a second answer to a question already answered, the same fault
`MusicDucking.speech(betweenSilences:over:)` exists to avoid.

In practice the gap is usually small anyway: a recogniser endpoints AFTER a silence
threshold, so a segment's own end already carries part of the pause that ended it.

**Source time, so a second deletion needs no re-mapping.** A transcript is timed against
the recording, not against the edit, and `EditTimeline.removing(sourceRange:)` takes
source time too — so deleting three sentences one at a time gives the same result in any
order, and none of the three ranges has to be recomputed after the others land.
