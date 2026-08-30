# What the exporter reads

*Two decisions moved out of the exporter's own source 2026-08-30, where each had grown
past the comment budget.*

## Building the edited asset

*From `Core/Sources/Compositing/EditedAsset.swift`.*

**One asset containing only what survived, in output order.**

Each surviving clip's source range is inserted into a composition track, so the result's
own timeline IS the edited one and everything downstream — the reader, the video
composition, the writer — counts in output time without knowing an edit happened.

`merged()` first: two clips that abut in the source are one read here. The unmerged form
exists so a reviewer's timeline can show where a cut was made, which an exporter has no
use for.

One composition track per SOURCE audio track, not one mixed track: a master carries
system sound and the microphone separately, and mixing is `AVAssetReaderAudioMixOutput`'s
job further down. Doing it here would mix twice.

`substitutingAudio` replaces individual audio tracks with the first audio track of
another asset, keyed by index into the source's own audio tracks.

**Per track, not for the whole asset, because the two tracks are not interchangeable.**
A Soredemo recording carries system audio and a microphone separately
(`AudioMixBuilder.trackOrder`) and a person mixes them separately. Noise removal produces
a cleaned MICROPHONE and must leave system audio exactly as recorded — so the shape of
this parameter is what stops a cleaned track being pasted over both.

A substitute that cannot be read leaves the original in place rather than dropping the
track: losing the voice is a worse outcome than keeping its hiss, and a cache file that
has been deleted under the app is an ordinary thing.

## Why both writer inputs are fed from one loop

*Moved out of `Core/Sources/Compositing/MP4Exporter.swift` 2026-08-30 — a set of measured decisions is a document.*

**One loop feeding both inputs, and the alternative is a deadlock.**

The first version wrote all the video and then all the audio, with a comment asserting
that `AVAssetWriter` accepts its inputs' data in any interleaving. That assertion is
false, and a real export found it: the writer stops signalling
`isReadyForMoreMediaData` on an input that has run far ahead of its siblings, because
it cannot lay out the file until the others catch up. A 15-second recording with audio
stalled at frame 134 — 2.23 seconds at 60 fps, which is the writer's interleaving
window, not a coincidence. The two-second fixture the tests used fit inside that window
and passed.

So both inputs are fed from one loop, whichever is behind in presentation time and
ready. Preferring the one that is behind is what keeps them within the window; falling
through to the other when the preferred one is momentarily not ready is what stops a
wait on one input from starving the other, which would reproduce the same deadlock with
extra steps.

**The video is resampled to a CONSTANT frame rate — a separate repair, kept here.**
`AVVideoComposition.frameDuration` does not resample: measured on the 10 fps fixture
with `frameDuration` set to 1/60, the export came out as 20 frames at exactly the
source's 100 ms spacing. That is fatal for screen recording, because ScreenCaptureKit
emits a frame when the screen changes and not otherwise — a real 11.4 s recording
measured 501 frames with gaps from 6.7 ms to 35 ms.
