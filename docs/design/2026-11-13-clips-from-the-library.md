# Clips from the library on the timeline

*Written 2026-11-13, the second stage of `2026-11-12-from-a-demo-to-a-launch-video.md`, after the
owner chose full multi-source editing over opening and closing cards only: a library's videos and
pictures go anywhere in the edit, and the agent assembles a finished video from one sentence.*

## The question

`EditTimeline` is a list of clips, every one a span of the recording. The preview and the export
cut one asset by it (`EditedAsset`), and the compositor maps each output moment back to the
recording to draw the cursor, the zoom, the captions and every overlay. A clip that is not the
recording breaks three assumptions at once:

1. every clip has a span of the recording — the cursor, the zoom and the cut proposals ask for one;
2. the composition has one source — `EditedAsset` reads one asset;
3. every frame is the recording — the compositor crops, zooms and draws a pointer on it.

So: how does a clip say what it is, what happens to each of those for a clip that is not the
recording, and in what order does it land?

## Decided

**1. A clip names its source.** `EditClip` gains `source`: `.recording` (the default, and what
every clip in every project already is — absent in a saved project means this), `.video(item:)`
for a library video, read from `sourceStart` for `duration` of *that* file, and `.picture(item:)`
for a library picture held for `duration`. Ids, speed and fades stay what they are. The decoder
refuses a library clip with a negative span, as it refuses one of the recording.

**2. Only the recording has a source time.** `sourceTime(atOutput:)` answers `nil` inside a
library clip, as it already does past the end: no cursor, no zoom, no recording caption, no
observation is placed there, because none was observed. `outputTime(atSource:)`,
`clip(atSource:)`, `survival(ofSource:)` and every cut by a span of the recording consider
recording clips only, so a cut proposal can never land inside a picture. Output durations count
every clip.

**3. The composition reads every source.** `EditedAsset.make` is given the library's files by id;
a video clip's span is inserted from its own asset, a picture clip is empty time on the video track
and silence on the audio tracks. A library video's sound goes on its own audio track, so the
recording's mix and noise removal never touch it.

**4. The compositor draws what the moment is.** For output time inside a library clip the stage
draws the clip's frame or picture fitted to the card, with the style's background, corners and
shadow — so an inserted clip looks like it belongs — and nothing that comes from the recording:
no crop, zoom, pointer, keystroke or recording caption. Titles, marks and hidden regions are
placed in source time today; they appear only over the recording until they gain an output-time
placement, which is said in the inspector rather than left to look like a bug.

**5. Inserting is one edit.** `inserting(_ source:, duration:, atOutput:)` splits the clip under
the playhead if it lands inside one and puts the new clip between, as one undo step. The agent's
`insert_from_library(item, at, seconds?)` does the same, refused for an item that is not in the
library or a span past the file's end.

## In what order, each observable

1. `EditClip.source` and the timeline's rules, with the decoder — Core, tests only.
2. `EditedAsset` from several sources, and the compositor's library frames — the preview shows an
   inserted picture and plays an inserted video.
3. Inserting from the Library tab and from the agent; the timeline draws a library clip with its
   kind; export carries it.

## Alternatives not taken

- **Cards at the start and end only.** The owner's choice was the whole edit.
- **A second timeline track for library media, over the recording.** That is picture-in-picture,
  a different feature; a launch video cuts between sources, it does not stack them.
- **Encode each picture as a long still movie and insert it like any video**, as an open-source
  editor read for this does. *Corrected the same day:* this document first refused it as "a second
  rendering path whose look drifts", which is false — the movie would be the raw picture, and the
  card, corners and shadow would still be the compositor's. The real comparison is narrower. The
  movie gives every moment a source frame, at the cost of encoding a file per picture (time,
  space, an encoder's 4096-pixel limit). Empty time costs nothing to make, and the question was
  whether a custom compositor is even called inside it — **measured on macOS 27.2: it is**, with
  an empty `sourceTrackIDs` and no source frame, between two media segments that both arrive
  normally. So empty time, with the compositor drawing the picture; recorded as D6b-37, because
  it is a platform behaviour the whole path rests on.
