# Marking a chapter while recording, and two things the notch says about sound

2026-09-28. Asked for as "what should the notch do next"; these two were chosen.

## 1. A chapter mark, placed during the take

**The question.** A person narrating a demo knows where the sections begin *while* they are
recording it. Afterwards they have to find those moments again by scrubbing. The chapters tab
exists (`2026-09-27-chapters.md`); nothing feeds it from the recording.

**Where the mark lives: the observation log, as a `mark` record.** It is an observation — a person
did something at an instant — and the log is where observations are stamped in the host clock and
survive with the recording. The alternatives:

| Option | Why not |
| --- | --- |
| a list on `RecordingCoordinator`, handed to the editor | lost the moment the app quits between the take and the edit, and a reopened recording would have no marks |
| straight into `EditState.chapterTrackData` at stop | writes an *edit* the person has not made yet, and a recording opened without its project would lose them |
| the log (chosen) | already per segment, already epoch-stamped, already read back by the editor for stillness |

`mark` is **declared unconditionally**, for `still`'s reason: it needs no permission, so `mark: 0`
in the trailer is a measurement ("none were placed") and not a claim the session could not make.

**When a mark becomes a chapter: when the editor opens a recording with no saved edit.** A saved
edit already carries whatever the person did with the marks — kept, retitled, removed — and
reseeding over it would put back chapters they deleted, which is the producer-value rule broken
by the side door. With no saved edit there is nothing to override.

**Origin: a new `ChapterOrigin.marked`.** The *moment* is the person's; the *title* is not yet —
it is a placeholder numbered in order. Editing the title turns it `.authored`, which
`ChapterTrack.retitled` already does for every origin. The panel says "Marked while recording"
beside it, as it cites a sentence for a suggestion.

**Host time to recording time: `SegmentTable.contentTime(of:)`.** A pause is a gap between
segments and occupies no content, so a mark's place in the video has to be computed against the
table, not as an offset from the first frame — `FramingPlanReader.offset` would put every mark
after a pause late by the length of the pause. A mark that lands in no segment (a press in the
instant before the first frame, or in a gap) is **refused and counted**, never clamped to the
nearest edge: clamping would place a person's chapter at a moment they did not choose.

**Refused while paused, at the source.** A paused take has no open segment. The button is
disabled, and `CaptureSession.markChapter()` reports `.noSegmentOpen` rather than writing a
record that could not land.

**The shortcut: ⌥⌘M, registered only while a take runs.** A system-wide hot key swallows its
combination in every application; holding one when nothing is recording would steal it for no
reason. `InputObserver.approvedShortcuts` does not list it, so pressing it never becomes a
keystroke badge in the video — asserted by a test, because the day someone approves `cmd+opt+m`
every mark would draw one.

## 2. The notch says when the microphone hears nothing

**The failure it exists for:** ten minutes recorded against a muted interface or the wrong input,
found afterwards. The meter is already in the notch; a meter at the bottom of its track looks
identical to a quiet room.

**"Nothing" means no signal, not no speech.** `MicrophoneSilenceWatch` goes off when, for five
seconds without a break, either no buffer arrived (`delivered` did not move — a device that stops
delivering leaves `latestRMS` at its last value, so the level alone cannot see it) or every buffer
was below −80 dBFS (RMS 1e-4). **The threshold is chosen, not measured**, and is chosen below any
working microphone's noise floor so that it fires on a dead input and never on a person pausing
to think. A person who is merely silent is not told anything. It is recorded in D6b.

Five seconds is the patience; the watch resets on resume, because the clock does not tick while
paused and a pause is not silence.

## 3. The notch says when the speakers will be heard by the microphone

**Only a hint, only when it is true.** With the built-in microphone and the built-in speakers,
whatever the Mac plays — the demo's own audio, a notification — reaches the take twice. The
notch's open surface says so and suggests headphones. It does not suggest muting: whether
ScreenCaptureKit's system audio is taken before or after the output volume is unmeasured, and if
after, muting would silence the system-audio track as well. That measurement plays sound and
changes the volume and is waiting for the owner's consent.

**What "built-in speakers" is, measured on this machine (MacBook Pro, macOS 27):** the default
output device reports transport `bltn` and output data source `ispk`; the built-in microphone
reports transport `bltn`. The headphone case was not measured — nothing was plugged in — so the
rule is `bltn` **and** `ispk`, and an unreadable data source means no hint. A wrong hint is mild in
either direction; a hint shown to someone wearing headphones is the one that teaches people to
ignore it, so unknown resolves to silence. D6b.

The decision is a pure function (`EchoRisk`) of what was read; the Core Audio reads are one file.
