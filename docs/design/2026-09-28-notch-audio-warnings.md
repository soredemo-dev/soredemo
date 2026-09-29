# Two things the notch says about sound (and a chapter mark, withdrawn)

2026-09-28. Asked for as "what should the notch do next"; two were chosen, and the first was
withdrawn a day later.

## 1. A chapter mark, placed during the take — WITHDRAWN 2026-09-29

Shipped in `a71e6ee` and removed the next day. The owner tried it and did not find it useful: a
bookmark glyph in the notch did not say what it did, and they had to ask. It was removed whole —
the `mark` record, `CaptureSession.markChapter()`, the ⌥⌘M key, the notch and bar buttons, the
seeding of chapters on open, `ChapterOrigin.marked` and probe § 31 — rather than hidden, so no
code is left without a caller.

**What was not needed, and why:** no reading-compatibility shim for `ChapterOrigin.marked`. The
owner confirmed no project was saved while the feature existed, so no file carries that origin.
Recordings made in that window may hold `mark` lines in their observation logs; every reader
switches on `kind` and ignores kinds it does not know, so they are inert.

**If it comes back:** the design below the fold of `git show a71e6ee` still holds — the log was
the right home, and `SegmentTable.contentTime` the right placement. What failed was the surface,
not the mechanism.

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
