# Plurals, AppKit's plain strings, and a probe section that skipped

2026-09-27. The three things `2026-09-26-a-string-shown-verbatim.md` left open, and what looking
at them turned up.

## Probe section 18 — measured, and my first explanation was wrong

Four runs on 2026-09-26 got 2 complete frames in 2 s and skipped section 18; on 2026-09-27 two runs
got 23 and 99. The explanation offered in the release report was "the screen was still". A program
of its own doing only section 18's capture refuted it, and three more after it:

| condition | complete frames in 2 s |
| --- | --- |
| captured window still, screen otherwise active | 115, 116, 115 |
| another window animating | 117, 116, 117 |
| captured window fully covered by another | 61, 93, 75 |
| terminal idle for 25 s first, nothing on screen moving | 61, 61, 61 |
| display on throughout the skipped runs (`pmset -g log`) | — |

None comes near 2. What settles the part that matters: **section 18 runs no Soredemo code** — it
is an `SCStream` over the probe's own window — so the spread cannot be a regression in this
repository. It is the platform answering differently at different times, for a reason not found.
The section now captures for at least its original 2 s and then, if fewer than 10 frames have
come, until 10 frames or 10 s; a skip names the time it waited. The first version stopped at 10
frames, which cut a normal run from ~120 frames to 15 in 0.25 s — seen in its own first gate run
and corrected; the run after it took 121 frames in 2.1 s.

## `stopPolling()` did not stop polling

The second of those probe runs failed a different check: one poll counted after `stopPolling()`.
`dispatch/source.h`: cancellation "does not interrupt an event handler block that is already in
progress". `stopPolling()` was only `cancel()`, so a poll under way kept writing the observer's
state after the session had read it. It now drains the poll queue. The test holds a poll inside
its shape read, outside the lock, so the red is deterministic — the probe's check caught it once
in three runs.

## Plurals

"%lld caption(s)" was English's answer and every table copied its shape: "sous-titre(s)",
"субтитр(ов)", and "1 captions" in English itself. 21 counted keys now have a
`Localizable.stringsdict` rule in all ten languages — one/other, Russian's one/few/many/other,
none for Japanese, Korean and Chinese — and each keeps a `.strings` entry as fallback and as what
the source scans read. The formats were measured before being written 21 × 10 times: positional
outer formats (`%2$#@n@`) with plain `%lld` inside the rule, in Russian at 1, 2, 5 and 21.

Doing this found a real defect in the existing tables: **"%lld caption(s) from %lld word(s)." had
its two counts swapped in Japanese, Korean and both Chinese** — "10 captions from 1 word" read
"from 10 words, 1 caption". The stringsdict formats are positional.

## Strings that no table could reach

Three more shapes, each found by looking for the one before:

- **AppKit takes plain strings.** The unsaved-work alert was English everywhere, with an English
  gerund slotted into its question ("before \(actionName)?"). The caller now passes the whole
  question as a `LocalizedStringResource`.
- **Undo names.** The timeline's undo tooltip was "Undo Split at Playhead" in every language.
  `apply(_:_:)` takes a `LocalizedStringResource`, so each call site's literal is a key.
- **Literal + literal.** `Label("\(name) is connected. " + "Unlock it…")` is a `String`, whose
  comment said it was one sentence. `noSentenceIsTwoLiteralsJoinedWithAPlus` forbids the shape
  outside `print(`.

And interpolated view literals were in no scan at all — `Text("\(a) of \(b)")` is the key
"%@ of %@", which is why the timeline read "0:57.06 of 0:57.06" in a German window.
`everyStatusSentenceIsInEveryStringTable` now reduces those too.

## The review, and its limit

Every translation's arguments are checked against its key's (`everyTranslationTakesTheArgumentsItsKeyGives`).
Everything written in this session and the last was re-read language by language; the changes are
in the commit. The ~500 older entries per language were audited mechanically instead — values
identical to their English key (all legitimate: codec names, "Zoom", "Audio", French "Silence")
and multi-argument keys without positions (none reordered). **None of this is a native speaker's
review, and nothing here should be read as one.**
