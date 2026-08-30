# Is the file a recording?

*Code: `Core/Sources/Capture/RecordingHealth.swift`. Moved out of that file's header 2026-08-30 — two section headings is a document written in the wrong place.*

**Whether the file a recording just produced is actually a recording.**

The worst failure this app can have is not a crash. It is a person who talks for eleven
minutes, presses stop, and finds out later — in the editor, or on the day they meant to
publish — that the file is four seconds long or will not open. A crash costs a restart;
this costs the eleven minutes, and they cannot be recorded again.

Nothing here checked for it. The sequence below is the one that makes each check mean
something: does the file exist, is it non-empty, does the container open, does the video
actually decode, and is it as long as the recording was.

### Each check catches something the one before it cannot

They look redundant and they are not. A file can exist and be empty — a writer that was
killed before its first flush. It can be non-empty and not open — an `.mov` whose `moov`
atom was never written, which is exactly what a power cut leaves behind, and which is the
most common way a recording dies. It can open and have no video track — an audio-only
asset, which is what a screen capture that never received a frame produces. It can have a
video track that will not decode. And it can decode perfectly and be four seconds long.

**The decode check is the one worth having and the one people leave out.** `AVAsset` will
happily report a duration for a file whose frames are unreadable; only pulling a frame
through the decoder proves there is a picture in there.

### Why the length check is loose, and why loose is right

A recording's expected length is wall-clock from start to stop, and the file is legitimately
a little shorter: the last partial frame is not written, and a segment boundary can land
just before the stop. So an exact comparison would cry damage on every healthy recording,
which is worse than not checking — an alarm that is usually wrong is an alarm people learn
to dismiss, including on the day it is right.

`shortnessThreshold` is therefore set where only a catastrophe reaches it: **half**. A file
that is 49% of the length of the session it recorded did not lose a frame at the end; it
stopped writing.

And nothing is checked at all below `shortestWorthChecking`. A one-second recording is
within rounding of every threshold, and the ratio is meaningless there.
